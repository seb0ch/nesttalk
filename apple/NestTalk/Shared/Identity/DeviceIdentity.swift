import Foundation
import CryptoKit
import Security

/// Per-install device identity persisted in the Keychain.
///
/// Holds three keypairs:
///
///   * **Ed25519** — the signing identity. Public side is registered
///     via `POST /auth/enroll/complete`; private side signs every
///     enrollment challenge and connect handshake.
///   * **X25519** — classical leg of the hybrid-PQC AEAD. Public side
///     forms the first 32 bytes of the `message_pubkey` blob.
///   * **ML-KEM-768** — post-quantum leg, 1184-byte public, 2400-byte
///     secret per FIPS 203. Public side is bytes 32..1216 of
///     `message_pubkey`.
///
/// **Sprint 2 expansion.** Pre-Sprint-2 DeviceIdentity held only the
/// Ed25519 key — the spike's enrollment used a placeholder
/// message_pubkey. Sprint 2 grows the type to all three under
/// dedicated Keychain tags so atomic create / atomic delete still
/// hold (a partial create-Ed25519-but-fail-to-create-X25519 path
/// rolls back any stored bytes before throwing).
///
/// Storage: Keychain generic password under each tag, flags
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` + synchronizable
/// `false` — no iCloud/iPad sync; device-local; unlocked after first
/// unlock. The first-launch Keychain wipe (Sprint 0 `KeychainWipe`)
/// removes ALL three on a fresh install.
public struct DeviceIdentity: Equatable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public var publicKey: Curve25519.Signing.PublicKey { privateKey.publicKey }

    /// Optional message-keypair material — populated when the install
    /// has gone through the Sprint-2 enrollment flow. The stub
    /// `createAndPersist()` path leaves these nil; live `enroll()`
    /// fills them via `ensureMessageKeys()`.
    public let x25519PrivateRaw: Data?
    public let mlkem768PrivateRaw: Data?

    public init(privateKey: Curve25519.Signing.PrivateKey,
                x25519PrivateRaw: Data? = nil,
                mlkem768PrivateRaw: Data? = nil) {
        self.privateKey = privateKey
        self.x25519PrivateRaw = x25519PrivateRaw
        self.mlkem768PrivateRaw = mlkem768PrivateRaw
    }

    public static func == (lhs: DeviceIdentity, rhs: DeviceIdentity) -> Bool {
        lhs.privateKey.rawRepresentation == rhs.privateKey.rawRepresentation &&
        lhs.x25519PrivateRaw == rhs.x25519PrivateRaw &&
        lhs.mlkem768PrivateRaw == rhs.mlkem768PrivateRaw
    }

    /// Sign arbitrary data with the device private key (Ed25519).
    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }

    // MARK: - Keychain persistence

    public static let defaultTag       = "com.nesttalk.device.signing-key"
    public static let x25519Tag        = "com.nesttalk.device.x25519-key"
    public static let mlkem768Tag      = "com.nesttalk.device.mlkem-key"

    /// Create a fresh Ed25519 keypair and persist its private-key bytes into
    /// the Keychain under `tag`. Returns the created identity. Fails if a key
    /// with the same tag already exists — callers should call `delete` first
    /// when they want to roll.
    @discardableResult
    public static func createAndPersist(tag: String = defaultTag) throws -> DeviceIdentity {
        let priv = Curve25519.Signing.PrivateKey()
        try persist(priv, tag: tag)
        return DeviceIdentity(privateKey: priv)
    }

    /// Load the persisted identity. Reads all three keys; if X25519 or
    /// ML-KEM material is absent (pre-Sprint-2 installs, or fresh ones
    /// before `ensureMessageKeys()` ran) returns nil for those slots.
    /// Throws `notFound` if even the Ed25519 key is missing.
    public static func load(tag: String = defaultTag,
                            x25519Tag: String = x25519Tag,
                            mlkem768Tag: String = mlkem768Tag) throws -> DeviceIdentity {
        let data = try readKeyData(tag: tag)
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        let xRaw = try? readKeyData(tag: x25519Tag)
        let mRaw = try? readKeyData(tag: mlkem768Tag)
        return DeviceIdentity(privateKey: priv, x25519PrivateRaw: xRaw, mlkem768PrivateRaw: mRaw)
    }

    /// Delete every stored device-identity Keychain entry — used by
    /// re-enroll / wipe paths so all three keys roll together.
    public static func deleteAll(tag: String = defaultTag,
                                 x25519Tag: String = x25519Tag,
                                 mlkem768Tag: String = mlkem768Tag) throws {
        try delete(tag: tag)
        try delete(tag: x25519Tag)
        try delete(tag: mlkem768Tag)
    }

    /// Delete any stored key at `tag`. No-op if nothing is there.
    public static func delete(tag: String = defaultTag) throws {
        #if DEBUG && os(macOS)
        if DevSecureFile.active { DevSecureFile.delete(account: tag); return }
        #endif
        let query: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrAccount               as String: tag,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.osStatus(status)
        }
    }

    /// Ensure X25519 + ML-KEM material is persisted. Idempotent: if both
    /// keys already exist, returns the existing identity unchanged.
    /// Otherwise generates fresh material and stores it atomically — if
    /// either persist fails, both are rolled back so we never leave a
    /// half-populated identity behind.
    @available(iOS 26.0, macOS 26.0, *)
    @discardableResult
    public static func ensureMessageKeys(
        tag: String = defaultTag,
        x25519Tag: String = x25519Tag,
        mlkem768Tag: String = mlkem768Tag
    ) throws -> DeviceIdentity {
        // Read each tag exactly once — `try?` collapses an underlying
        // OSStatus error (e.g., errSecAuthFailed if the device is
        // locked) into nil, which would otherwise look like
        // "key absent" and put us on the create+persist path. We treat
        // any non-notFound OSStatus as fatal so a real Keychain fault
        // surfaces immediately instead of silently scheduling a delete
        // of a key that exists on disk but failed to read.
        let signingExisting: Data? = try readOptional(tag: tag)
        let xExisting: Data? = try readOptional(tag: x25519Tag)
        let mExisting: Data? = try readOptional(tag: mlkem768Tag)

        let signingKey: Curve25519.Signing.PrivateKey
        if let data = signingExisting {
            signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        } else {
            signingKey = Curve25519.Signing.PrivateKey()
            try persist(signingKey, tag: tag)
        }

        // Atomicity: if X25519 or ML-KEM persistence fails, we roll
        // back any keys we created in THIS invocation so the on-disk
        // state stays consistent with the doc-comment promise: "either
        // all three are present or none of the new ones are."
        let xRaw: Data
        do {
            if let existing = xExisting {
                xRaw = existing
            } else {
                xRaw = try newX25519AndPersist(tag: x25519Tag)
            }
        } catch {
            if signingExisting == nil { try? delete(tag: tag) }
            throw error
        }

        let mRaw: Data
        do {
            if let existing = mExisting {
                mRaw = existing
            } else {
                mRaw = try newMlkemAndPersist(tag: mlkem768Tag)
            }
        } catch {
            if xExisting == nil       { try? delete(tag: x25519Tag) }
            if signingExisting == nil { try? delete(tag: tag) }
            throw error
        }

        return DeviceIdentity(
            privateKey: signingKey,
            x25519PrivateRaw: xRaw,
            mlkem768PrivateRaw: mRaw
        )
    }

    /// Reads the Keychain entry, returning `nil` ONLY for `notFound`.
    /// Any other OSStatus surfaces as a thrown `KeychainError.osStatus`
    /// so the caller can distinguish "absent" from "present but
    /// inaccessible" (e.g., device locked).
    private static func readOptional(tag: String) throws -> Data? {
        do {
            return try readKeyData(tag: tag)
        } catch KeychainError.notFound {
            return nil
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    public func messageKeyBundle() throws -> HybridCryptoService.LocalKeyBundle {
        guard let xRaw = x25519PrivateRaw,
              let mRaw = mlkem768PrivateRaw else {
            throw KeychainError.notFound
        }
        let x = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: xRaw)
        let m = try MLKEM768.PrivateKey(integrityCheckedRepresentation: mRaw)
        return HybridCryptoService.LocalKeyBundle(x25519Private: x, mlkemPrivate: m)
    }

    @available(iOS 26.0, macOS 26.0, *)
    public func messagePubKeyBlob() throws -> Data {
        let bundle = try messageKeyBundle()
        return MessagePubKey.compose(
            x25519: bundle.x25519Private.publicKey,
            mlkem:  bundle.mlkemPrivate.publicKey
        )
    }

    // MARK: - Internals

    private static func persist(_ priv: Curve25519.Signing.PrivateKey, tag: String) throws {
        try persistRaw(priv.rawRepresentation, tag: tag)
    }

    private static func persistRaw(_ raw: Data, tag: String) throws {
        #if DEBUG && os(macOS)
        if DevSecureFile.active {
            // Add-only semantics: createAndPersist relies on a duplicate
            // throwing so callers roll the key explicitly.
            if DevSecureFile.read(account: tag) != nil { throw KeychainError.duplicate }
            try DevSecureFile.write(account: tag, data: raw)
            return
        }
        #endif
        let add: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrAccount               as String: tag,
            kSecValueData                 as String: raw,
            kSecAttrAccessible            as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable        as String: false,
            // macOS: route through data-protection keychain so item
            // ACLs are bundle-id scoped, not signing-identity scoped.
            // Without this, every Debug re-sign breaks readback —
            // the user gets prompted for a fresh invite each launch.
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            throw KeychainError.duplicate
        }
        if status != errSecSuccess {
            throw KeychainError.osStatus(status)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    fileprivate static func newX25519AndPersist(tag: String) throws -> Data {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let raw = priv.rawRepresentation
        try persistRaw(raw, tag: tag)
        return raw
    }

    @available(iOS 26.0, macOS 26.0, *)
    fileprivate static func newMlkemAndPersist(tag: String) throws -> Data {
        let priv = try MLKEM768.PrivateKey()
        // CryptoKit's MLKEM768.PrivateKey persistence form is
        // `integrityCheckedRepresentation` — a compact seed + integrity
        // tag round-trip-compatible with
        // `MLKEM768.PrivateKey(integrityCheckedRepresentation:)`.
        let raw = priv.integrityCheckedRepresentation
        try persistRaw(raw, tag: tag)
        return raw
    }

    private static func readKeyData(tag: String) throws -> Data {
        #if DEBUG && os(macOS)
        if DevSecureFile.active {
            guard let data = DevSecureFile.read(account: tag) else { throw KeychainError.notFound }
            return data
        }
        #endif
        let query: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrAccount               as String: tag,
            kSecReturnData                as String: true,
            kSecMatchLimit                as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        if status != errSecSuccess       { throw KeychainError.osStatus(status) }
        guard let data = out as? Data else { throw KeychainError.malformed }
        return data
    }
}

public enum KeychainError: Error, CustomStringConvertible {
    case notFound
    case duplicate
    case malformed
    case osStatus(OSStatus)

    public var description: String {
        switch self {
        case .notFound:             return "Keychain: item not found"
        case .duplicate:            return "Keychain: duplicate item"
        case .malformed:            return "Keychain: data malformed"
        case .osStatus(let status): return "Keychain: OSStatus \(status)"
        }
    }
}
