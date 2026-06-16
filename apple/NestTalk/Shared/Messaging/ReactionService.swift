import Foundation
import CryptoKit

/// Optimistic-update reaction layer.
///
/// On `setReaction`:
///   1. Insert / update the local `reactions` row immediately so the
///      UI bubble chip flips on the next render tick.
///   2. Seal the emoji bytes under the recipient's hybrid pubkeys and
///      wrap them in the REAL wire envelope (the server's
///      `messages.ParseEnvelope` validates routing UUIDs + layout —
///      same contract as message sends).
///   3. PUT `/api/v1/messages/{serverId}/reactions`.
///   4. On failure, roll back the local row to its previous state.
///
/// **Two id spaces.** Local `reactions.message_id` references the local
/// `messages.id` row UUID; the server speaks its own message id. Inbound
/// peer reactions arrive keyed by server id and are re-mapped through
/// `store.message(serverId:)` before insert.
public actor ReactionService {

    public enum Outcome: Equatable {
        case applied
        case rolledBack(code: Int)
    }

    private let store: MessageStore
    private let api: APIClient
    private let crypto: CryptoService
    private let sessionToken: () -> String?
    private let selfUserId: () -> String
    private let selfDeviceId: () -> String
    /// Drops the recipient's cached message pubkeys (RecipientKeysCache)
    /// so the post-rotation re-seal targets the NEW device's keys, not
    /// the revoked ones. Injected by AppState.
    private let invalidateKeys: (@Sendable (String) async -> Void)?
    private let signEnvelope: ((Data) throws -> Data)?
    /// Sender's enrolled Ed25519 key for verifying inbound reaction
    /// envelopes. nil (tests) skips verification.
    private let senderSigningKey: ((String, String) async -> RecipientKeysCache.SigningKeyResult)?
    /// Resolves keys + active device id as ONE atomic snapshot — see
    /// MessageSendService for the rationale. nil falls back to the
    /// userId-only seal + separate device fetch (tests).
    private let resolveSnapshot: ((String) async throws -> (recipient: CryptoRecipient, deviceId: String))?
    private let now: () -> Date
    private var deviceCache: [String: String] = [:]   // recipient userId → deviceId (fallback)

    public init(
        store: MessageStore,
        api: APIClient,
        crypto: CryptoService,
        sessionToken: @escaping () -> String?,
        selfUserId: @escaping () -> String,
        selfDeviceId: @escaping () -> String = { "" },
        invalidateKeys: (@Sendable (String) async -> Void)? = nil,
        signEnvelope: ((Data) throws -> Data)? = nil,
        senderSigningKey: ((String, String) async -> RecipientKeysCache.SigningKeyResult)? = nil,
        resolveSnapshot: ((String) async throws -> (recipient: CryptoRecipient, deviceId: String))? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.api = api
        self.crypto = crypto
        self.sessionToken = sessionToken
        self.selfUserId = selfUserId
        self.selfDeviceId = selfDeviceId
        self.invalidateKeys = invalidateKeys
        self.signEnvelope = signEnvelope
        self.senderSigningKey = senderSigningKey
        self.resolveSnapshot = resolveSnapshot
        self.now = now
    }

    /// In-flight update per message row. setReaction chains behind the
    /// previous task for the SAME message so overlapping taps can't
    /// interleave: without this, update A's rollback (snapshotted
    /// before B) could erase a B that already succeeded.
    /// Each entry carries an explicit `token` identity alongside its task,
    /// so the cleanup compares UUIDs (unambiguously, no reliance on `Task`'s
    /// Equatable conformance) to decide whether OUR task still owns the slot.
    private var inFlightByMessage: [String: (token: UUID, task: Task<Outcome, Never>)] = [:]

    /// Set or update the reaction for a message to `emoji` (or nil to
    /// clear). `messageRowId` keys the local table; `serverMessageId`
    /// addresses the server (rows still in `sending` have none — the
    /// reaction stays local-only and is not an error). Updates for the
    /// same message are serialized in arrival order.
    @discardableResult
    public func setReaction(
        messageRowId: String,
        serverMessageId: String?,
        toUserId: String,
        emoji: String?
    ) async -> Outcome {
        let prev = inFlightByMessage[messageRowId]?.task
        let token = UUID()
        let task = Task { [weak self] () -> Outcome in
            _ = await prev?.value
            guard let self else { return .rolledBack(code: -99) }
            return await self.performSetReaction(
                messageRowId: messageRowId,
                serverMessageId: serverMessageId,
                toUserId: toUserId,
                emoji: emoji
            )
        }
        inFlightByMessage[messageRowId] = (token: token, task: task)
        let outcome = await task.value
        // Only clear the slot if it still holds OUR entry — a newer
        // setReaction for the same message may have replaced it while we
        // awaited, and that one owns the cleanup. Compare the explicit UUID
        // token (not the task handle) so the check is self-evidently valid.
        if inFlightByMessage[messageRowId]?.token == token {
            inFlightByMessage.removeValue(forKey: messageRowId)
        }
        return outcome
    }

    private func performSetReaction(
        messageRowId: String,
        serverMessageId: String?,
        toUserId: String,
        emoji: String?
    ) async -> Outcome {
        // No server id yet (message still `sending`) → refuse up front.
        // Committing locally and reporting .applied would show the
        // sender a reaction the recipient can never receive — nothing
        // re-transmits it once the server id binds. The UI hides the
        // reaction menu for unsent messages; this guard is the
        // belt-and-suspenders for any other caller.
        guard let serverMessageId else {
            return .rolledBack(code: -5)
        }

        // Optimistic local update + remember rollback state.
        let previous = (try? store.reactions(forMessageId: messageRowId).first { $0.user_id == selfUserId() })
        do {
            if let emoji {
                try store.upsertReaction(MessageStore.Reaction(
                    messageId: messageRowId, userId: selfUserId(),
                    reaction: emoji, setAt: now()
                ))
            } else {
                try store.clearReaction(messageId: messageRowId, userId: selfUserId())
            }
        } catch {
            return .rolledBack(code: -1)
        }

        // Seal + PUT, with exactly one retry after a device-rotation
        // response: the recipient re-enrolled, so the cached device id
        // and pubkeys are stale — refresh both and re-seal for the new
        // device. Without this, the server-side device check rejects
        // the stale envelope (and before that check existed, the new
        // device would silently fail to decrypt it).
        let payload = Data((emoji ?? "").utf8)
        switch await sealAndPut(serverMessageId: serverMessageId, toUserId: toUserId, payload: payload) {
        case .success:
            return .applied
        case .rotated(let activeDeviceId):
            deviceCache[toUserId] = activeDeviceId
            await invalidateKeys?(toUserId)
            switch await sealAndPut(serverMessageId: serverMessageId, toUserId: toUserId, payload: payload) {
            case .success:
                return .applied
            case .rotated:
                await rollback(messageRowId: messageRowId, previous: previous)
                return .rolledBack(code: 403)
            case .failure(let code):
                await rollback(messageRowId: messageRowId, previous: previous)
                return .rolledBack(code: code)
            }
        case .failure(let code):
            await rollback(messageRowId: messageRowId, previous: previous)
            return .rolledBack(code: code)
        }
    }

    private enum PutAttempt {
        case success
        case rotated(activeDeviceId: String)
        case failure(code: Int)
    }

    /// One seal → wire-encode → PUT round. Rotation surfaces as a typed
    /// case so the caller can refresh caches and retry.
    private func sealAndPut(serverMessageId: String, toUserId: String, payload: Data) async -> PutAttempt {
        let envelope: Envelope
        let recipientDeviceId: String
        do {
            let sealRecipient: CryptoRecipient
            if let resolveSnapshot {
                let snap = try await resolveSnapshot(toUserId)
                sealRecipient = snap.recipient
                recipientDeviceId = snap.deviceId
            } else {
                sealRecipient = CryptoRecipient(userId: toUserId)
                recipientDeviceId = try await resolveRecipientDeviceId(toUserId)
            }
            // The reaction's wire message_id IS the parent server message
            // id: it binds the AEAD (routing) AND lets the receiver reject
            // a reaction transplanted onto a different message.
            let routing = EnvelopeRouting(
                senderUserId: selfUserId(),
                senderDeviceId: selfDeviceId(),
                recipientUserId: toUserId,
                recipientDeviceId: recipientDeviceId,
                messageId: serverMessageId
            )
            envelope = try await crypto.seal(plaintext: payload, forRecipient: sealRecipient, routing: routing)
        } catch {
            return .failure(code: -2)
        }
        let envelopeBase64: String
        do {
            envelopeBase64 = try WireEnvelope.encode(
                senderUserId: selfUserId(),
                senderDeviceId: selfDeviceId(),
                recipientUserId: toUserId,
                recipientDeviceId: recipientDeviceId,
                messageId: serverMessageId,
                senderEphemeralX25519Pub: envelope.senderEphemeralX25519Pub,
                kemCiphertext: envelope.kemCiphertext,
                nonce: envelope.nonce,
                ciphertextWithTag: envelope.ciphertext + envelope.tag,
                signer: signEnvelope
            ).base64EncodedString()
        } catch {
            return .failure(code: -4)
        }

        do {
            _ = try await api.putReaction(
                messageId: serverMessageId,
                envelopeBase64: envelopeBase64,
                sentAt: now(),
                sessionToken: sessionToken()
            )
            return .success
        } catch APIClient.SendError.recipientDeviceRotated(let activeDeviceId) {
            return .rotated(activeDeviceId: activeDeviceId)
        } catch APIClient.SendError.http(let code, _) {
            return .failure(code: code)
        } catch {
            return .failure(code: -3)
        }
    }

    /// Decode + apply a live `.reactionUpdate` WS event (peer reaction,
    /// envelope keyed by the SERVER message id). An undecryptable
    /// envelope is dropped — it must never read as "reaction cleared"
    /// (an INTENTIONAL clear decrypts fine to an empty string).
    public func ingestUpdate(
        serverMessageId: String,
        senderUserId: String,
        envelopeBase64: String,
        receivedAtMillis: Int64
    ) async {
        let emoji: String
        switch await decodeEmoji(serverMessageId: serverMessageId, envelopeBase64: envelopeBase64, senderUserId: senderUserId) {
        case .decoded(let e): emoji = e
        case .invalid, .deferred:
            // WS path is fire-and-forget; on either outcome just drop —
            // catch-up (which holds its cursor on .deferred) recovers a
            // transiently-undecodable reaction on the next reconnect.
            NTLogger.messaging.error("reaction WS envelope not applied from \(senderUserId)")
            return
        }
        await ingest(
            serverMessageId: serverMessageId,
            senderUserId: senderUserId,
            emoji: emoji,
            setAt: Date(timeIntervalSince1970: TimeInterval(receivedAtMillis) / 1000)
        )
    }

    /// Apply a peer reaction. Re-maps the server message id to the
    /// local row. Returns whether the row was durably applied — the
    /// catch-up loop uses this to avoid checkpointing its cursor past
    /// a reaction that was never stored (e.g. parent not ingested yet).
    @discardableResult
    public func ingest(serverMessageId: String, senderUserId: String, emoji: String, setAt: Date) async -> Bool {
        guard let parent = try? store.message(serverId: serverMessageId) else { return false }
        do {
            if emoji.isEmpty {
                try store.clearReaction(messageId: parent.id, userId: senderUserId)
            } else {
                try store.upsertReaction(MessageStore.Reaction(
                    messageId: parent.id,
                    userId: senderUserId,
                    reaction: emoji,
                    setAt: setAt
                ))
            }
            return true
        } catch {
            // Storage failure — the catch-up poll retries on the next
            // tick (its cursor won't advance past this reaction).
            return false
        }
    }

    /// One-shot catch-up: pulls every reaction since the last cursor
    /// and ingests them. Cursor stored in `local_cursors` under
    /// "reactions.received_at".
    @discardableResult
    public func catchUp(limit: Int = 100) async -> Int {
        // Restore the full composite cursor `(received_at, id)`. Persisting
        // only `received_at` (and replaying with an empty `sinceId`) makes the
        // server re-return every reaction sharing the checkpoint millisecond,
        // replaying acked rows on each reconnect and risking starvation of
        // later reactions behind the page cap. See MessageReceiveService.
        let parsed = MessageReceiveService.parseCursor((try? store.cursor(name: Self.cursorName)) ?? nil)
        var sinceReceivedAt: Int64? = parsed.receivedAt
        var sinceId: String? = parsed.id
        var ingested = 0
        var pages = 0
        repeat {
            pages += 1
            let page: APIClient.ReactionsPage
            do {
                page = try await api.reactionsSince(
                    sinceReceivedAt: sinceReceivedAt,
                    sinceId: sinceId,
                    limit: limit,
                    sessionToken: sessionToken()
                )
            } catch {
                break
            }
            var stalled = false
            for r in page.reactions {
                switch await decodeEmoji(serverMessageId: r.message_id, envelopeBase64: r.envelope, senderUserId: r.sender_user_id) {
                case .deferred:
                    // Sender-key lookup failed (transient). Stop WITHOUT
                    // advancing the cursor — matching MessageReceive
                    // Service — so the reaction is re-fetched once the
                    // key endpoint recovers.
                    stalled = true
                case .invalid:
                    // Permanently bad envelope — never "cleared"; skip
                    // it and let the cursor advance past.
                    break
                case .decoded(let emoji):
                    let applied = await ingest(
                        serverMessageId: r.message_id,
                        senderUserId: r.sender_user_id,
                        emoji: emoji,
                        setAt: Date(timeIntervalSince1970: TimeInterval(r.received_at) / 1000)
                    )
                    if applied {
                        ingested += 1
                    } else if store.isRejected(serverId: r.message_id) {
                        // The parent was REJECTED by the receive pipeline
                        // (forged / unparseable / mis-routed) — it has no
                        // local row and never will, so this reaction can't
                        // apply. Dead-letter it (advance past) instead of
                        // wedging the cursor forever.
                        NTLogger.messaging.error("reaction targets a rejected parent \(r.message_id) — dead-lettering")
                    } else {
                        // Parent not ingested yet (reaction catch-up raced
                        // message catch-up) or a storage hiccup. The server
                        // only returns reactions whose parent still exists
                        // (FK), so a missing LOCAL parent is a transient
                        // ordering delay — pin the cursor (no give-up) and
                        // retry on the next catch-up, once message catch-up
                        // has landed the parent. Advancing past it would
                        // silently lose the reaction.
                        stalled = true
                    }
                }
                if stalled { break }
                sinceReceivedAt = r.received_at
                sinceId = r.id
            }
            if let r = sinceReceivedAt {
                let id = sinceId ?? ""
                let prior = (try? store.cursor(name: Self.cursorName)) ?? nil
                if MessageReceiveService.cursorAdvances(receivedAt: r, id: id, beyond: prior) {
                    try? store.setCursor(name: Self.cursorName, value: MessageReceiveService.formatCursor(receivedAt: r, id: id))
                }
            }
            if stalled || page.next_cursor == nil || page.reactions.isEmpty || pages >= 50 { break }
        } while true
        return ingested
    }

    public static let cursorName = "reactions.received_at"

    // MARK: - Internals

    enum EmojiDecode {
        case decoded(String)  // verified + decrypted ("" = intentional clear)
        case invalid          // unparseable / forged / undecryptable — drop permanently
        case deferred         // sender-key lookup failed — transient, retry
    }

    /// Parse the wire envelope and decrypt the emoji body. Same AAD
    /// reconstruction as MessageReceiveService.ingestRemote.
    /// Distinguishes a transient key-lookup failure (.deferred — must
    /// not advance the catch-up cursor) from a permanently bad envelope
    /// (.invalid — drop). `.decoded("")` is an intentional clear.
    private func decodeEmoji(serverMessageId: String, envelopeBase64: String, senderUserId: String) async -> EmojiDecode {
        guard
            let bytes = Data(base64Encoded: envelopeBase64),
            let parsed = try? WireEnvelope.parse(bytes)
        else { return .invalid }
        // Routing trust: the SIGNED envelope must be addressed to us, from
        // the claimed sender, AND carry the parent message id of the
        // wrapper. Without the message-id check a malicious server could
        // transplant a validly-signed reaction onto a DIFFERENT message
        // (the signature doesn't bind the wrapper id). Reject on any drift.
        guard
            parsed.recipientUserId == selfUserId(),
            parsed.senderUserId == senderUserId,
            parsed.messageId == serverMessageId
        else {
            NTLogger.messaging.error("reaction routing mismatch (sender/recipient/message_id) — rejecting")
            return .invalid
        }
        // Authenticity: verify the trailer signature against the
        // sender's enrolled Ed25519 device key. A failed lookup
        // (endpoint unreachable) is transient; a present-but-mismatched
        // key is a forgery.
        if let senderSigningKey {
            let pub: Data
            switch await senderSigningKey(senderUserId, parsed.senderDeviceId) {
            case .found(let p):    pub = p
            case .lookupFailed:    return .deferred
            case .deviceUnknown:   return .invalid
            }
            guard
                let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub),
                key.isValidSignature(parsed.signature, for: WireEnvelope.signedBody(bytes))
            else { return .invalid }
        }
        let ctTotal = parsed.ciphertextWithTag
        let tagStart = max(0, ctTotal.count - 16)
        let routing = EnvelopeRouting(parsed: parsed)
        let envelope = Envelope(
            version: parsed.version,
            senderEphemeralX25519Pub: parsed.senderEphemeralX25519Pub,
            kemCiphertext: parsed.kemCiphertext,
            nonce: parsed.nonce,
            aad: routing.infoBytes(),
            ciphertext: Data(ctTotal.prefix(tagStart)),
            tag: Data(ctTotal.suffix(16))
        )
        guard let opened = try? await crypto.open(envelope, fromRecipient: CryptoRecipient(userId: senderUserId), routing: routing) else {
            return .invalid
        }
        return .decoded(String(data: opened, encoding: .utf8) ?? "")
    }

    private func resolveRecipientDeviceId(_ userId: String) async throws -> String {
        if let cached = deviceCache[userId] { return cached }
        guard let entry = try await api.fetchActiveDevice(
            forUserId: userId, sessionToken: sessionToken()
        ) else {
            throw APIClient.SendError.http(code: 404, body: nil)
        }
        deviceCache[userId] = entry.device_id
        return entry.device_id
    }

    private func rollback(messageRowId: String, previous: MessageStore.Reaction?) async {
        if let prev = previous {
            try? store.upsertReaction(prev)
        } else {
            try? store.clearReaction(messageId: messageRowId, userId: selfUserId())
        }
    }
}
