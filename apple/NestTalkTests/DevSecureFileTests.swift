#if DEBUG && os(macOS)
import XCTest
@testable import NestTalk_macOS

/// The DEBUG-only macOS file fallback that lets identity blobs survive
/// Cmd+R re-signs (which orphan keychain items). Tests the primitive
/// directly: the store-level integration is gated off under XCTest
/// (`DevSecureFile.active == false`) so the suites keep exercising the
/// real Keychain.
final class DevSecureFileTests: XCTestCase {
    private let account = "com.nesttalk.test.devsecurefile"

    override func tearDown() {
        DevSecureFile.delete(account: account)
        super.tearDown()
    }

    func test_round_trips_and_overwrites_and_deletes() throws {
        XCTAssertNil(DevSecureFile.read(account: account), "absent → nil")

        let first = Data("hello".utf8)
        try DevSecureFile.write(account: account, data: first)
        XCTAssertEqual(DevSecureFile.read(account: account), first, "must read back what was written")

        let second = Data("world!!".utf8)
        try DevSecureFile.write(account: account, data: second)
        XCTAssertEqual(DevSecureFile.read(account: account), second, "write must overwrite in place")

        DevSecureFile.delete(account: account)
        XCTAssertNil(DevSecureFile.read(account: account), "delete must remove the blob")
    }

    /// The blob must be written 0600 — it holds private-key material in dev.
    func test_file_is_owner_only_readable() throws {
        try DevSecureFile.write(account: account, data: Data("secret".utf8))
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let url = base.appendingPathComponent("NestTalk/DevKeychain/\(account).bin")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600, "dev key material must be owner-only")
    }
}
#endif
