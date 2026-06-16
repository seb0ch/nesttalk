import XCTest
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class CryptoServiceTests: XCTestCase {

    func test_round_trip_recovers_plaintext() async throws {
        let svc = DebugCryptoService()
        let plaintext = Data("hello family".utf8)
        let recipient = CryptoRecipient(userId: "mom")

        let envelope = try await svc.seal(plaintext: plaintext, forRecipient: recipient)
        XCTAssertEqual(envelope.version, Envelope.currentVersion)
        XCTAssertEqual(envelope.nonce.count, Envelope.nonceBytes)
        XCTAssertEqual(envelope.tag.count, Envelope.tagBytes)
        XCTAssertEqual(envelope.kemCiphertext.count, Envelope.kemCiphertextBytes)
        XCTAssertEqual(envelope.senderEphemeralX25519Pub.count, Envelope.x25519PubBytes)

        let opened = try await svc.open(envelope, fromRecipient: recipient)
        XCTAssertEqual(opened, plaintext)
    }

    func test_mismatched_routing_fails_authentication() async throws {
        // The AEAD AAD is the 96-byte routing blob (version + all five
        // routing UUIDs). Opening with ANY altered routing field must fail
        // authentication — this is the binding that stops a compromised
        // server re-routing or re-attributing a sealed envelope.
        let svc = DebugCryptoService()
        let plaintext = Data([0x01, 0x02, 0x03])
        let recipient = CryptoRecipient(userId: "11111111-1111-1111-1111-111111111111")
        let sealRouting = EnvelopeRouting(
            senderUserId:      "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            senderDeviceId:    "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            recipientUserId:   "11111111-1111-1111-1111-111111111111",
            recipientDeviceId: "cccccccc-cccc-cccc-cccc-cccccccccccc",
            messageId:         "dddddddd-dddd-dddd-dddd-dddddddddddd"
        )
        let envelope = try await svc.seal(plaintext: plaintext, forRecipient: recipient, routing: sealRouting)

        // Same envelope, but the receiver is told a DIFFERENT message id
        // (e.g. a server trying to transplant it onto another message).
        let tamperedRouting = EnvelopeRouting(
            senderUserId:      sealRouting.senderUserId,
            senderDeviceId:    sealRouting.senderDeviceId,
            recipientUserId:   sealRouting.recipientUserId,
            recipientDeviceId: sealRouting.recipientDeviceId,
            messageId:         "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        )
        do {
            _ = try await svc.open(envelope, fromRecipient: recipient, routing: tamperedRouting)
            XCTFail("open must throw when routing differs from the sealed routing")
        } catch CryptoServiceError.authenticationFailed {
            // expected
        }

        // Control: the original routing still opens.
        let opened = try await svc.open(envelope, fromRecipient: recipient, routing: sealRouting)
        XCTAssertEqual(opened, plaintext)
    }

    func test_invalid_version_rejected() async throws {
        let svc = DebugCryptoService()
        let plaintext = Data("x".utf8)
        let recipient = CryptoRecipient(userId: "mom")
        var envelope = try await svc.seal(plaintext: plaintext, forRecipient: recipient)
        envelope = Envelope(
            version: 99,
            senderEphemeralX25519Pub: envelope.senderEphemeralX25519Pub,
            kemCiphertext: envelope.kemCiphertext,
            nonce: envelope.nonce,
            aad: envelope.aad,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        do {
            _ = try await svc.open(envelope, fromRecipient: recipient)
            XCTFail("open must reject unknown version")
        } catch CryptoServiceError.invalidVersion(let v) {
            XCTAssertEqual(v, 99)
        }
    }

    func test_two_seals_produce_distinct_nonces() async throws {
        let svc = DebugCryptoService()
        let plaintext = Data("same".utf8)
        let recipient = CryptoRecipient(userId: "mom")
        let a = try await svc.seal(plaintext: plaintext, forRecipient: recipient)
        let b = try await svc.seal(plaintext: plaintext, forRecipient: recipient)
        XCTAssertNotEqual(a.nonce, b.nonce, "fresh-nonce per seal")
        XCTAssertNotEqual(a.ciphertext, b.ciphertext, "ciphertexts must differ")
    }

    func test_aad_for_is_deterministic_for_inputs() {
        let aad1 = DebugCryptoService.aadFor(senderUserID: "a", recipientUserID: "b", version: 1)
        let aad2 = DebugCryptoService.aadFor(senderUserID: "a", recipientUserID: "b", version: 1)
        XCTAssertEqual(aad1, aad2)
        let aad3 = DebugCryptoService.aadFor(senderUserID: "a", recipientUserID: "c", version: 1)
        XCTAssertNotEqual(aad1, aad3)
    }
}
