import Foundation

/// Resolves and caches recipients' message public keys.
///
/// `GET /api/v1/keys/message/{userId}` returns the active device's
/// `message_pubkey` blob — `x25519_pub(32) || mlkem_pub(1184)`, the
/// same layout `MessagePubKey.compose` produced at enrollment. One
/// active device per user (v0.4.0 invariant), so a per-user cache is
/// the device cache.
public actor RecipientKeysCache {

    public enum KeysError: Error, Equatable {
        case noActiveDevice(userId: String)
        case malformedPubkey(userId: String)
    }

    private let api: APIClient
    private let sessionToken: @Sendable () -> String?
    private var cache: [String: CryptoRecipient] = [:]
    /// Ed25519 device public keys keyed by "userId/deviceId". The
    /// server retains HISTORICAL devices precisely so signatures on
    /// messages spooled before a re-enrollment still verify — keying
    /// by user alone rejected those after rotation.
    private var signingKeys: [String: Data] = [:]
    /// Active (non-revoked) device id per user, from the SAME fetch
    /// that populated `cache`. Senders route the envelope to this id so
    /// the routing device and the encryption keys are one atomic
    /// snapshot — a separate device-id fetch could straddle a
    /// re-enrollment and seal to D1 while the header names D2.
    private var activeDeviceIds: [String: String] = [:]
    /// Users whose full device list has been fetched this session.
    private var devicesFetched: Set<String> = []

    public init(api: APIClient, sessionToken: @escaping @Sendable () -> String?) {
        self.api = api
        self.sessionToken = sessionToken
    }

    public func recipient(for userId: String) async throws -> CryptoRecipient {
        if let hit = cache[userId] { return hit }
        return try await refresh(userId: userId)
    }

    /// The active device id from the SAME snapshot as `recipient(for:)`.
    /// Senders call this AFTER sealing (which warms the cache) so the
    /// routing device id matches the keys the ciphertext was sealed to.
    public func activeDeviceId(for userId: String) async throws -> String {
        if let hit = activeDeviceIds[userId] { return hit }
        _ = try await refresh(userId: userId)
        guard let id = activeDeviceIds[userId] else {
            throw KeysError.noActiveDevice(userId: userId)
        }
        return id
    }

    /// Resolve the recipient's encryption keys AND active device id as
    /// ONE atomic snapshot — read together from the same cache state in
    /// a single actor hop, so an `invalidate` (concurrent 403 rotation)
    /// can't slip between the two and leave ciphertext sealed to device
    /// D1 under a header naming D2. The caller seals with the returned
    /// recipient (keys present → the KeyResolvingCryptoService decorator
    /// passes through without re-resolving) and routes with deviceId.
    public func snapshot(for userId: String) async throws -> (recipient: CryptoRecipient, deviceId: String) {
        if let r = cache[userId], let id = activeDeviceIds[userId] {
            return (r, id)
        }
        let r = try await refresh(userId: userId)
        guard let id = activeDeviceIds[userId] else {
            throw KeysError.noActiveDevice(userId: userId)
        }
        return (r, id)
    }

    public enum SigningKeyResult: Equatable {
        case found(Data)
        case deviceUnknown   // fetch succeeded, device absent — permanent
        case lookupFailed    // couldn't reach the keys endpoint — transient
    }

    /// The sender's Ed25519 public key for a SPECIFIC device (32 bytes)
    /// — the device id comes from the envelope routing header, so a
    /// message signed by a since-revoked device still verifies.
    /// Distinguishes a genuinely absent device (server fetch OK, device
    /// not in the list → permanent; the receiver acks + drops) from a
    /// network failure (→ transient; the receiver defers and retries).
    public func signingKey(for userId: String, deviceId: String) async -> SigningKeyResult {
        let key = userId + "/" + deviceId
        if let hit = signingKeys[key] { return .found(hit) }
        // Miss for this device id: the sender may have re-enrolled since
        // our last fetch (new device id we've never seen). Refresh ONCE
        // regardless of whether the user was fetched before — keying the
        // refresh on `devicesFetched` permanently rejected first
        // messages from every newly enrolled device.
        do {
            try await refresh(userId: userId)
        } catch {
            // `refresh` registers EVERY device's signing key (including
            // revoked ones) before it can throw `noActiveDevice`, so a key
            // populated mid-refresh is usable for verification even though
            // selecting an active device failed (sender's only device was
            // revoked). Only a genuine fetch failure leaves it absent →
            // transient `.lookupFailed`.
            if let hit = signingKeys[key] { return .found(hit) }
            return .lookupFailed
        }
        if let hit = signingKeys[key] { return .found(hit) }
        return .deviceUnknown
    }

    @discardableResult
    private func refresh(userId: String) async throws -> CryptoRecipient {
        let devices = try await api.fetchDevices(forUserId: userId, sessionToken: sessionToken())
        // Register signing keys for ALL devices (including revoked) FIRST,
        // before selecting the active one. The verify path needs a
        // since-revoked device's key to check messages it spooled before
        // revocation — even when the user now has NO active device at all
        // (single-device user mid-re-enroll). Selecting the active device
        // first and throwing on its absence would skip this registration.
        for d in devices {
            if let pub = Data(base64Encoded: d.public_key), pub.count == 32 {
                signingKeys[userId + "/" + d.device_id] = pub
            }
        }
        devicesFetched.insert(userId)
        // Seal/route ONLY to a non-revoked device. A revoked device 403s
        // server-side, and the send path would treat that as a permanent
        // failure and lose the message. No active device → noActiveDevice
        // (retryable; an admin re-enroll publishes a new active device).
        guard let active = devices.first(where: { $0.revoked_at == nil }) else {
            throw KeysError.noActiveDevice(userId: userId)
        }
        guard let blob = Data(base64Encoded: active.message_pubkey),
              blob.count == Envelope.x25519PubBytes + 1184
        else {
            throw KeysError.malformedPubkey(userId: userId)
        }
        let resolved = CryptoRecipient(
            userId: userId,
            x25519Pub: Data(blob.prefix(Envelope.x25519PubBytes)),
            mlkemPub: Data(blob.suffix(1184))
        )
        cache[userId] = resolved
        activeDeviceIds[userId] = active.device_id
        return resolved
    }

    /// Drop a cached entry — call on `recipient_device_rotated` so the
    /// next seal re-fetches the new device's keys. Historical signing
    /// keys are immutable, but the rotation added a NEW device, so the
    /// device-list fetch flag resets too.
    public func invalidate(userId: String) {
        cache[userId] = nil
        activeDeviceIds[userId] = nil
        devicesFetched.remove(userId)
    }
}

/// `CryptoService` decorator that fills in recipient public keys before
/// delegating `seal` to the real hybrid implementation. The message
/// pipeline constructs `CryptoRecipient(userId:)` without key material;
/// this layer resolves it through `RecipientKeysCache` so the services
/// stay key-agnostic. `open` needs only local private keys and passes
/// through.
public final class KeyResolvingCryptoService: CryptoService, @unchecked Sendable {

    private let inner: CryptoService
    private let keys: RecipientKeysCache

    public init(inner: CryptoService, keys: RecipientKeysCache) {
        self.inner = inner
        self.keys = keys
    }

    public func seal(plaintext: Data, forRecipient recipient: CryptoRecipient, routing: EnvelopeRouting) async throws -> Envelope {
        if recipient.x25519Pub != nil, recipient.mlkemPub != nil {
            return try await inner.seal(plaintext: plaintext, forRecipient: recipient, routing: routing)
        }
        let resolved = try await keys.recipient(for: recipient.userId)
        return try await inner.seal(plaintext: plaintext, forRecipient: resolved, routing: routing)
    }

    public func open(_ envelope: Envelope, fromRecipient sender: CryptoRecipient, routing: EnvelopeRouting) async throws -> Data {
        try await inner.open(envelope, fromRecipient: sender, routing: routing)
    }
}
