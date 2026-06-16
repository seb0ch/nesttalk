import XCTest
import CryptoKit
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

@available(iOS 26.0, macOS 26.0, *)
final class DeviceIdentityV2Tests: XCTestCase {

    private let signingTag = "com.nesttalk.test.signing.\(UUID().uuidString)"
    private let xTag       = "com.nesttalk.test.x25519.\(UUID().uuidString)"
    private let mTag       = "com.nesttalk.test.mlkem.\(UUID().uuidString)"

    override func tearDown() async throws {
        try? DeviceIdentity.delete(tag: signingTag)
        try? DeviceIdentity.delete(tag: xTag)
        try? DeviceIdentity.delete(tag: mTag)
        try await super.tearDown()
    }

    func test_ensureMessageKeys_creates_all_three_atomically() throws {
        let id = try DeviceIdentity.ensureMessageKeys(tag: signingTag, x25519Tag: xTag, mlkem768Tag: mTag)
        XCTAssertNotNil(id.x25519PrivateRaw)
        XCTAssertNotNil(id.mlkem768PrivateRaw)
        XCTAssertEqual(id.x25519PrivateRaw?.count, 32)
        // CryptoKit MLKEM768.integrityCheckedRepresentation is 96 bytes.
        XCTAssertEqual(id.mlkem768PrivateRaw?.count, 96)
    }

    func test_ensureMessageKeys_is_idempotent() throws {
        let first = try DeviceIdentity.ensureMessageKeys(tag: signingTag, x25519Tag: xTag, mlkem768Tag: mTag)
        let again = try DeviceIdentity.ensureMessageKeys(tag: signingTag, x25519Tag: xTag, mlkem768Tag: mTag)
        XCTAssertEqual(first.privateKey.rawRepresentation, again.privateKey.rawRepresentation)
        XCTAssertEqual(first.x25519PrivateRaw, again.x25519PrivateRaw)
        XCTAssertEqual(first.mlkem768PrivateRaw, again.mlkem768PrivateRaw)
    }

    func test_load_returns_full_bundle_after_ensure() throws {
        _ = try DeviceIdentity.ensureMessageKeys(tag: signingTag, x25519Tag: xTag, mlkem768Tag: mTag)
        let loaded = try DeviceIdentity.load(tag: signingTag, x25519Tag: xTag, mlkem768Tag: mTag)
        XCTAssertNotNil(loaded.x25519PrivateRaw)
        XCTAssertNotNil(loaded.mlkem768PrivateRaw)
    }

    func test_message_pubkey_blob_round_trips() throws {
        let id = try DeviceIdentity.ensureMessageKeys(tag: signingTag, x25519Tag: xTag, mlkem768Tag: mTag)
        let blob = try id.messagePubKeyBlob()
        XCTAssertEqual(blob.count, 32 + 1184)

        let (xPub, mPub) = try MessagePubKey.parse(blob)
        let bundle = try id.messageKeyBundle()
        XCTAssertEqual(xPub.rawRepresentation, bundle.x25519Private.publicKey.rawRepresentation)
        XCTAssertEqual(mPub.rawRepresentation, bundle.mlkemPrivate.publicKey.rawRepresentation)
    }

    func test_deleteAll_removes_all_three() throws {
        _ = try DeviceIdentity.ensureMessageKeys(tag: signingTag, x25519Tag: xTag, mlkem768Tag: mTag)
        try DeviceIdentity.deleteAll(tag: signingTag, x25519Tag: xTag, mlkem768Tag: mTag)
        XCTAssertThrowsError(try DeviceIdentity.load(tag: signingTag, x25519Tag: xTag, mlkem768Tag: mTag))
    }
}
