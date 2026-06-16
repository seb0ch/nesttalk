import XCTest
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class WireEnvelopeTests: XCTestCase {

    private func encode(xpub: Int, kem: Int, nonce: Int) throws -> Data {
        try WireEnvelope.encode(
            senderUserId: "11111111-1111-1111-1111-111111111111",
            senderDeviceId: "22222222-2222-2222-2222-222222222222",
            recipientUserId: "33333333-3333-3333-3333-333333333333",
            recipientDeviceId: "44444444-4444-4444-4444-444444444444",
            messageId: "55555555-5555-5555-5555-555555555555",
            senderEphemeralX25519Pub: Data(count: xpub),
            kemCiphertext: Data(count: kem),
            nonce: Data(count: nonce),
            ciphertextWithTag: Data(count: 50)
        )
    }

    /// Round-59 design-review fix: encode must FAIL CLOSED on a wrong-length
    /// crypto field instead of zero-padding/truncating it — a normalized field
    /// yields a structurally-valid but undecryptable envelope (silent loss).
    func test_encode_rejects_wrong_length_crypto_fields() {
        XCTAssertThrowsError(try encode(xpub: 31, kem: 1088, nonce: 12), "short X25519 pub must throw")
        XCTAssertThrowsError(try encode(xpub: 33, kem: 1088, nonce: 12), "long X25519 pub must throw")
        XCTAssertThrowsError(try encode(xpub: 32, kem: 1087, nonce: 12), "short KEM ciphertext must throw")
        XCTAssertThrowsError(try encode(xpub: 32, kem: 1088, nonce: 11), "short nonce must throw")
    }

    func test_encode_accepts_exact_lengths_and_round_trips() throws {
        let wire = try encode(xpub: 32, kem: 1088, nonce: 12)
        let parsed = try WireEnvelope.parse(wire)
        XCTAssertEqual(parsed.senderEphemeralX25519Pub.count, 32)
        XCTAssertEqual(parsed.kemCiphertext.count, 1088)
        XCTAssertEqual(parsed.nonce.count, 12)
        XCTAssertEqual(parsed.ciphertextWithTag.count, 50)
        XCTAssertEqual(parsed.senderDeviceId, "22222222-2222-2222-2222-222222222222")
    }
}
