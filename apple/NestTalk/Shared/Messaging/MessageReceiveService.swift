import CryptoKit
import Foundation
import GRDB

/// Drains incoming messages from two sources:
///
/// 1. **Live WS path.** Consumes `ControlWebSocket.events()` for
///    `.messageIncoming`. For each event: decode the envelope, decrypt
///    via `CryptoService.open`, insert as a "delivered" row in
///    `messages`, then POST `/api/v1/messages/{id}/ack` (kind=received).
///
/// 2. **Catch-up path.** On `ScenePhase.active` transitions (or any
///    explicit `catchUp()` call), pulls
///    `GET /api/v1/messages/pending?since_received_at=<cursor>` to
///    absorb messages that arrived while WS was offline. Cursor is
///    persisted in `local_cursors` table so it survives app relaunch.
///
/// **De-duplication.** Server `id` is the join key — we never
/// dedupe on `local_id`. Catch-up rows whose `id` already exists
/// (including outgoing rows that just transitioned to "sent_to_server")
/// are skipped, only ack'd.
public actor MessageReceiveService {

    public static let cursorName = "messages.received_at"

    /// The server pages by the COMPOSITE cursor `(received_at, id)`. Persisting
    /// only `received_at` and replaying with an empty `sinceId` makes the
    /// server return every row sharing the checkpoint millisecond again (its
    /// predicate is `received_at = ? AND id > ''`, true for any real UUID), so
    /// a same-millisecond burst can spend the page cap re-acking old rows
    /// before newer messages are reached. We therefore persist BOTH halves,
    /// encoded as `"<received_at>|<id>"`, and restore them before paging.
    static func parseCursor(_ raw: String?) -> (receivedAt: Int64?, id: String?) {
        guard let raw, !raw.isEmpty else { return (nil, nil) }
        if let pipe = raw.firstIndex(of: "|") {
            let r = Int64(raw[raw.startIndex..<pipe])
            let id = String(raw[raw.index(after: pipe)...])
            return (r, id.isEmpty ? nil : id)
        }
        return (Int64(raw), nil) // legacy value: received_at only
    }

    static func formatCursor(receivedAt: Int64, id: String) -> String {
        "\(receivedAt)|\(id)"
    }

    /// True when `(r, id)` is strictly after the persisted cursor `prior`,
    /// using the same composite ordering as the server.
    static func cursorAdvances(receivedAt r: Int64, id: String, beyond prior: String?) -> Bool {
        let (pr, pid) = parseCursor(prior)
        guard let pr else { return true }
        if r != pr { return r > pr }
        return id > (pid ?? "")
    }

    private let store: MessageStore
    private let api: APIClient
    private let crypto: CryptoService
    private let sessionToken: () -> String?
    private let selfUserId: () -> String
    /// Resolves the sender's enrolled Ed25519 public key so envelope
    /// trailer signatures can be verified — without it a compromised
    /// server could fabricate decryptable envelopes attributed to any
    /// user. nil (tests) skips verification.
    private let senderSigningKey: ((String, String) async -> RecipientKeysCache.SigningKeyResult)?
    /// Invoked when a catch-up pull is rejected with 401 — the cold-launch
    /// detection point for a token invalidated by a server restore the
    /// client missed (it was offline for the live `server_restored` event).
    /// Triggers a single-flight re-handshake so the client recovers in
    /// seconds instead of waiting out the token TTL (~an hour).
    private let onAuthFailure: (@Sendable () async -> Void)?

    public init(
        store: MessageStore,
        api: APIClient,
        crypto: CryptoService,
        sessionToken: @escaping () -> String?,
        selfUserId: @escaping () -> String,
        senderSigningKey: ((String, String) async -> RecipientKeysCache.SigningKeyResult)? = nil,
        onAuthFailure: (@Sendable () async -> Void)? = nil
    ) {
        self.store = store
        self.api = api
        self.crypto = crypto
        self.sessionToken = sessionToken
        self.selfUserId = selfUserId
        self.senderSigningKey = senderSigningKey
        self.onAuthFailure = onAuthFailure
    }

    /// Process one event from the WS stream. Idempotent — receiving
    /// the same event twice doesn't double-insert.
    public func handleEvent(_ event: ControlEvent) async {
        guard case let .messageIncoming(id, from, _, envelopeBase64, sentAt, receivedAt, replyToId) = event else {
            return
        }
        await ingestRemote(
            id: id, from: from,
            envelopeBase64: envelopeBase64,
            sentAt: sentAt, receivedAt: receivedAt,
            replyToId: replyToId
        )
    }

    /// Run a one-shot catch-up cycle. Reads the persisted cursor, pulls
    /// pending pages until exhausted, advances the cursor, ack's each
    /// message. Returns the number of new rows inserted.
    @discardableResult
    public func catchUp(limit: Int = 100) async -> Int {
        let parsed = Self.parseCursor((try? store.cursor(name: Self.cursorName)) ?? nil)
        var inserted = 0
        var cursorReceivedAt: Int64? = parsed.receivedAt
        var cursorId: String? = parsed.id
        var pages = 0
        repeat {
            pages += 1
            let resp: APIClient.PendingResponse
            do {
                resp = try await api.pendingMessages(
                    sinceReceivedAt: cursorReceivedAt,
                    sinceId: cursorId,
                    limit: limit,
                    sessionToken: sessionToken()
                )
            } catch {
                // A 401 here on cold launch means our cached token is
                // invalid (a server restore we missed rotated the signing
                // key). Trigger an immediate re-handshake.
                if case APIClient.SendError.http(let code, _) = error, code == 401 {
                    await onAuthFailure?()
                }
                break
            }
            var deferredStop = false
            for m in resp.messages {
                let result = await ingestRemote(
                    id: m.id, from: m.sender_user_id,
                    envelopeBase64: m.envelope,
                    sentAt: m.sent_at, receivedAt: m.received_at,
                    replyToId: m.reply_to_id
                )
                switch result {
                case .inserted:
                    inserted += 1
                case .duplicate:
                    break   // already have it (acked); advance past it
                case .deferred:
                    // Sender-key lookup failed — neither stored nor
                    // acked. Stop WITHOUT advancing past this row, or the
                    // cursor checkpoints beyond a valid message and the
                    // server's composite cursor never returns it again.
                    deferredStop = true
                }
                if deferredStop { break }
                cursorReceivedAt = m.received_at
                cursorId = m.id
            }
            // Persist progress after every page — but only if we're
            // moving forward. Concurrent catch-up calls can interleave
            // pages; if A's page-N writes a higher cursor and B's
            // page-N+1 then writes a lower one, the cursor regresses
            // and we re-pull already-acked rows on the next tick.
            if let r = cursorReceivedAt {
                let id = cursorId ?? ""
                let prior = (try? store.cursor(name: Self.cursorName)) ?? nil
                if Self.cursorAdvances(receivedAt: r, id: id, beyond: prior) {
                    try? store.setCursor(name: Self.cursorName, value: Self.formatCursor(receivedAt: r, id: id))
                }
            }
            // Stop on a deferred row (retry next tick), exhausted pages,
            // or the page cap.
            if deferredStop || resp.next_cursor == nil || resp.messages.isEmpty || pages >= 50 {
                break
            }
        } while true
        return inserted
    }

    /// Decrypt the envelope body. AAD reconstructed from routing
    /// metadata (same shape the sender bound). Returns nil on any
    /// failure — the caller renders an undecryptable placeholder.
    private func decryptBody(parsed: WireEnvelope.Parsed, senderUserId: String) async -> String? {
        let ctTotal = parsed.ciphertextWithTag
        // ChaChaPoly tag is the last 16 bytes; ct is everything before
        // it. CryptoKit's SealedBox(combined:) wants nonce || ct || tag.
        let tagStart = max(0, ctTotal.count - 16)
        let ct  = ctTotal.prefix(tagStart)
        let tag = ctTotal.suffix(16)
        // Routing parsed off the wire header drives BOTH the HKDF info and
        // the AEAD AAD — byte-identical to what the sender bound, so any
        // re-routing or re-attribution fails authentication.
        let routing = EnvelopeRouting(parsed: parsed)
        let envelope = Envelope(
            version: parsed.version,
            senderEphemeralX25519Pub: parsed.senderEphemeralX25519Pub,
            kemCiphertext: parsed.kemCiphertext,
            nonce: parsed.nonce,
            aad: routing.infoBytes(),
            ciphertext: Data(ct),
            tag: Data(tag)
        )
        guard let opened = try? await crypto.open(envelope, fromRecipient: CryptoRecipient(userId: senderUserId), routing: routing) else {
            return nil
        }
        return String(data: opened, encoding: .utf8)
    }

    enum SenderVerification {
        case ok          // verified, or no verifier configured
        case forged      // key resolved but signature invalid → reject permanently
        case lookupFailed // couldn't resolve the sender's key → transient, retry
    }

    /// Authenticity gate: validate the envelope trailer signature
    /// against the sender's enrolled Ed25519 device key (v0.2.3
    /// contract). Distinguishes a forged signature (a real envelope we
    /// must reject and ack) from a key-lookup failure (our keys
    /// endpoint was unreachable — must NOT insert/ack, so catch-up
    /// re-delivers once the lookup recovers; otherwise a transient
    /// network blip would dedupe the valid envelope away forever).
    private func verifySender(
        parsed: WireEnvelope.Parsed,
        envelopeBytes: Data,
        senderUserId: String
    ) async -> SenderVerification {
        guard let senderSigningKey else { return .ok }
        let pub: Data
        switch await senderSigningKey(senderUserId, parsed.senderDeviceId) {
        case .found(let p):
            pub = p
        case .lookupFailed:
            NTLogger.crypto.error("sender key lookup failed for \(senderUserId) — deferring")
            return .lookupFailed
        case .deviceUnknown:
            // Server binds sender_device_id at send, so a present-but-
            // unknown device only happens for a legitimately removed
            // device on an old spooled message. Permanent → reject + ack
            // so it can't wedge the catch-up cursor forever.
            NTLogger.crypto.error("sender device unknown for \(senderUserId) — rejecting")
            return .forged
        }
        guard
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub),
            key.isValidSignature(parsed.signature, for: WireEnvelope.signedBody(envelopeBytes))
        else {
            NTLogger.crypto.error("envelope signature rejected for sender \(senderUserId)")
            return .forged
        }
        return .ok
    }

    enum IngestResult {
        case inserted   // new row stored + acked
        case duplicate  // already had it (re-acked); safe to advance past
        case deferred   // key lookup failed — NOT stored, NOT acked; retry
    }

    /// Insert + ack one remote message.
    @discardableResult
    private func ingestRemote(
        id: String, from senderUserId: String,
        envelopeBase64: String,
        sentAt: Int64, receivedAt: Int64,
        replyToId: String?
    ) async -> IngestResult {
        // Dedupe on server id (never local_id — peers never carry our
        // local_id). The same id can arrive twice if a catch-up pull
        // races with a live WS frame, or if our own outgoing message
        // echoes back via the WS broadcast — in either case the row
        // already exists in `messages.server_id`.
        if (try? store.message(serverId: id)) != nil {
            // Already stored — re-ack so the server's spool advances. If the
            // ack fails, DON'T advance the catch-up cursor: defer so the next
            // pull re-delivers and re-acks.
            return await ackDelivered(id: id) ? .duplicate : .deferred
        }

        let envelopeBytes = Data(base64Encoded: envelopeBase64) ?? Data()
        var plaintext: String? = nil
        // attributedSender starts as the UNTRUSTED outer sender; once the
        // signed routing fields validate, it's the SIGNED sender.
        var attributedSender = senderUserId
        // The SIGNED message id — the replay-proof dedup key. A
        // compromised server can re-wrap the same signed envelope under a
        // fresh OUTER server id; deduping on the signed id (which it
        // can't change without breaking the signature) blocks the
        // duplicate-plaintext replay. nil → unparseable envelope (store
        // as undecryptable, dedup on outer id only).
        var signedMessageId: String? = nil
        let parsedOpt = try? WireEnvelope.parse(envelopeBytes)
        // Authenticity gate is ON whenever a sender-key resolver is wired
        // (always, in production). With it on, an envelope we CANNOT
        // authenticate must never become a visible conversation row — a
        // compromised relay would otherwise inject arbitrary placeholders
        // into a thread and advance delivery/catch-up state. Such envelopes
        // are ack'd-and-dropped (rejected), never inserted.
        let verifying = senderSigningKey != nil
        if parsedOpt == nil, verifying {
            NTLogger.crypto.error("unparseable envelope under verification — rejecting (no insert)")
            return await rejectAndAck(id: id)
        }
        if let parsed = parsedOpt {
            // Routing trust: the envelope's SIGNED routing fields must
            // match the outer event and our own identity. A server that
            // re-attributes or mis-routes a valid envelope is rejected
            // here BEFORE the signature even matters. The SIGNED message id
            // must also equal the outer server handle `id` — otherwise a
            // compromised/skewed relay could deliver a valid envelope under a
            // different handle, and we'd store localId from the signed payload
            // but key serverId/ack on the wrong outer id, desyncing receipts,
            // reactions, and sender status (the same binding reactions enforce).
            guard parsed.recipientUserId == selfUserId(),
                  parsed.senderUserId == senderUserId,
                  parsed.messageId == id else {
                NTLogger.crypto.error("envelope routing mismatch (signed sender/recipient/message-id) — rejecting")
                return await rejectAndAck(id: id)
            }
            switch await verifySender(parsed: parsed, envelopeBytes: envelopeBytes, senderUserId: parsed.senderUserId) {
            case .lookupFailed:
                // Transient: neither insert nor ack — the server keeps
                // it spooled and catch-up retries once the key resolves.
                return .deferred
            case .forged:
                // Real envelope, bad signature: REJECT — ack + drop, never
                // insert. A compromised server must not be able to spam a
                // user's thread with forged placeholder rows. (.forged only
                // arises when verification is configured.)
                NTLogger.crypto.error("forged envelope signature — rejecting (no insert)")
                return await rejectAndAck(id: id)
            case .ok:
                attributedSender = parsed.senderUserId
                signedMessageId = parsed.messageId
                plaintext = await decryptBody(parsed: parsed, senderUserId: parsed.senderUserId)
            }
        }

        // Replay dedupe on the SIGNED message id (stored in local_id,
        // which carries a UNIQUE partial index). Catches the same signed
        // envelope re-delivered under a fresh outer server id.
        if let signedMessageId, (try? store.message(localId: signedMessageId)) != nil {
            return await ackDelivered(id: id) ? .duplicate : .deferred
        }

        // Whether decrypt worked or not, store SOMETHING — the row
        // surfaces in the UI. Decryption failures appear as a placeholder
        // (Sprint 5 Task 5.5 LocalUnknownEnvelopes turns this into a
        // proper debug-bin with the raw bytes).
        // Inbound rows: the row id is a fresh client UUID, server_id is
        // the server-assigned routing handle (acks), and local_id carries
        // the signed message id for replay-proof dedup.
        let row = MessageStore.Message(
            id: UUID().uuidString,
            threadUserId: attributedSender,
            outgoing: false,
            plaintext: plaintext ?? MessageStore.undecryptablePlaceholder,
            state: "delivered",
            sentAt: Date(timeIntervalSince1970: TimeInterval(sentAt) / 1000.0),
            receivedAt: Date(timeIntervalSince1970: TimeInterval(receivedAt) / 1000.0),
            replyTo: replyToId,
            localId: signedMessageId,
            serverId: id
        )
        do {
            try store.insert(row)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            // A second WS frame for the same server_id raced our
            // catch-up insert. Drop the duplicate (the row already
            // exists) and still ack so the server's spool advances.
        } catch {
            // Any other DB failure is real: log via NTLogger so the
            // operator can see it instead of letting `try?` swallow
            // genuine schema/IO errors. Treat as deferred (no ack) so a
            // transient storage fault doesn't dedupe the message away.
            NTLogger.messaging.error("ingestRemote insert failed: \(error)")
            return .deferred
        }
        // Row stored. Only report .inserted (advance the cursor) once the
        // delivered-ack lands; a failed ack defers so the next catch-up
        // re-acks via the duplicate path rather than stranding the receipt.
        return await ackDelivered(id: id) ? .inserted : .deferred
    }

    /// POST the delivered ack for a message we have stored. Returns whether
    /// the server accepted it. A failed ack must NOT advance the catch-up
    /// cursor — the server keeps the message spooled and the sender never
    /// sees "delivered" — so callers defer on `false`.
    private func ackDelivered(id: String) async -> Bool {
        do {
            try await api.ackMessage(id: id, kind: "delivered", sessionToken: sessionToken())
            return true
        } catch {
            NTLogger.messaging.error("delivered-ack failed for \(id) — deferring")
            return false
        }
    }

    /// Reject a message: persist its tombstone DURABLY, then ack so the server
    /// drops the spool. The tombstone must land BEFORE the ack — if the local
    /// write fails we must NOT ack, because acking lets the server delete the
    /// spooled message while the client has neither the message nor a rejection
    /// record. Reaction catch-up would then treat reactions for this server id
    /// as a missing-parent case (stall the cursor) instead of a rejected-parent
    /// case (dead-letter), wedging later reactions. Deferring retries the whole
    /// rejection on the next catch-up.
    private func rejectAndAck(id: String) async -> IngestResult {
        do {
            try store.tombstoneRejected(serverId: id)
        } catch {
            NTLogger.crypto.error("rejection tombstone write failed for \(id) — deferring (no ack)")
            return .deferred
        }
        return await ackDelivered(id: id) ? .duplicate : .deferred
    }

}
