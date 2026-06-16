import Foundation
import CryptoKit
#if canImport(Network)
import Network
#endif

/// Background retry pump for `pending_queue`.
///
/// Wakes on:
///   * a path-restored event from `NWPathMonitor` (Wi-Fi → on, etc.), and
///   * a periodic 30-second poll.
///
/// On each tick, reads rows where `next_retry_at IS NULL OR <= now`, and
/// for each:
///   1. Fast path: POST the pinned `payload` to `/api/v1/messages`.
///   2. On 403 with `active_recipient_device_id != pinned`: unwrap
///      `plaintext_wrapped` (under `dbWrapKey`), re-seal via
///      `CryptoService.seal` against the new device pubkey (Sprint 2
///      adds the actual key fetch), update the row with new payload
///      + pinned id, retry.
///   3. On success: delete pending row, transition messages.state to
///      `"sent_to_server"`.
///   4. On retryable error: bump `attempts`, schedule next backoff.
///      Cap at 8 attempts → `"failed_permanently"`.
public actor OutboxService {

    public enum Tick: Equatable {
        case timer
        case pathRestored
        case manual
    }

    private let store: MessageStore
    private let api: APIClient
    private let crypto: CryptoService
    private let dbWrapKey: SymmetricKey
    private let sessionToken: () -> String?
    private let resolveActiveDeviceForRetry: ((String) async throws -> (recipient: CryptoRecipient, deviceId: String)?)?
    private let selfUserId: () -> String
    private let selfDeviceId: () -> String
    private let signEnvelope: ((Data) throws -> Data)?
    private let now: () -> Date
    /// Invoked on a 401 before rescheduling so a server restore / JWT rotation
    /// forces a session refresh — otherwise the outbox would keep retrying
    /// outgoing sends with the same stale token until some unrelated path
    /// happens to refresh. Mirrors the receive/read/call auth-failure wiring.
    private let onAuthFailure: (() async -> Void)?
    public static let maxAttempts = 8
    private var running = false
    private var ticking = false   // re-entrancy guard for tick(_:)

    #if canImport(Network)
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "nt.outbox.monitor")
    #endif

    public init(
        store: MessageStore,
        api: APIClient,
        crypto: CryptoService,
        dbWrapKey: SymmetricKey,
        sessionToken: @escaping () -> String?,
        resolveActiveDeviceForRetry: ((String) async throws -> (recipient: CryptoRecipient, deviceId: String)?)? = nil,
        selfUserId: @escaping () -> String = { "" },
        selfDeviceId: @escaping () -> String = { "" },
        signEnvelope: ((Data) throws -> Data)? = nil,
        onAuthFailure: (() async -> Void)? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.api = api
        self.crypto = crypto
        self.dbWrapKey = dbWrapKey
        self.sessionToken = sessionToken
        self.resolveActiveDeviceForRetry = resolveActiveDeviceForRetry
        self.selfUserId = selfUserId
        self.selfDeviceId = selfDeviceId
        self.signEnvelope = signEnvelope
        self.onAuthFailure = onAuthFailure
        self.now = now
    }

    /// Boot the path-monitor and the 30-second poll. Idempotent: a
    /// second `start()` while already running is a no-op so we don't
    /// spawn parallel pollers (e.g., on ScenePhase.active toggling
    /// rapidly during state restoration).
    public func start() async {
        guard !running else { return }
        running = true
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { await self?.tick(.pathRestored) }
        }
        monitor.start(queue: monitorQueue)
        #endif
        Task.detached { [weak self] in
            while await self?.running == true {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                await self?.tick(.timer)
            }
        }
    }

    public func stop() {
        running = false
        #if canImport(Network)
        monitor.cancel()
        #endif
    }

    /// One pass over due rows. Test-friendly: tests call this directly
    /// rather than waiting for the path-monitor / 30 s timer.
    ///
    /// Re-entrancy: an in-flight `tick` blocks parallel ticks (path-
    /// monitor + timer can both call here) so we don't double-POST a
    /// pending row whose first attempt hasn't settled yet.
    @discardableResult
    public func tick(_ source: Tick = .manual) async -> [Result<String, Error>] {
        if ticking { return [] }
        ticking = true
        defer { ticking = false }
        guard let due = try? store.pendingDue(now: now()) else { return [] }
        var results: [Result<String, Error>] = []
        for row in due {
            do {
                try await processRow(row)
                results.append(.success(row.id))
            } catch {
                results.append(.failure(error))
            }
        }
        return results
    }

    private func processRow(_ row: MessageStore.PendingMessage) async throws {
        // Empty payload → the original send couldn't resolve recipient
        // keys (transient), so it enqueued unsealed. Seal it now from the
        // wrapped plaintext before the first POST, reusing the same
        // resolve-keys + re-seal path as device rotation.
        if row.payload.isEmpty {
            try await sealUnsealedRow(row)
            return
        }
        let envelopeBase64 = row.payload.base64EncodedString()
        do {
            let resp = try await api.sendMessage(
                envelopeBase64: envelopeBase64,
                sentAt: originalSentAt(row),
                replyToId: row.reply_to_id,
                sessionToken: sessionToken()
            )
            // Success — bind the server id and drop the pending row in ONE
            // transaction (a crash between the two would strand a delivered
            // message with no retry record and no server_id).
            try store.completePendingSend(
                pendingId: row.id, messageLocalId: row.message_id, serverId: resp.id
            )
        } catch APIClient.SendError.recipientDeviceRotated {
            // The 403 device-id hint is ignored: handleRotation resolves
            // the truly-current device + keys atomically.
            try await handleRotation(row: row)
        } catch APIClient.SendError.retryable {
            try bumpAttempts(row: row)
        } catch APIClient.SendError.http(let code, let body) {
            if code == 401 {
                // Auth failure — transient (restore invalidated the token).
                // Force a session refresh (a missed control restore event
                // would otherwise leave us retrying the same stale token until
                // an unrelated path refreshes), then retain + retry.
                await onAuthFailure?()
                try rescheduleAuthRetry(row: row)
            } else if code == 403, row.plaintext_wrapped != nil,
                      sealedUnderStaleSenderDevice(row) || body?.reason == "not_authorized" {
                // Two recoverable 403s, both fixed by re-resolving + re-sealing
                // to the CURRENT device (handleRotation):
                //   - sealedUnderStaleSenderDevice: same-user re-enrollment
                //     rotated OUR sender device; the persisted envelope is
                //     signed by the OLD device, so re-seal under the current one.
                //   - not_authorized: the RECIPIENT lost its active device
                //     (single-device recipient revoked mid-flight). Retrying the
                //     same payload, sealed to the dead device, would 403 forever;
                //     re-resolving recovers once they re-enroll (or bumps
                //     attempts until maxAttempts gives up). `recipient_revoked`
                //     (deliberate full revocation) falls through to permanent.
                try await handleRotation(row: row)
            } else {
                // Non-retryable HTTP (malformed envelope, recipient_revoked,
                // etc.) — permanent.
                try failPermanently(row)
            }
        } catch {
            // Network / unknown — retryable.
            try bumpAttempts(row: row)
        }
    }

    /// True when a sealed pending payload was signed by a sender device id
    /// other than the one we currently hold — i.e. the local device was
    /// re-enrolled after the row was queued. Such an envelope is rejected by
    /// the server (the signed sender_device_id no longer matches the session),
    /// but it is recoverable via re-seal under the current device.
    private func sealedUnderStaleSenderDevice(_ row: MessageStore.PendingMessage) -> Bool {
        guard !row.payload.isEmpty,
              let parsed = try? WireEnvelope.parse(row.payload) else { return false }
        return parsed.senderDeviceId != selfDeviceId()
    }

    /// Resolve the recipient's current {keys, deviceId} for a retry,
    /// handling the resolver's failure modes uniformly. A non-nil return
    /// means the caller may re-seal; a nil return means this tick is already
    /// settled (attempts bumped or auth-rescheduled) and the caller must
    /// return without further work.
    ///   - resolver missing / nil (no keys yet) → bumpAttempts
    ///   - 401 (stale token) → refresh + rescheduleAuthRetry (NOT counted
    ///     toward maxAttempts; auth failures are transient)
    ///   - other throw (network, malformed, recipient has no active device)
    ///     → bumpAttempts (bounded retry)
    private func resolveForRetry(
        row: MessageStore.PendingMessage, recipientUserId: String
    ) async throws -> (recipient: CryptoRecipient, deviceId: String)? {
        guard let resolver = resolveActiveDeviceForRetry else {
            try bumpAttempts(row: row)
            return nil
        }
        do {
            guard let snap = try await resolver(recipientUserId) else {
                try bumpAttempts(row: row)
                return nil
            }
            return snap
        } catch APIClient.SendError.http(let code, _) where code == 401 {
            await onAuthFailure?()
            try rescheduleAuthRetry(row: row)
            return nil
        } catch {
            try bumpAttempts(row: row)
            return nil
        }
    }

    private func handleRotation(
        row: MessageStore.PendingMessage
    ) async throws {
        // If the caller didn't wire a key resolver, we still bump
        // attempts so the row eventually times out.
        guard
            let plaintextWrapped = row.plaintext_wrapped,
            let recipientUserId = row.recipient_user_id
        else {
            try bumpAttempts(row: row)
            return
        }
        guard let snap = try await resolveForRetry(row: row, recipientUserId: recipientUserId) else {
            return
        }
        let freshRecipient = snap.recipient
        // Seal AND route to the SAME device the snapshot resolved — never
        // the device id from the 403 body. That `active_recipient_device_id`
        // is only a stale "your pin is wrong" hint; by the time the resolver
        // fetched fresh keys the active device may have rotated AGAIN, and
        // snap.{recipient,deviceId} are the atomic, consistent pair. Mixing
        // snap's keys with the 403's device id would seal ciphertext for
        // one device while the signed header names another — the server
        // rejects it and the retry is wasted.
        let activeDeviceId = snap.deviceId
        let plaintext: Data
        do {
            plaintext = try PlaintextWrap.open(plaintextWrapped, using: dbWrapKey)
        } catch {
            // Key mismatch (would only happen if the wrap key was
            // somehow rotated mid-flight) — drop and mark permanent.
            try failPermanently(row)
            return
        }
        // The wire message_id must stay STABLE across retries (it binds
        // the AEAD and is the recipient's dedup key), so reuse the row's
        // message_id rather than minting a fresh one.
        let messageId = row.message_id ?? row.id
        let routing = EnvelopeRouting(
            senderUserId: selfUserId(),
            senderDeviceId: selfDeviceId(),
            recipientUserId: recipientUserId,
            recipientDeviceId: activeDeviceId,
            messageId: messageId
        )
        let envelope = try await crypto.seal(plaintext: plaintext, forRecipient: freshRecipient, routing: routing)
        // Re-seal must produce the REAL wire envelope (the same
        // 1297-byte layout MessageSendService POSTs) — the server's
        // ParseEnvelope rejects anything else. The fast-path `payload`
        // already carries wire bytes; only this rotation branch
        // rebuilds them.
        let resealed = try WireEnvelope.encode(
            senderUserId: selfUserId(),
            senderDeviceId: selfDeviceId(),
            recipientUserId: recipientUserId,
            recipientDeviceId: activeDeviceId,
            messageId: messageId,
            senderEphemeralX25519Pub: envelope.senderEphemeralX25519Pub,
            kemCiphertext: envelope.kemCiphertext,
            nonce: envelope.nonce,
            ciphertextWithTag: envelope.ciphertext + envelope.tag,
            signer: signEnvelope
        )
        var updated = row
        updated.payload = resealed
        updated.pinned_recipient_device_id = activeDeviceId
        updated.attempts += 1
        // Honor maxAttempts here too: a re-seal that keeps getting rejected
        // (e.g. a recipient 403 not_authorized that never clears) must
        // converge to permanent failure rather than re-sealing forever.
        if updated.attempts >= Self.maxAttempts {
            try failPermanently(row)
            return
        }
        updated.next_retry_at = Int64(MessageSendService.nextDelay(
            for: updated.attempts, base: now()
        ).timeIntervalSince1970 * 1000)
        try store.updatePending(updated)
    }

    /// Seal a row that was enqueued unsealed (original send couldn't
    /// resolve recipient keys). Resolves keys + device fresh, seals from
    /// the wrapped plaintext, POSTs. Success lifts the message;
    /// unresolved keys bump attempts (retry later); a 403 rotation falls
    /// through to the normal rotation handler.
    private func sealUnsealedRow(_ row: MessageStore.PendingMessage) async throws {
        guard
            let plaintextWrapped = row.plaintext_wrapped,
            let recipientUserId = row.recipient_user_id
        else {
            // Keys still unresolvable (endpoint down) — retry later.
            try bumpAttempts(row: row)
            return
        }
        guard let snap = try await resolveForRetry(row: row, recipientUserId: recipientUserId) else {
            return
        }
        let freshRecipient = snap.recipient
        let deviceId = snap.deviceId
        let plaintext: Data
        do {
            plaintext = try PlaintextWrap.open(plaintextWrapped, using: dbWrapKey)
        } catch {
            try failPermanently(row)
            return
        }
        let messageId = row.message_id ?? row.id
        let routing = EnvelopeRouting(
            senderUserId: selfUserId(),
            senderDeviceId: selfDeviceId(),
            recipientUserId: recipientUserId,
            recipientDeviceId: deviceId,
            messageId: messageId
        )
        let envelope = try await crypto.seal(plaintext: plaintext, forRecipient: freshRecipient, routing: routing)
        let wire = try WireEnvelope.encode(
            senderUserId: selfUserId(),
            senderDeviceId: selfDeviceId(),
            recipientUserId: recipientUserId,
            recipientDeviceId: deviceId,
            messageId: messageId,
            senderEphemeralX25519Pub: envelope.senderEphemeralX25519Pub,
            kemCiphertext: envelope.kemCiphertext,
            nonce: envelope.nonce,
            ciphertextWithTag: envelope.ciphertext + envelope.tag,
            signer: signEnvelope
        )
        do {
            let resp = try await api.sendMessage(
                envelopeBase64: wire.base64EncodedString(),
                sentAt: originalSentAt(row), replyToId: row.reply_to_id, sessionToken: sessionToken()
            )
            try store.completePendingSend(
                pendingId: row.id, messageLocalId: row.message_id, serverId: resp.id
            )
        } catch APIClient.SendError.recipientDeviceRotated {
            // Persist the now-sealed payload, then let rotation re-seal
            // against the freshly-resolved device (the 403 hint is ignored).
            var updated = row
            updated.payload = wire
            updated.pinned_recipient_device_id = deviceId
            try store.updatePending(updated)
            try await handleRotation(row: updated)
        } catch APIClient.SendError.http(let code, let body) {
            if code == 401 {
                await onAuthFailure?()
                var updated = row
                updated.payload = wire
                updated.pinned_recipient_device_id = deviceId
                try? store.updatePending(updated)
                try rescheduleAuthRetry(row: updated)
            } else if code == 403, body?.reason == "not_authorized" {
                // The recipient lost its active device between our fresh
                // resolve and this POST (revoked mid-flight). Keep the row
                // UNSEALED (don't persist `wire`) so the next tick re-resolves
                // the current device and re-seals; recovers on re-enroll, or
                // bumpAttempts caps it. recipient_revoked falls through to drop.
                try bumpAttempts(row: row)
            } else {
                try failPermanently(row)
            }
        } catch {
            // Persist the sealed payload so the next retry uses the
            // fast path instead of re-resolving.
            var updated = row
            updated.payload = wire
            updated.pinned_recipient_device_id = deviceId
            try? store.updatePending(updated)
            try bumpAttempts(row: updated)
        }
    }

    /// The message's ORIGINAL send time — reused on every retry/reseal so
    /// the server's ordering doesn't shift. Falls back to now() only for
    /// pre-v5 rows that predate the persisted timestamp.
    private func originalSentAt(_ row: MessageStore.PendingMessage) -> Date {
        if let ms = row.original_sent_at {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        }
        return now()
    }

    /// Terminal failure for a pending row: mark the message
    /// `failed_permanently` AND drop the pending row in ONE transaction,
    /// guarded by `server_id IS NULL` so a concurrently-successful send is
    /// never downgraded (phantom-fail). Replaces the old non-atomic
    /// `deletePending` + unguarded `updateMessage` pair, which could (a) crash
    /// between the two writes leaving a stranded row, or (b) clobber a row a
    /// racing success had already bound a server id to.
    private func failPermanently(_ row: MessageStore.PendingMessage) throws {
        _ = try store.failPendingPermanentlyIfUnsent(
            localId: row.message_id ?? row.id, pendingId: row.id
        )
    }

    private func bumpAttempts(row: MessageStore.PendingMessage) throws {
        var updated = row
        updated.attempts += 1
        if updated.attempts >= Self.maxAttempts {
            try failPermanently(row)
            return
        }
        updated.next_retry_at = Int64(MessageSendService.nextDelay(
            for: updated.attempts, base: now()
        ).timeIntervalSince1970 * 1000)
        try store.updatePending(updated)
    }

    /// Reschedule a row after an AUTH failure (401) WITHOUT incrementing
    /// the permanent-failure counter. A server restore invalidates tokens
    /// while refresh is async, so an outbox tick in that window must never
    /// discard the message — it retries indefinitely (auth recovers via
    /// SessionRefresher), bounded only by the backoff schedule.
    private func rescheduleAuthRetry(row: MessageStore.PendingMessage) throws {
        var updated = row
        updated.next_retry_at = Int64(MessageSendService.nextDelay(
            for: max(1, updated.attempts), base: now()
        ).timeIntervalSince1970 * 1000)
        try store.updatePending(updated)
    }
}
