#if DEBUG && os(macOS)
import Foundation

/// DEBUG-only macOS fallback that persists secret blobs as `0600` files
/// under Application Support instead of the Keychain.
///
/// **Why this exists.** A non-sandboxed macOS Debug build is re-signed on
/// every `Cmd+R` with a different code signature. That destabilizes BOTH
/// keychain backends:
///   * the legacy keychain item ACL is tied to the signing identity, and
///   * the data-protection keychain access group on macOS is derived from
///     the signature when no provisioning profile grants
///     `application-identifier`.
/// Either way, the identity blobs (`DeviceIdentity`, `EnrolledIdentity`,
/// `TransportConfig`, `DatabaseWrapKey`) written by one build become
/// unreadable to the next — so the app demands a fresh invite on EVERY
/// launch (and re-submitting a consumed invite yields HTTP 410).
///
/// Files keyed by account name sidestep code-signing entirely and survive
/// rebuilds. The dev machine is the developer's own and already
/// non-sandboxed in Debug, so plaintext-at-rest here is an accepted
/// development convenience. This whole file is compiled out of Release and
/// iOS; production keeps the data-protection keychain, which IS stable
/// under Developer-ID / distribution signing.
///
/// Disabled under XCTest (`active == false`) so the existing keychain-based
/// unit tests keep exercising the real `SecItem` paths unchanged.
enum DevSecureFile {
    /// Off while running tests — the test host has a stable signature and
    /// the suites assert on real Keychain behavior.
    static var active: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    static func read(account: String) -> Data? {
        try? Data(contentsOf: url(for: account))
    }

    /// Throws on any failure so a caller never reports "saved" for a blob
    /// that didn't land (which would resurface as "gone next Cmd+R") or a
    /// secret file that failed to become 0600.
    static func write(account: String, data: Data) throws {
        let fileURL = url(for: account)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )
    }

    static func delete(account: String) {
        try? FileManager.default.removeItem(at: url(for: account))
    }

    private static func directory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("NestTalk/DevKeychain", isDirectory: true)
    }

    /// Account names are dotted identifiers (e.g. `com.nesttalk.device.signing-key`)
    /// with no path separators, so they map straight to a filename.
    private static func url(for account: String) -> URL {
        directory().appendingPathComponent(account).appendingPathExtension("bin")
    }
}
#endif
