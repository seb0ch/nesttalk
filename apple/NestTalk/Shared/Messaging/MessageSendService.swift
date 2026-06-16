import Foundation
import CryptoKit

/// Sends one outgoing message end-to-end:
///
/// 1. Generates a `local_id` (UUID) and inserts a `messages` row in
///    state `"sending"`.
/// 2. Asks `CryptoService` to seal the plaintext to the recipient.
/// 3. POSTs the sealed envelope to `/api/v1/messages`.
/// 4. On 200, transitions the row to `"sent_to_server"` and binds the
///    server-assigned `id`.
/// 5. On 403 with `active_recipient_device_id`, raises a typed error so
///    the caller can re-fetch keys via `/api/v1/keys/message/{userId}`
///    and retry once.
/// 6. On 5xx / 408 / 429 / network, enqueues the row in `pending_queue`
///    in state `"failed"` (retriable). `OutboxService` drives retries.
/// 7. On other 4xx, marks `"failed_permanently"` and surfaces the error.
///
/// Concurrency: `actor` so all state transitions are serialized per
/// instance. UI consumers wait on the `async` API and update on
/// `@MainActor` from the resulting `Message`.
public actor MessageSendService {

    public enum SendOutcome: Equatable {
        case sentToServer(serverId: String, localId: String)
        case enqueuedRetry(localId: String, attemptsSoFar: Int)
        case failedPermanently(localId: String, code: Int)
    }

    public enum SendError: Error, Equatable {
        case rotated(activeDeviceId: String)
        case permanent(code: Int)
        case unexpected(String)
    }

    private let store: MessageStore
    private let api: APIClient
    private let crypto: CryptoService
    private let dbWrapKey: SymmetricKey
    private let sessionToken: () -> String?
    private let selfUserId: () -> String
    private let selfDeviceId: () -> String
    /// Signs the envelope body with the device Ed25519 key (v0.2.3
    /// contract: receivers verify; zero-fill is rejected by peers).
    private let signEnvelope: ((Data) throws -> Data)?
    /// Resolves the recipient's encryption keys AND active device id as
    /// ONE atomic snapshot so sealing and wire routing use the exact
    /// same rotation — no straddle between seal and device lookup. nil
    /// falls back to the userId-only seal + separate device fetch
    /// (tests).
    private let resolveSnapshot: ((String) async throws -> (recipient: CryptoRecipient, deviceId: String))?
    /// Force a session refresh on a 401 so the first stale-token send doesn't
    /// have to wait for an outbox tick to recover. Mirrors OutboxService.
    private let onAuthFailure: (() async -> Void)?
    private let now: () -> Date
    private var deviceCache: [String: String] = [:]   // recipient userId → deviceId (fallback)

    public init(
        store: MessageStore,
        api: APIClient,
        crypto: CryptoService,
        dbWrapKey: SymmetricKey,
        sessionToken: @escaping () -> String?,
        selfUserId: @escaping () -> String,
        selfDeviceId: @escaping () -> String = { "" },
        signEnvelope: ((Data) throws -> Data)? = nil,
        resolveSnapshot: ((String) async throws -> (recipient: CryptoRecipient, deviceId: String))? = nil,
        onAuthFailure: (() async -> Void)? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.api = api
        self.crypto = crypto
        self.dbWrapKey = dbWrapKey
        self.sessionToken = sessionToken
        self.selfUserId = selfUserId
        self.selfDeviceId = selfDeviceId
        self.signEnvelope = signEnvelope
        self.resolveSnapshot = resolveSnapshot
        self.onAuthFailure = onAuthFailure
        self.now = now
    }

    private func resolveRecipientDeviceId(_ userId: String) async throws -> String {
        if let cached = deviceCache[userId] { return cached }
        guard let entry = try await api.fetchActiveDevice(
            forUserId: userId, sessionToken: sessionToken()
        ) else {
            throw SendError.unexpected("recipient \(userId) has no active device")
        }
        deviceCache[userId] = entry.device_id
        return entry.device_id
    }

    /// Public send entry point.
    /// - Returns: the outcome — caller can chain UI updates on success or
    ///   surface an error label on permanent failure.
    @discardableResult
    public func send(
        text: String,
        toUserId recipientUserId: String,
        replyTo: String? = nil,
        pinnedRecipientDeviceId: String? = nil
    ) async -> SendOutcome {
        let localId = UUID().uuidString
        let sentAt = now()

        // 1. Local echo: insert "sending" row first so the UI shows it.
        // The row's id is the stable client UUID; server_id stays nil
        // until the POST returns. Other tables (reactions, replies,
        // read_receipts) reference messages.id by value — keeping that
        // value stable for the row's lifetime is what prevents orphan
        // rows when the server-assigned id finally arrives.
        do {
            try store.insert(MessageStore.Message(
                id: localId,
                threadUserId: recipientUserId,
                outgoing: true,
                plaintext: text,
                state: "sending",
                sentAt: sentAt,
                replyTo: replyTo,
                localId: localId
            ))
        } catch {
            return .failedPermanently(localId: localId, code: -1)
        }

        // 2. Wrap the plaintext FIRST so a transient key/device lookup
        // failure can persist a RETRYABLE pending entry instead of
        // losing the message — OutboxService re-seals from this wrap on
        // a later tick.
        let plaintextWrapped: Data
        do {
            plaintextWrapped = try PlaintextWrap.seal(Data(text.utf8), using: dbWrapKey)
        } catch {
            try? store.updateMessage(localId: localId, serverId: nil, state: "failed_permanently")
            return .failedPermanently(localId: localId, code: -3)
        }

        // 2.5. Create the DURABLE retry record BEFORE the first network
        // attempt — unsealed (empty payload + wrapped plaintext). If the app
        // is killed mid-send (during key resolution, the POST, or before the
        // success completion runs), this row survives and OutboxService
        // re-seals + re-sends it; the server dedups by the stable wire
        // message_id (= localId). Without this, a crash anywhere before the
        // success write strands the message in "sending" with no recovery.
        // A small backoff keeps OutboxService from racing the fast path. If
        // the durable insert itself fails, we can't promise delivery — fail.
        do {
            try store.enqueuePending(MessageStore.PendingMessage(
                id: localId, payload: Data(),     // empty → seal-on-retry
                attempts: 1, nextRetryAt: Self.nextDelay(for: 1, base: sentAt),
                recipientUserId: recipientUserId,
                pinnedRecipientDeviceId: "",       // resolved on retry
                messageId: localId,
                plaintextWrapped: plaintextWrapped,
                originalSentAt: sentAt,
                replyToId: replyTo
            ))
        } catch {
            try? store.updateMessage(localId: localId, serverId: nil, state: "failed_permanently")
            return .failedPermanently(localId: localId, code: -7)
        }

        // 3. Resolve the recipient snapshot {keys, deviceId} ONCE, then
        // seal with that exact recipient (keys present → the decorator
        // passes through) and route to that exact device — no straddle
        // between sealing and device lookup across a rotation. A
        // transient failure here (network, 5xx, auth-refresh race)
        // enqueues for retry; only a CONFIRMED terminal condition (no
        // active device, malformed key material) fails permanently.
        let sealRecipient: CryptoRecipient
        let recipientDeviceId: String
        do {
            if let resolveSnapshot {
                let snap = try await resolveSnapshot(recipientUserId)
                sealRecipient = snap.recipient
                recipientDeviceId = snap.deviceId
            } else {
                sealRecipient = CryptoRecipient(userId: recipientUserId)
                recipientDeviceId = try await resolveRecipientDeviceId(recipientUserId)
            }
        } catch RecipientKeysCache.KeysError.noActiveDevice {
            // The recipient currently has no active (non-revoked) device —
            // every device is revoked, e.g. a single-device user between
            // revocation and an admin re-enroll. Retry rather than drop:
            // re-enrollment publishes a new active device and the durable
            // unsealed row re-resolves it on a later outbox tick. Sealing
            // to the revoked device would 403 and lose the message.
            return deferToOutbox(localId: localId)
        } catch let e as RecipientKeysCache.KeysError {
            // malformedPubkey: the recipient's published key material is
            // corrupt — no amount of retry fixes the bytes. Drop the
            // durable row and fail.
            NTLogger.messaging.error("recipient keys terminal failure: \(String(describing: e))")
            return failPermanently(localId: localId, code: -4)
        } catch APIClient.SendError.http(let code, _) where code == 401 {
            // A 401 on the KEY-LOOKUP request (not just the POST) means a
            // stale token — force a refresh now so the durable row's retry
            // uses a fresh token, mirroring the POST-401 path. Without this,
            // key resolution keeps 401ing against the dead token until
            // maxAttempts drops the message.
            await onAuthFailure?()
            return deferToOutbox(localId: localId)
        } catch {
            // Transient (network / 5xx / refresh race) — the durable unsealed
            // row already exists; OutboxService seals + retries it.
            return deferToOutbox(localId: localId)
        }

        // The local UUID doubles as the wire message_id: it's stable
        // across retries, binds the AEAD (routing below), and becomes the
        // recipient's replay-dedup key.
        let messageId = localId
        let routing = EnvelopeRouting(
            senderUserId: selfUserId(),
            senderDeviceId: selfDeviceId(),
            recipientUserId: recipientUserId,
            recipientDeviceId: recipientDeviceId,
            messageId: messageId
        )
        let envelope: Envelope
        do {
            envelope = try await crypto.seal(plaintext: Data(text.utf8), forRecipient: sealRecipient, routing: routing)
        } catch {
            // Permanent: drop the durable pending row too. Leaving it behind
            // would let OutboxService (which treats an empty-payload row as
            // seal-on-retry) re-seal and SEND a message the caller was just
            // told permanently failed — a consent/state violation.
            NTLogger.messaging.error("crypto.seal failed permanently: \(String(describing: error))")
            return failPermanently(localId: localId, code: -2)
        }

        // ChaChaPoly's "combined" output is nonce(12) || ct || tag(16).
        // The wire envelope carries nonce in the cipher header; ct_len
        // is just (ct + tag).
        let ciphertextWithTag = envelope.ciphertext + envelope.tag

        let envelopeBytes: Data
        do {
            envelopeBytes = try WireEnvelope.encode(
                senderUserId: selfUserId(),
                senderDeviceId: selfDeviceId(),
                recipientUserId: recipientUserId,
                recipientDeviceId: recipientDeviceId,
                messageId: messageId,
                senderEphemeralX25519Pub: envelope.senderEphemeralX25519Pub,
                kemCiphertext: envelope.kemCiphertext,
                nonce: envelope.nonce,
                ciphertextWithTag: ciphertextWithTag,
                signer: signEnvelope
            )
        } catch {
            NSLog("[send] envelope build failed: \(error)")
            return failPermanently(localId: localId, code: -5)
        }
        let envelopeBase64 = envelopeBytes.base64EncodedString()

        // 4. POST. The durable pending row already exists (step 2.5); on
        // success we drop it + bind the server id atomically, otherwise we
        // leave it for OutboxService (transient) or drop it (permanent).
        do {
            let resp = try await api.sendMessage(
                envelopeBase64: envelopeBase64,
                sentAt: sentAt,
                replyToId: replyTo,
                sessionToken: sessionToken()
            )
            do {
                try store.completePendingSend(
                    pendingId: localId, messageLocalId: localId, serverId: resp.id
                )
            } catch {
                // Server has it; the durable row also remains, so
                // OutboxService will re-send (server dedups) and reconcile.
                NTLogger.messaging.error("completePendingSend failed: \(error)")
            }
            return .sentToServer(serverId: resp.id, localId: localId)
        } catch APIClient.SendError.recipientDeviceRotated {
            // The unsealed durable row re-resolves the current device on retry.
            return deferToOutbox(localId: localId)
        } catch APIClient.SendError.retryable {
            return deferToOutbox(localId: localId)
        } catch APIClient.SendError.http(let code, let body) {
            if code == 401 {
                // Auth failure (restore invalidated the token) — never
                // permanent. Force a refresh now so the durable row's retry
                // uses a fresh token instead of waiting for an unrelated path,
                // then leave it for the outbox.
                await onAuthFailure?()
                return deferToOutbox(localId: localId)
            }
            if code == 403, body?.reason == "not_authorized" {
                // The recipient had an active device when we resolved keys
                // but lost it before the POST landed (single-device recipient
                // revoked mid-send). This is recoverable by re-enrollment —
                // defer so the outbox re-resolves the current device rather
                // than dropping the message. `recipient_revoked` (deliberate
                // full revocation) and other 4xx stay permanent.
                return deferToOutbox(localId: localId)
            }
            return failPermanently(localId: localId, code: code)
        } catch {
            // Network / transport / unknown — retryable via the durable row.
            return deferToOutbox(localId: localId)
        }
    }

    /// Leave the (already-durable) pending row for OutboxService and mark the
    /// message failed-but-retryable — UNLESS a concurrent outbox already
    /// completed the send (server_id bound). The first POST runs while the
    /// OutboxService timer may already be processing the same durable row, so
    /// the failure write is a CAS guarded on `server_id IS NULL`: success
    /// always wins.
    private func deferToOutbox(localId: String, attemptsSoFar: Int = 1) -> SendOutcome {
        let marked = (try? store.markSendFailedIfUnsent(localId: localId, state: "failed")) ?? false
        if !marked, let sid = sentServerId(localId: localId) {
            // The outbox bound the server id first — the message is sent.
            return .sentToServer(serverId: sid, localId: localId)
        }
        return .enqueuedRetry(localId: localId, attemptsSoFar: attemptsSoFar)
    }

    /// Drop the durable pending row and mark the message permanently failed —
    /// for confirmed terminal conditions (no active device, malformed key,
    /// non-auth 4xx) where retry can't succeed. Guarded against the same
    /// first-send/outbox race: if a concurrent outbox already sent it, do NOT
    /// mark it failed or delete its (already-removed) pending row.
    private func failPermanently(localId: String, code: Int) -> SendOutcome {
        // Mark terminal-failed AND drop the durable pending row in ONE
        // transaction (the pending id equals the localId on the send path).
        // Two separate writes risked a crash in between that returned
        // failed_permanently while leaving the retry row for OutboxService to
        // re-send — a message the user was told had permanently failed.
        let marked = (try? store.failPendingPermanentlyIfUnsent(localId: localId, pendingId: localId)) ?? false
        if !marked, let sid = sentServerId(localId: localId) {
            return .sentToServer(serverId: sid, localId: localId)
        }
        return .failedPermanently(localId: localId, code: code)
    }

    /// The bound server id for a local message, if a (possibly concurrent) send
    /// already completed it.
    private func sentServerId(localId: String) -> String? {
        ((try? store.message(localId: localId)) ?? nil)?.server_id
    }

    /// Stub envelope serialization. Real wire layout — including the
    /// 1297-byte minimum, routing UUIDs, KEM ciphertext, and Ed25519
    /// signature — lands in Sprint 2's HybridCryptoService along with
    /// interop vectors. Until then, the bytes are concatenated in a
    /// shape that round-trips through `decodeStubEnvelope` for tests.
    static func encodeStubEnvelope(_ env: Envelope) -> Data {
        var out = Data()
        out.append(env.version)
        out.append(env.senderEphemeralX25519Pub)
        out.append(env.kemCiphertext)
        out.append(env.nonce)
        // ciphertext length (4 bytes big-endian)
        var ctLen = UInt32(env.ciphertext.count).bigEndian
        withUnsafeBytes(of: &ctLen) { out.append(contentsOf: $0) }
        out.append(env.ciphertext)
        out.append(env.tag)
        return out
    }

    static func decodeStubEnvelope(_ bytes: Data) throws -> Envelope {
        // Floor for a zero-length-ciphertext envelope. Use `<` so the
        // exact-floor case (legitimate empty payload) parses; `>` would
        // reject it as malformed.
        guard bytes.count >= 1 + 32 + 1088 + 12 + 4 + 16 else {
            throw CryptoServiceError.lengthMismatch(field: "envelope", expected: 1153, actual: bytes.count)
        }
        var i = bytes.startIndex
        let version = bytes[i]; i = bytes.index(after: i)
        let x = bytes[i..<bytes.index(i, offsetBy: 32)]; i = bytes.index(i, offsetBy: 32)
        let kem = bytes[i..<bytes.index(i, offsetBy: 1088)]; i = bytes.index(i, offsetBy: 1088)
        let nonce = bytes[i..<bytes.index(i, offsetBy: 12)]; i = bytes.index(i, offsetBy: 12)
        let ctLenBytes = bytes[i..<bytes.index(i, offsetBy: 4)]; i = bytes.index(i, offsetBy: 4)
        // Build the UInt32 byte-by-byte instead of `load(as:)` so we
        // tolerate unaligned slice base addresses.
        let ctLenArray = [UInt8](ctLenBytes)
        let ctLen = (Int(ctLenArray[0]) << 24)
            | (Int(ctLenArray[1]) << 16)
            | (Int(ctLenArray[2]) << 8)
            |  Int(ctLenArray[3])
        let ct = bytes[i..<bytes.index(i, offsetBy: ctLen)]; i = bytes.index(i, offsetBy: ctLen)
        let tag = bytes[i..<bytes.index(i, offsetBy: 16)]
        return Envelope(
            version: version,
            senderEphemeralX25519Pub: Data(x),
            kemCiphertext: Data(kem),
            nonce: Data(nonce),
            aad: Data(),       // reconstructed by receiver
            ciphertext: Data(ct),
            tag: Data(tag)
        )
    }

    /// Exponential backoff with ±10% jitter.
    /// `attempts = 1 → 5s, 2 → 20s, 3 → 60s, 4+ → 5m`.
    static func nextDelay(for attempts: Int, base: Date) -> Date {
        let coreSeconds: Double
        switch attempts {
        case 1: coreSeconds = 5
        case 2: coreSeconds = 20
        case 3: coreSeconds = 60
        default: coreSeconds = 300
        }
        let jitter = Double.random(in: -0.1...0.1) * coreSeconds
        return base.addingTimeInterval(coreSeconds + jitter)
    }
}
