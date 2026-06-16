import XCTest
import Compression
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class EnrollmentPayloadTests: XCTestCase {

    /// Locked canonical zlib byte vector emitted by the v0.2.3 server-side
    /// encoder (`server/cmd/cli/users.go buildInviteURL`). The server is the
    /// producer and the client is the consumer, so this exact byte string
    /// MUST decode successfully or the wire contract is broken.
    ///
    /// Source: `client/test/enrollment_payload_test.dart` at tag `v0.2.3`.
    private static let lockedCanonicalBlob =
        "eJxUjlFqwCAQRO8y3yZQmi8vIxvdUIlRWTU0hNy9bKDQ_g2P2Z13w5fAsPCUS46e0vQCgy6UWy3SYW9QjW6MGGA1Thqnk9LQ4h6zcmFKsV8wqGNN0budr39_6w6DxnKyOApBYJG59Zm_6aiJZ18OuyyfWvoq0t275mnjlVbdaTkqSGWELZG8B-o5JP-6af4r9xicsB_PTwAAAP__1itO9Q"

    func test_decodes_locked_canonical_server_emitted_blob() {
        let url = "https://nest.example.com/i/\(Self.lockedCanonicalBlob)"
        let payload = EnrollmentPayload.parse(url)
        XCTAssertEqual(payload.code, "canonical-code")
        XCTAssertEqual(payload.bootstrap?.serverAddress, "nest.example.com")
        XCTAssertEqual(payload.bootstrap?.serverPort, 443)
        XCTAssertEqual(payload.bootstrap?.serverName, "cloudflare.com")
        XCTAssertEqual(payload.bootstrap?.realityPublicKey, "canonical-pk")
        XCTAssertEqual(payload.bootstrap?.realityShortID, "cafebabe")
        XCTAssertEqual(payload.apiUuid,  "api-uuid-value")
        XCTAssertEqual(payload.turnUuid, "turn-uuid-value")
    }

    func test_accepts_nesttalk_i_scheme() {
        let blob = try! Self.makeBlob(code: "opaque-code", shortID: "f00d", turn: nil, api: nil)
        let payload = EnrollmentPayload.parse("nesttalk://i/\(blob)")
        XCTAssertEqual(payload.code, "opaque-code")
        XCTAssertEqual(payload.bootstrap?.realityShortID, "f00d")
    }

    func test_accepts_nesttalk_enroll_query_scheme() {
        let blob = try! Self.makeBlob(code: "q-code", shortID: "ab12", turn: nil, api: nil)
        let payload = EnrollmentPayload.parse("nesttalk://enroll?data=\(blob)")
        XCTAssertEqual(payload.code, "q-code")
        XCTAssertEqual(payload.bootstrap?.realityShortID, "ab12")
    }

    func test_rejects_oversized_envelope() {
        let overlong = String(repeating: "a", count: 5 * 1024)
        let payload = EnrollmentPayload.parse("https://nest.example.com/i/\(overlong)")
        XCTAssertFalse(payload.hasRealityBootstrap)
    }

    func test_rejects_unknown_transport_kind() {
        let json: [String: Any] = [
            "v": 1,
            "code": "x",
            "transport": [
                "kind": "something-else",
                "server_addr": "x:443",
                "sni": "x",
                "public_key": "pk",
                "short_id": "sid",
            ],
        ]
        let blob = try! Self.encode(json)
        let payload = EnrollmentPayload.parse("https://nest.example.com/i/\(blob)")
        XCTAssertFalse(payload.hasRealityBootstrap)
    }

    // MARK: - helpers

    private static func makeBlob(
        code: String, shortID: String, turn: String?, api: String?
    ) throws -> String {
        var transport: [String: Any] = [
            "kind": "reality",
            "server_addr": "nest.example.com:443",
            "sni": "cloudflare.com",
            "public_key": "pk",
            "short_id": shortID,
        ]
        if let turn { transport["turn_uuid"] = turn }
        if let api  { transport["api_uuid"]  = api  }
        return try encode(["v": 1, "code": code, "transport": transport])
    }

    /// Mirror of the Go server encoder: `base64url(zlib(json_marshal(payload)))`.
    /// json_marshal emits alphabetised keys; JSONSerialization with
    /// `.sortedKeys` matches that. Equivalent to
    /// `helpers._encodeV2Blob(payload)` in the v0.2.3 Dart test.
    private static func encode(_ payload: [String: Any]) throws -> String {
        let jsonData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        let compressed = try zlibDeflate(jsonData)
        return base64URLEncode(compressed)
    }

    private static func zlibDeflate(_ data: Data) throws -> Data {
        // Use Compression framework raw deflate + manual zlib wrapper
        // (2-byte header + 4-byte Adler32 footer, network byte order).
        let cap = max(data.count * 2, 128)
        var out = Data(count: cap)
        let written = out.withUnsafeMutableBytes { (outBuf: UnsafeMutableRawBufferPointer) -> Int in
            guard let outPtr = outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return data.withUnsafeBytes { (inBuf: UnsafeRawBufferPointer) -> Int in
                guard let inPtr = inBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return compression_encode_buffer(
                    outPtr, cap, inPtr, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else {
            throw NSError(domain: "deflate", code: -1)
        }
        let deflate = out.prefix(written)

        // zlib header: CMF 0x78 (deflate, 32K window) + FLG 0x9c (level 5, no FDICT)
        var wrapped = Data([0x78, 0x9c])
        wrapped.append(deflate)
        var adler = adler32(data).bigEndian
        wrapped.append(Data(bytes: &adler, count: 4))
        return wrapped
    }

    /// Adler-32 over `data`. zlib's wrapper footer.
    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a)             % 65521
        }
        return (b << 16) | a
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class DeviceIdentityTests: XCTestCase {

    private let testTag = "com.nesttalk.test.device-identity-\(UUID().uuidString)"

    override func tearDown() {
        try? DeviceIdentity.delete(tag: testTag)
        super.tearDown()
    }

    func test_roundtrips_through_keychain() throws {
        let created = try DeviceIdentity.createAndPersist(tag: testTag)
        let loaded  = try DeviceIdentity.load(tag: testTag)
        XCTAssertEqual(
            created.publicKey.rawRepresentation,
            loaded.publicKey.rawRepresentation
        )
        XCTAssertEqual(
            created.privateKey.rawRepresentation,
            loaded.privateKey.rawRepresentation
        )
    }

    func test_load_without_persist_throws_notFound() {
        XCTAssertThrowsError(try DeviceIdentity.load(tag: testTag)) { err in
            XCTAssertEqual(err as? KeychainError, KeychainError.notFound)
        }
    }

    func test_createAndPersist_twice_throws_duplicate() throws {
        _ = try DeviceIdentity.createAndPersist(tag: testTag)
        XCTAssertThrowsError(try DeviceIdentity.createAndPersist(tag: testTag)) { err in
            XCTAssertEqual(err as? KeychainError, KeychainError.duplicate)
        }
    }

    func test_sign_and_verify_roundtrip() throws {
        let identity = try DeviceIdentity.createAndPersist(tag: testTag)
        let message = "challenge-payload".data(using: .utf8)!
        let signature = try identity.sign(message)
        XCTAssertTrue(identity.publicKey.isValidSignature(signature, for: message))
        let tampered = "challenge-payload!".data(using: .utf8)!
        XCTAssertFalse(identity.publicKey.isValidSignature(signature, for: tampered))
    }

    func test_delete_is_idempotent() throws {
        try DeviceIdentity.delete(tag: testTag)  // nothing there
        try DeviceIdentity.delete(tag: testTag)  // still nothing — must not throw
    }
}

extension KeychainError: Equatable {
    public static func == (lhs: KeychainError, rhs: KeychainError) -> Bool {
        switch (lhs, rhs) {
        case (.notFound, .notFound),
             (.duplicate, .duplicate),
             (.malformed, .malformed):
            return true
        case (.osStatus(let a), .osStatus(let b)):
            return a == b
        default:
            return false
        }
    }
}
