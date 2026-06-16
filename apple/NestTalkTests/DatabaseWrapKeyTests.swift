import XCTest
import CryptoKit
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class DatabaseWrapKeyTests: XCTestCase {

    private let testTag = "com.nesttalk.test.dbwrap.\(UUID().uuidString)"

    override func tearDown() {
        DatabaseWrapKey.deleteForTesting(tag: testTag)
        super.tearDown()
    }

    func test_load_or_create_persists_and_reloads_same_bytes() throws {
        let k1 = try DatabaseWrapKey.loadOrCreate(tag: testTag)
        let k2 = try DatabaseWrapKey.loadOrCreate(tag: testTag)
        XCTAssertEqual(
            k1.withUnsafeBytes { Data($0) },
            k2.withUnsafeBytes { Data($0) },
            "second load must return the persisted bytes"
        )
        XCTAssertEqual(k1.withUnsafeBytes { $0.count }, DatabaseWrapKey.byteCount)
    }

    func test_aead_round_trip_with_wrap_key() throws {
        let key = try DatabaseWrapKey.loadOrCreate(tag: testTag)
        let plaintext = Data("hello family".utf8)
        let nonce = ChaChaPoly.Nonce()
        let aad = Data("nesttalk.outbox.v1".utf8)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)

        let opened = try ChaChaPoly.open(
            ChaChaPoly.SealedBox(combined: sealed.combined),
            using: key, authenticating: aad
        )
        XCTAssertEqual(opened, plaintext)
    }

    func test_aead_rejects_wrong_key() throws {
        let k1 = try DatabaseWrapKey.loadOrCreate(tag: testTag)
        let k2 = SymmetricKey(size: .bits256)
        let plaintext = Data("private".utf8)
        let aad = Data("aad".utf8)
        let sealed = try ChaChaPoly.seal(plaintext, using: k1, authenticating: aad)
        XCTAssertThrowsError(try ChaChaPoly.open(
            ChaChaPoly.SealedBox(combined: sealed.combined),
            using: k2, authenticating: aad
        ))
    }

    func test_aead_rejects_tampered_aad() throws {
        let k = try DatabaseWrapKey.loadOrCreate(tag: testTag)
        let plaintext = Data([0x01, 0x02, 0x03])
        let sealed = try ChaChaPoly.seal(plaintext, using: k, authenticating: Data("a".utf8))
        XCTAssertThrowsError(try ChaChaPoly.open(
            ChaChaPoly.SealedBox(combined: sealed.combined),
            using: k, authenticating: Data("b".utf8)
        ))
    }

    func test_hex_string_serialization() {
        let key = SymmetricKey(data: Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(key.hexString, String(repeating: "ab", count: 32))
    }
}
