import XCTest
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class KeychainWipeTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "nt.test.keychain-wipe"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_first_launch_runs_sweep_and_sets_flag() {
        XCTAssertFalse(defaults.bool(forKey: KeychainWipe.firstLaunchKey))

        // Pre-populate two items: one with our prefix (sweep should
        // delete it), one without (sweep MUST leave it alone — this
        // is the regression guard for the bug where wipeAll() stomped
        // the user's Apple Development cert private keys).
        // Production code routes every Sec* call through the
        // data-protection keychain (see KeychainBlob.swift) so the
        // wipe target IS that keychain — preload + lookup must use the
        // same scope, otherwise the test is checking a keychain the
        // sweep never touches.
        let ourTag = KeychainWipe.accountPrefix + "test.preload.\(UUID().uuidString)"
        let foreignTag = "com.apple.test.preload.\(UUID().uuidString)"
        let preNT = SecItemAdd([
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrAccount               as String: ourTag,
            kSecValueData                 as String: Data([0xAB]),
            kSecAttrAccessible            as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary, nil)
        let preForeign = SecItemAdd([
            kSecClass                     as String: kSecClassGenericPassword,
            kSecAttrAccount               as String: foreignTag,
            kSecValueData                 as String: Data([0xCD]),
            kSecAttrAccessible            as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary, nil)
        if preNT != errSecSuccess || preForeign != errSecSuccess {
            print("[test] Keychain pre-population partial (NT=\(preNT) foreign=\(preForeign))")
        }

        let outcome = KeychainWipe.wipeIfFirstLaunch(defaults: defaults)
        switch outcome {
        case .wiped:
            break
        case .skippedAlreadyDone:
            XCTFail("first call must not skip")
        }
        XCTAssertTrue(defaults.bool(forKey: KeychainWipe.firstLaunchKey))

        if preNT == errSecSuccess {
            let lookup = SecItemCopyMatching([
                kSecClass                     as String: kSecClassGenericPassword,
                kSecAttrAccount               as String: ourTag,
                kSecMatchLimit                as String: kSecMatchLimitOne,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary, nil)
            XCTAssertEqual(lookup, errSecItemNotFound,
                           "sweep must delete prefix-matched items")
        }
        if preForeign == errSecSuccess {
            // Cleanup ourselves — the sweep must NOT have touched it.
            let lookup = SecItemCopyMatching([
                kSecClass                     as String: kSecClassGenericPassword,
                kSecAttrAccount               as String: foreignTag,
                kSecMatchLimit                as String: kSecMatchLimitOne,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary, nil)
            XCTAssertEqual(lookup, errSecSuccess,
                           "sweep must NOT touch items outside our prefix")
            SecItemDelete([
                kSecClass                     as String: kSecClassGenericPassword,
                kSecAttrAccount               as String: foreignTag,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
        }
    }

    func test_second_launch_skips() {
        defaults.set(true, forKey: KeychainWipe.firstLaunchKey)
        let outcome = KeychainWipe.wipeIfFirstLaunch(defaults: defaults)
        XCTAssertEqual(outcome, .skippedAlreadyDone)
    }

    func test_reset_for_testing_re_arms_sweep() {
        defaults.set(true, forKey: KeychainWipe.firstLaunchKey)
        KeychainWipe._resetForTesting(defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: KeychainWipe.firstLaunchKey))
    }
}
