import Foundation
import Security

/// Tiny Keychain CRUD helper for `kSecClassGenericPassword` blobs.
///
/// Centralizes the pattern used by `EnrolledIdentityStore`,
/// `SessionTokenStore`, and `TransportConfigStore`:
///   * accessibility = `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
///     (matches `DeviceIdentity` / `DatabaseWrapKey` so the
///     first-launch sweep picks up everything in one pass)
///   * `kSecAttrSynchronizable` = false (no iCloud sync, device-local)
///   * upsert via `SecItemUpdate` after `errSecDuplicateItem`
enum KeychainBlob {
    enum Error: Swift.Error, CustomStringConvertible {
        case osStatus(OSStatus)
        case notFound
        case malformed

        var description: String {
            switch self {
            case .notFound:           return "KeychainBlob: not found"
            case .malformed:          return "KeychainBlob: malformed value"
            case .osStatus(let s):    return "KeychainBlob: OSStatus \(s)"
            }
        }
    }

    /// macOS routes Sec* queries through the legacy file-based login
    /// keychain by default. Items there are tied to the signing
    /// identity ACL — every Debug build re-signs with a fresh ad-hoc
    /// identity, so the next launch can't read what the previous
    /// launch wrote, and the app forces a fresh invite each run.
    /// `kSecUseDataProtectionKeychain: true` forces the modern
    /// data-protection keychain (same backend iOS uses), where
    /// access is gated by the bundle id rather than per-build ACLs.
    static let useDataProtectionKeychain: Bool = true

    static func read(account: String) throws -> Data {
        #if DEBUG && os(macOS)
        if DevSecureFile.active {
            guard let data = DevSecureFile.read(account: account) else { throw Error.notFound }
            return data
        }
        #endif
        let q: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrAccount               as String: account,
            kSecReturnData                as String: true,
            kSecMatchLimit                as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: useDataProtectionKeychain,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { throw Error.notFound }
        if status != errSecSuccess        { throw Error.osStatus(status) }
        guard let data = out as? Data else { throw Error.malformed }
        return data
    }

    static func upsert(account: String, data: Data) throws {
        #if DEBUG && os(macOS)
        if DevSecureFile.active { try DevSecureFile.write(account: account, data: data); return }
        #endif
        let attributes: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrAccount               as String: account,
            kSecValueData                 as String: data,
            kSecAttrAccessible            as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable        as String: false,
            kSecUseDataProtectionKeychain as String: useDataProtectionKeychain,
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus != errSecDuplicateItem { throw Error.osStatus(addStatus) }

        // Already present — update in place.
        let lookup: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrAccount               as String: account,
            kSecUseDataProtectionKeychain as String: useDataProtectionKeychain,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if updateStatus != errSecSuccess { throw Error.osStatus(updateStatus) }
    }

    static func delete(account: String) throws {
        #if DEBUG && os(macOS)
        if DevSecureFile.active { DevSecureFile.delete(account: account); return }
        #endif
        let q: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrAccount               as String: account,
            kSecUseDataProtectionKeychain as String: useDataProtectionKeychain,
        ]
        let status = SecItemDelete(q as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.osStatus(status)
        }
    }
}
