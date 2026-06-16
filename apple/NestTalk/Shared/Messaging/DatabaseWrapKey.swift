import Foundation
import CryptoKit
import Security

/// 32-byte symmetric key used for two purposes:
///
/// 1. **SQLCipher passphrase.** The on-disk message-history database
///    (`MessageStore`) is encrypted with this key via SQLCipher's
///    `PRAGMA key`. Without it the file is opaque ciphertext.
/// 2. **OutboxService plaintext wrap.** Sprint-1's `pending_queue`
///    stores `plaintext_wrapped` — message bodies sealed under this key
///    so we can re-seal with a fresh recipient pubkey on device-rotation
///    retry without keeping plaintext at rest.
///
/// Persistence: Keychain `kSecClassGenericPassword`, account
/// `com.nesttalk.dbwrap.v1`, accessible
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (matches PushKit
/// background-access requirements). Survives all-but-uninstall; the
/// `KeychainWipe` first-launch sweep deletes the entry on a reinstall,
/// the next launch lazily regenerates.
public enum DatabaseWrapKey {
    public static let tag = "com.nesttalk.dbwrap.v1"
    public static let byteCount = 32

    public enum Error: Swift.Error, CustomStringConvertible {
        case osStatus(OSStatus)
        case malformed(actualBytes: Int)

        public var description: String {
            switch self {
            case .osStatus(let s):       return "DatabaseWrapKey: OSStatus \(s)"
            case .malformed(let bytes):  return "DatabaseWrapKey: stored bytes=\(bytes), expected=\(DatabaseWrapKey.byteCount)"
            }
        }
    }

    /// Load the persisted key, or generate-and-persist if absent.
    /// Idempotent across calls — repeated invocations return the same
    /// key for the same install.
    ///
    /// Race window: two callers (e.g., main app + a future Notification
    /// Service Extension cohabiting the access group) can both observe
    /// "not present" and race to insert. The second SecItemAdd returns
    /// `errSecDuplicateItem`; we recover by re-reading the now-present
    /// key. Without this recovery, the loser of the race throws and
    /// crashes the surrounding bootstrap.
    public static func loadOrCreate(tag: String = tag) throws -> SymmetricKey {
        if let existing = try? read(tag: tag) {
            return existing
        }
        let fresh = SymmetricKey(size: .bits256)
        do {
            try persist(fresh, tag: tag)
            return fresh
        } catch Error.osStatus(let status) where status == errSecDuplicateItem {
            return try read(tag: tag)
        }
    }

    /// TEST helper: delete any persisted key. Production code never
    /// calls this; the first-launch sweep handles uninstall semantics.
    public static func deleteForTesting(tag: String = tag) {
        let q: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrAccount               as String: tag,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: - Internals

    private static func read(tag: String) throws -> SymmetricKey {
        #if DEBUG && os(macOS)
        if DevSecureFile.active {
            guard let data = DevSecureFile.read(account: tag), data.count == byteCount else {
                throw Error.osStatus(errSecItemNotFound)
            }
            return SymmetricKey(data: data)
        }
        #endif
        let q: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrAccount               as String: tag,
            kSecReturnData                as String: true,
            kSecMatchLimit                as String: kSecMatchLimitOne,
            // Match DeviceIdentity / KeychainBlob AND the KeychainWipe
            // enumerator — all use the data-protection keychain on macOS, so
            // the wrap key is covered by the first-launch reinstall sweep.
            kSecUseDataProtectionKeychain as String: true,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { throw Error.osStatus(status) }
        if status != errSecSuccess       { throw Error.osStatus(status) }
        guard let data = out as? Data, data.count == byteCount else {
            throw Error.malformed(actualBytes: (out as? Data)?.count ?? -1)
        }
        return SymmetricKey(data: data)
    }

    private static func persist(_ key: SymmetricKey, tag: String) throws {
        let raw = key.withUnsafeBytes { Data($0) }
        #if DEBUG && os(macOS)
        if DevSecureFile.active {
            // Mirror SecItemAdd's add-only contract so loadOrCreate's
            // duplicate-race recovery (re-read on errSecDuplicateItem) holds.
            if DevSecureFile.read(account: tag) != nil { throw Error.osStatus(errSecDuplicateItem) }
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
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            throw Error.osStatus(status)
        }
    }
}

/// Hex string of the wrap-key bytes. SQLCipher accepts a hex passphrase
/// directly via `PRAGMA key = "x'<hex>'"` — preferred over a string-form
/// passphrase (avoids KDF iterations on every open).
public extension SymmetricKey {
    var hexString: String {
        withUnsafeBytes { buf in
            buf.map { String(format: "%02x", $0) }.joined()
        }
    }
}
