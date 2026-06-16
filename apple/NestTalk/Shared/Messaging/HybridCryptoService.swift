import Foundation
import CryptoKit

/// Real hybrid post-quantum AEAD: X25519 + ML-KEM-768 → HKDF-SHA256 →
/// ChaCha20-Poly1305. Replaces `DebugCryptoService` for non-DEBUG paths.
///
/// **CryptoKit MLKEM768.** The current Apple toolchain ships
/// `CryptoKit.MLKEM768`, eliminating the need to vendor `mlkem_native`
/// C sources. The on-the-wire sizes match v0.2.3:
/// `pub` = 1184 bytes, `ciphertext` = 1088 bytes, `sharedSecret` = 32 bytes.
/// Availability is gated to macOS 26 / iOS 26 / Mac Catalyst 26 — the
/// first OS revision shipping ML-KEM in CryptoKit. On older deployment
/// targets the build still compiles; AppRouter falls back to
/// DebugCryptoService and surfaces a "device requires latest OS" CTA
/// in the messaging UI (Sprint 2.5+).
///
/// **Wire format.** Sprint 2's `seal` builds the v0.2.3 envelope shape
/// (1297-byte minimum) — see `EnvelopeWire.serialize`. The receiver
/// reverses via `EnvelopeWire.parse`. The KDF inputs `salt`, `info`,
/// and AAD layout mirror `server/internal/crypto/envelope.go`.
@available(iOS 26.0, macOS 26.0, *)
public final class HybridCryptoService: CryptoService, @unchecked Sendable {

    /// Per-device long-term key bundle. Held in memory after Keychain
    /// load; X25519 + ML-KEM-768 private keys are never serialized
    /// outside the Keychain blob.
    public struct LocalKeyBundle: @unchecked Sendable {
        public let x25519Private: Curve25519.KeyAgreement.PrivateKey
        public let mlkemPrivate: MLKEM768.PrivateKey
        public init(
            x25519Private: Curve25519.KeyAgreement.PrivateKey,
            mlkemPrivate: MLKEM768.PrivateKey
        ) {
            self.x25519Private = x25519Private
            self.mlkemPrivate = mlkemPrivate
        }
    }

    /// HKDF inputs are constants chosen to match the v0.2.3 server's
    /// crypto/envelope.go encoder. Kept here as static lets so the
    /// audit trail is unmissable in code review.
    public enum WireConstants {
        public static let hkdfInfoPrefix = "nesttalk-msg-v1"
        public static let hkdfOutBytes = 32
        public static let aeadNonceBytes = 12
        public static let envelopeVersion: UInt8 = 1
    }

    private let bundle: LocalKeyBundle
    private let selfUserId: String

    public init(bundle: LocalKeyBundle, selfUserId: String) {
        self.bundle = bundle
        self.selfUserId = selfUserId
    }

    public func seal(plaintext: Data, forRecipient recipient: CryptoRecipient, routing: EnvelopeRouting) async throws -> Envelope {
        guard
            let recipientX25519PubBytes = recipient.x25519Pub,
            let recipientMlkemPubBytes = recipient.mlkemPub
        else {
            throw CryptoServiceError.unsupportedRecipient(reason: "recipient missing pubkeys")
        }
        let recipientX25519Pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientX25519PubBytes)
        let recipientMlkemPub = try MLKEM768.PublicKey(rawRepresentation: recipientMlkemPubBytes)

        // Ephemeral X25519 for forward secrecy on the classical leg.
        let ephemeralX25519 = Curve25519.KeyAgreement.PrivateKey()
        let xSharedSecret = try ephemeralX25519.sharedSecretFromKeyAgreement(with: recipientX25519Pub)

        // ML-KEM encapsulation.
        let kemResult = try recipientMlkemPub.encapsulate()
        let kemSharedSecretBytes = kemResult.sharedSecret.withUnsafeBytes { Data($0) }

        // Combine x25519_ss || kem_ss → HKDF → 32-byte symmetric key.
        // info AND aad are the 96-byte routing blob (version + all five
        // routing UUIDs), byte-exact with the v0.2.3 Go reference
        // (server/test/crypto-interop/go_roundtrip_test.go:buildHKDFInfo).
        // Binding routing into the KDF makes a re-routed envelope derive a
        // different key; a conforming peer therefore cannot decrypt it.
        let info = routing.infoBytes()
        let combined = xSharedSecret.withUnsafeBytes { Data($0) } + kemSharedSecretBytes
        let symKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: combined),
            salt: Data(count: 32),   // 32 zero bytes per spec
            info: info,
            outputByteCount: WireConstants.hkdfOutBytes
        )

        // Random 12-byte nonce — fresh per seal (no counter).
        var nonceBytes = Data(count: WireConstants.aeadNonceBytes)
        nonceBytes.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, WireConstants.aeadNonceBytes, buf.baseAddress!)
        }
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)

        let sealed = try ChaChaPoly.seal(plaintext, using: symKey, nonce: nonce, authenticating: info)

        return Envelope(
            version: routing.version,
            senderEphemeralX25519Pub: ephemeralX25519.publicKey.rawRepresentation,
            kemCiphertext: kemResult.encapsulated,
            nonce: nonceBytes,
            aad: info,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
    }

    public func open(_ envelope: Envelope, fromRecipient recipient: CryptoRecipient, routing: EnvelopeRouting) async throws -> Data {
        guard envelope.version == routing.version else {
            throw CryptoServiceError.invalidVersion(envelope.version)
        }
        guard envelope.senderEphemeralX25519Pub.count == Envelope.x25519PubBytes else {
            throw CryptoServiceError.lengthMismatch(field: "senderEphemeralX25519Pub", expected: Envelope.x25519PubBytes, actual: envelope.senderEphemeralX25519Pub.count)
        }
        guard envelope.kemCiphertext.count == Envelope.kemCiphertextBytes else {
            throw CryptoServiceError.lengthMismatch(field: "kemCiphertext", expected: Envelope.kemCiphertextBytes, actual: envelope.kemCiphertext.count)
        }
        guard envelope.nonce.count == Envelope.nonceBytes else {
            throw CryptoServiceError.lengthMismatch(field: "nonce", expected: Envelope.nonceBytes, actual: envelope.nonce.count)
        }

        let senderEphPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.senderEphemeralX25519Pub)
        let xSharedSecret = try bundle.x25519Private.sharedSecretFromKeyAgreement(with: senderEphPub)
        let kemSharedSecret = try bundle.mlkemPrivate.decapsulate(envelope.kemCiphertext)
        let kemSharedSecretBytes = kemSharedSecret.withUnsafeBytes { Data($0) }

        // Rebuild info/aad from the routing the receiver parsed off the
        // wire header — must match the sender's bound bytes or auth fails.
        let info = routing.infoBytes()
        let combined = xSharedSecret.withUnsafeBytes { Data($0) } + kemSharedSecretBytes
        let symKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: combined),
            salt: Data(count: 32),
            info: info,
            outputByteCount: WireConstants.hkdfOutBytes
        )
        let combinedSealed = envelope.nonce + envelope.ciphertext + envelope.tag
        let box = try ChaChaPoly.SealedBox(combined: combinedSealed)
        do {
            return try ChaChaPoly.open(box, using: symKey, authenticating: info)
        } catch {
            throw CryptoServiceError.authenticationFailed
        }
    }
}

/// Composite `message_pubkey` blob used by the enrollment / keys APIs.
/// Wire layout: `x25519_pub(32) || ml_kem_pub(1184)` = 1216 bytes,
/// X25519 first per v0.2.3 convention.
@available(iOS 26.0, macOS 26.0, *)
public enum MessagePubKey {
    public static let totalBytes = 32 + 1184

    public static func compose(x25519: Curve25519.KeyAgreement.PublicKey,
                               mlkem:  MLKEM768.PublicKey) -> Data {
        x25519.rawRepresentation + mlkem.rawRepresentation
    }

    public static func parse(_ blob: Data) throws -> (x25519: Curve25519.KeyAgreement.PublicKey,
                                                      mlkem:  MLKEM768.PublicKey) {
        guard blob.count == totalBytes else {
            throw CryptoServiceError.lengthMismatch(field: "message_pubkey", expected: totalBytes, actual: blob.count)
        }
        let x = blob.prefix(32)
        let m = blob.suffix(1184)
        let xKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: x)
        let mKey = try MLKEM768.PublicKey(rawRepresentation: m)
        return (xKey, mKey)
    }
}
