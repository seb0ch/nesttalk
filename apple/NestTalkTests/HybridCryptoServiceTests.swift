import XCTest
import CryptoKit
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

@available(iOS 26.0, macOS 26.0, *)
final class HybridCryptoServiceTests: XCTestCase {

    private func bundle() throws -> HybridCryptoService.LocalKeyBundle {
        HybridCryptoService.LocalKeyBundle(
            x25519Private: Curve25519.KeyAgreement.PrivateKey(),
            mlkemPrivate: try MLKEM768.PrivateKey()
        )
    }

    func test_seal_open_round_trip_with_real_kem_handshake() async throws {
        let alice = try bundle()
        let bob = try bundle()

        let bobAsRecipient = CryptoRecipient(
            userId: "bob",
            x25519Pub: bob.x25519Private.publicKey.rawRepresentation,
            mlkemPub: bob.mlkemPrivate.publicKey.rawRepresentation
        )

        let aliceCrypto = HybridCryptoService(bundle: alice, selfUserId: "alice")
        let bobCrypto = HybridCryptoService(bundle: bob, selfUserId: "bob")

        let plaintext = Data("hi from alice".utf8)
        var envelope = try await aliceCrypto.seal(plaintext: plaintext, forRecipient: bobAsRecipient)
        XCTAssertEqual(envelope.kemCiphertext.count, 1088)
        XCTAssertEqual(envelope.senderEphemeralX25519Pub.count, 32)
        XCTAssertEqual(envelope.nonce.count, 12)
        XCTAssertEqual(envelope.tag.count, 16)

        // Bob reconstructs the AAD from his side (sender = "alice",
        // recipient = "bob"). Real receivers know the sender id from
        // the routing envelope metadata, not from the AAD bytes.
        envelope = Envelope(
            version: envelope.version,
            senderEphemeralX25519Pub: envelope.senderEphemeralX25519Pub,
            kemCiphertext: envelope.kemCiphertext,
            nonce: envelope.nonce,
            aad: DebugCryptoService.aadFor(senderUserID: "alice", recipientUserID: "bob", version: 1),
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        let opened = try await bobCrypto.open(envelope, fromRecipient: CryptoRecipient(userId: "alice"))
        XCTAssertEqual(opened, plaintext)
    }

    func test_seal_to_wrong_recipient_fails_to_open() async throws {
        let alice = try bundle()
        let bob = try bundle()
        let mallory = try bundle()
        let bobRecipient = CryptoRecipient(
            userId: "bob",
            x25519Pub: bob.x25519Private.publicKey.rawRepresentation,
            mlkemPub: bob.mlkemPrivate.publicKey.rawRepresentation
        )
        var envelope = try await HybridCryptoService(bundle: alice, selfUserId: "alice")
            .seal(plaintext: Data("secret".utf8), forRecipient: bobRecipient)
        envelope = Envelope(
            version: envelope.version,
            senderEphemeralX25519Pub: envelope.senderEphemeralX25519Pub,
            kemCiphertext: envelope.kemCiphertext,
            nonce: envelope.nonce,
            aad: DebugCryptoService.aadFor(senderUserID: "alice", recipientUserID: "bob", version: 1),
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        // Mallory tries to open. Decapsulation either succeeds (with a
        // different shared secret due to ML-KEM's implicit-rejection
        // contract) or throws — both lead to AEAD authentication
        // failure, which is what we assert.
        do {
            _ = try await HybridCryptoService(bundle: mallory, selfUserId: "bob")
                .open(envelope, fromRecipient: CryptoRecipient(userId: "alice"))
            XCTFail("mallory must not open")
        } catch {
            // expected
        }
    }

    func test_message_pubkey_round_trip() throws {
        let x = Curve25519.KeyAgreement.PrivateKey()
        let m = try MLKEM768.PrivateKey()
        let blob = MessagePubKey.compose(x25519: x.publicKey, mlkem: m.publicKey)
        XCTAssertEqual(blob.count, MessagePubKey.totalBytes)

        let (xParsed, mParsed) = try MessagePubKey.parse(blob)
        XCTAssertEqual(xParsed.rawRepresentation, x.publicKey.rawRepresentation)
        XCTAssertEqual(mParsed.rawRepresentation, m.publicKey.rawRepresentation)
    }

    func test_message_pubkey_rejects_wrong_length() {
        XCTAssertThrowsError(try MessagePubKey.parse(Data(count: 1024)))
    }

    func test_envelope_version_mismatch_rejected() async throws {
        let alice = try bundle()
        let bob = try bundle()
        let bobRecipient = CryptoRecipient(
            userId: "bob",
            x25519Pub: bob.x25519Private.publicKey.rawRepresentation,
            mlkemPub: bob.mlkemPrivate.publicKey.rawRepresentation
        )
        let aliceCrypto = HybridCryptoService(bundle: alice, selfUserId: "alice")
        var envelope = try await aliceCrypto.seal(plaintext: Data("v".utf8), forRecipient: bobRecipient)
        envelope = Envelope(
            version: 99,
            senderEphemeralX25519Pub: envelope.senderEphemeralX25519Pub,
            kemCiphertext: envelope.kemCiphertext,
            nonce: envelope.nonce,
            aad: envelope.aad,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        let bobCrypto = HybridCryptoService(bundle: bob, selfUserId: "bob")
        do {
            _ = try await bobCrypto.open(envelope, fromRecipient: CryptoRecipient(userId: "alice"))
            XCTFail("must reject version 99")
        } catch CryptoServiceError.invalidVersion(let v) {
            XCTAssertEqual(v, 99)
        }
    }
}
