import Foundation
import Security

/// First-launch Keychain sweep.
///
/// **The problem.** iOS Keychain entries with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (and matching macOS
/// classes) **survive app uninstall**. On a fresh reinstall the old
/// device key would still be present, contradicting v0.4.0's
/// "reinstall = new device identity" requirement (design spec §
/// Architecture › Identity).
///
/// **The fix.** On the first launch of any new install — detected via
/// absence of a `UserDefaults` flag, which IS wiped on uninstall — we
/// `SecItemDelete` all generic-password items belonging to this app's
/// keychain access group, then set the flag.
///
/// This mirrors v0.2.3's `SecureStorage.wipeOnFirstLaunch()`.
public enum KeychainWipe {
    /// UserDefaults key gating the first-launch sweep. The value is a
    /// monotonic version stamp so future migrations (e.g., schema
    /// changes that need a forced re-key) can bump it without touching
    /// this file's contract.
    static let firstLaunchKey = "nt.identity.firstLaunchDone.v1"

    /// Result of a sweep call.
    public enum Outcome: Equatable {
        case skippedAlreadyDone
        case wiped(deletedClasses: [String])
    }

    /// Run on app launch — IDEMPOTENT after the first invocation.
    @discardableResult
    public static func wipeIfFirstLaunch(
        defaults: UserDefaults = .standard
    ) -> Outcome {
        if defaults.bool(forKey: firstLaunchKey) {
            return .skippedAlreadyDone
        }
        let deleted = wipeAll()
        defaults.set(true, forKey: firstLaunchKey)
        defaults.synchronize()
        return .wiped(deletedClasses: deleted)
    }

    /// Reset the flag — TEST ONLY. Production code never calls this; it's
    /// here so test cases can re-arm the wiper between scenarios.
    public static func _resetForTesting(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: firstLaunchKey)
    }

    /// Prefix for every Keychain account name we own. The first-launch
    /// sweep deletes ONLY items whose `kSecAttrAccount` starts with
    /// this string — never anything else. Without this filter the
    /// sweep would catch the user's Apple Development signing
    /// certificates, SSH passphrases, browser-saved passwords, and so
    /// on, because on macOS Debug builds the app runs against the
    /// user's login keychain.
    public static let accountPrefix = "com.nesttalk."

    /// Wipe NestTalk-owned Keychain entries. Scope:
    ///   * class = `kSecClassGenericPassword` only (the only class we
    ///     ever write to — DeviceIdentity, DatabaseWrapKey,
    ///     EnrolledIdentityStore, SessionTokenStore,
    ///     TransportConfigStore all use generic-password)
    ///   * account name starts with `accountPrefix`
    ///
    /// Returns the deleted account names (for tests / logging).
    @discardableResult
    public static func wipeAll() -> [String] {
        // Enumerate matching items via SecItemCopyMatching, then delete
        // each by exact account name. This is safer than a class-only
        // SecItemDelete because:
        //   1. SecItemDelete on a class-only query without
        //      kSecAttrAccount can match items the user owns outside
        //      our prefix (older builds did this and accidentally
        //      stomped login-keychain certificates on macOS).
        //   2. We get back the exact list of accounts we deleted so a
        //      test can assert the set.
        let copyQuery: [String: Any] = [
            kSecClass                     as String: kSecClassGenericPassword,
            kSecMatchLimit                as String: kSecMatchLimitAll,
            kSecReturnAttributes          as String: true,
            // Match the read/write path — DeviceIdentity, KeychainBlob,
            // etc. now route through the data-protection keychain on
            // macOS, so the wipe enumerator has to look there too.
            kSecUseDataProtectionKeychain as String: true,
        ]
        var out: CFTypeRef?
        let copyStatus = SecItemCopyMatching(copyQuery as CFDictionary, &out)
        guard copyStatus == errSecSuccess, let entries = out as? [[String: Any]] else {
            // errSecItemNotFound = nothing to delete; anything else is
            // a real error worth surfacing — but we can't recover
            // mid-sweep, so log and move on.
            if copyStatus != errSecItemNotFound && copyStatus != errSecSuccess {
                NSLog("[keychain] wipe enumerate returned OSStatus %d", copyStatus)
            }
            return []
        }

        var deleted: [String] = []
        for entry in entries {
            guard let account = entry[kSecAttrAccount as String] as? String,
                  account.hasPrefix(accountPrefix) else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass                     as String: kSecClassGenericPassword,
                kSecAttrAccount               as String: account,
                kSecUseDataProtectionKeychain as String: true,
            ]
            let s = SecItemDelete(deleteQuery as CFDictionary)
            if s == errSecSuccess {
                deleted.append(account)
            } else if s != errSecItemNotFound {
                NSLog("[keychain] wipe delete %@ returned OSStatus %d", account, s)
            }
        }
        return deleted
    }
}
