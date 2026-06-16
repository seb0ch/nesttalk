import Foundation
import CryptoKit

/// Hybrid post-quantum envelope wire format.
///
/// Layout follows v0.2.3's `server/internal/crypto/envelope.go`. Field
/// sizes are constants so misaligned versions / KEM ciphertexts are
/// caught at the protocol boundary rather than as decryption failures.
public struct Envelope: Equatable, Sendable {
    public static let currentVersion: UInt8 = 1
    public static let x25519PubBytes = 32
    public static let kemCiphertextBytes = 1088
    public static let nonceBytes = 12
    public static let tagBytes = 16

    public let version: UInt8
    public let senderEphemeralX25519Pub: Data    // 32 bytes
    public let kemCiphertext: Data               // 1088 bytes
    public let nonce: Data                       // 12 bytes
    public let aad: Data                         // reconstructed by receiver
    public let ciphertext: Data
    public let tag: Data                         // 16 bytes

    public init(
        version: UInt8 = Envelope.currentVersion,
        senderEphemeralX25519Pub: Data,
        kemCiphertext: Data,
        nonce: Data,
        aad: Data,
        ciphertext: Data,
        tag: Data
    ) {
        self.version = version
        self.senderEphemeralX25519Pub = senderEphemeralX25519Pub
        self.kemCiphertext = kemCiphertext
        self.nonce = nonce
        self.aad = aad
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

/// Recipient handle used by the seal call.
///
/// Sprint 1 ships only `userId`; Sprint 2 adds the real recipient pubkeys
/// (`x25519Pub`, `mlkemPub`) once enrollment carries them. The stub
/// `DebugCryptoService` ignores everything except `userId`.
public struct CryptoRecipient: Equatable, Sendable {
    public let userId: String
    public let x25519Pub: Data?
    public let mlkemPub: Data?

    public init(userId: String, x25519Pub: Data? = nil, mlkemPub: Data? = nil) {
        self.userId = userId
        self.x25519Pub = x25519Pub
        self.mlkemPub = mlkemPub
    }
}

/// Errors raised at the crypto boundary. Test code asserts on these
/// (not on string matches).
public enum CryptoServiceError: Error, Equatable {
    case invalidVersion(UInt8)
    case lengthMismatch(field: String, expected: Int, actual: Int)
    case authenticationFailed
    case unsupportedRecipient(reason: String)
}

/// The routing context that BINDS an envelope's AEAD to its wire header.
///
/// The v0.2.3 protocol folds the version plus all five routing UUIDs into
/// BOTH the HKDF `info` and the AEAD AAD (see
/// `server/test/crypto-interop/go_roundtrip_test.go`,
/// `buildHKDFInfo`). A conforming peer derives a different key — and
/// authentication fails — if any routing field is altered, so a
/// compromised server cannot re-attribute, re-route, or transplant a
/// sealed envelope. The sender and receiver MUST pass byte-identical
/// routing; the receiver reconstructs it from the parsed wire header.
public struct EnvelopeRouting: Sendable, Equatable {
    /// `"nesttalk-msg-v1"` — the 15-byte ASCII prefix on the info blob.
    public static let infoPrefix = "nesttalk-msg-v1"
    /// version(1) + 5 × 16-byte UUID + 15-byte prefix = 96 bytes.
    public static let infoLength = 96

    public let version: UInt8
    public let senderUserId: String
    public let senderDeviceId: String
    public let recipientUserId: String
    public let recipientDeviceId: String
    public let messageId: String

    public init(
        version: UInt8 = Envelope.currentVersion,
        senderUserId: String,
        senderDeviceId: String,
        recipientUserId: String,
        recipientDeviceId: String,
        messageId: String
    ) {
        self.version = version
        self.senderUserId = senderUserId
        self.senderDeviceId = senderDeviceId
        self.recipientUserId = recipientUserId
        self.recipientDeviceId = recipientDeviceId
        self.messageId = messageId
    }

    /// Reconstruct routing from a parsed wire envelope — the exact bytes
    /// the sender bound.
    public init(parsed p: WireEnvelope.Parsed) {
        self.init(
            version: p.version,
            senderUserId: p.senderUserId,
            senderDeviceId: p.senderDeviceId,
            recipientUserId: p.recipientUserId,
            recipientDeviceId: p.recipientDeviceId,
            messageId: p.messageId
        )
    }

    /// The 96-byte HKDF-`info` / AEAD-AAD blob:
    /// `"nesttalk-msg-v1"(15) || version(1) || sender_user(16) ||
    /// sender_device(16) || recipient_user(16) || recipient_device(16) ||
    /// message_id(16)`. Routing IDs are the raw 16-byte UUIDs (real UUIDs
    /// round-trip exactly; non-UUID test names are hashed via
    /// `WireEnvelope.uuidBytes`).
    public func infoBytes() -> Data {
        var out = Data()
        out.reserveCapacity(Self.infoLength)
        out.append(Data(Self.infoPrefix.utf8))
        out.append(version)
        out.append((try? WireEnvelope.uuidBytes(senderUserId)) ?? Data(count: 16))
        out.append((try? WireEnvelope.uuidBytes(senderDeviceId)) ?? Data(count: 16))
        out.append((try? WireEnvelope.uuidBytes(recipientUserId)) ?? Data(count: 16))
        out.append((try? WireEnvelope.uuidBytes(recipientDeviceId)) ?? Data(count: 16))
        out.append((try? WireEnvelope.uuidBytes(messageId)) ?? Data(count: 16))
        return out
    }
}

/// Protocol seam between the message pipeline and the cipher choice.
///
/// Implementations:
/// - `DebugCryptoService` — Sprint-1 stub. AEAD with an all-zero session
///   key. **DEBUG-only** (gated by `#if !DEBUG fatalError`); refuses to
///   instantiate in Release builds.
/// - `HybridCryptoService` — Sprint 2. Real X25519 + ML-KEM-768 → HKDF
///   → ChaCha20-Poly1305, byte-compatible with v0.2.3 server.
public protocol CryptoService: AnyObject, Sendable {
    func seal(plaintext: Data, forRecipient: CryptoRecipient, routing: EnvelopeRouting) async throws -> Envelope
    func open(_ envelope: Envelope, fromRecipient: CryptoRecipient, routing: EnvelopeRouting) async throws -> Data
}

/// Stub crypto service. AEAD-seals plaintext under an all-zero session
/// key — proves the wire contract end-to-end without committing to the
/// real hybrid-PQC layout. Replaced by `HybridCryptoService` in
/// Sprint 2 Task 2.2.
///
/// **REFUSES TO RUN UNDER `Release`.** A `Release` build that
/// instantiates `DebugCryptoService` traps via `fatalError` to prevent
/// shipping a build whose envelopes carry plaintext-grade traffic.
public final class DebugCryptoService: CryptoService, @unchecked Sendable {
    private let sessionKey: SymmetricKey
    private let selfUserId: String

    public init(selfUserId: String = "self") {
        #if !DEBUG
        fatalError("DebugCryptoService disabled in Release — wire HybridCryptoService instead.")
        #else
        self.sessionKey = SymmetricKey(data: Data(repeating: 0, count: 32))
        self.selfUserId = selfUserId
        #endif
    }

    public func seal(plaintext: Data, forRecipient recipient: CryptoRecipient, routing: EnvelopeRouting) async throws -> Envelope {
        // Generate a random 12-byte nonce — same shape as the production
        // envelope; randomness keeps repeated identical plaintexts from
        // sealing to identical ciphertexts at the wire layer.
        var nonceBytes = Data(count: Envelope.nonceBytes)
        nonceBytes.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, Envelope.nonceBytes, buf.baseAddress!)
        }
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        // AAD = the spec-mandated 96-byte routing blob (same as the HKDF
        // info the production cipher derives the key from), so this stub
        // binds routing exactly like HybridCryptoService.
        let aad = routing.infoBytes()

        let sealed = try ChaChaPoly.seal(plaintext, using: sessionKey, nonce: nonce, authenticating: aad)
        return Envelope(
            version: routing.version,
            senderEphemeralX25519Pub: Data(repeating: 0, count: Envelope.x25519PubBytes),
            kemCiphertext: Data(repeating: 0, count: Envelope.kemCiphertextBytes),
            nonce: nonceBytes,
            aad: aad,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
    }

    public func open(_ envelope: Envelope, fromRecipient recipient: CryptoRecipient, routing: EnvelopeRouting) async throws -> Data {
        guard envelope.version == routing.version else {
            throw CryptoServiceError.invalidVersion(envelope.version)
        }
        guard envelope.nonce.count == Envelope.nonceBytes else {
            throw CryptoServiceError.lengthMismatch(field: "nonce", expected: Envelope.nonceBytes, actual: envelope.nonce.count)
        }
        let nonce = try ChaChaPoly.Nonce(data: envelope.nonce)
        let combined = nonce.withUnsafeBytes { Data($0) } + envelope.ciphertext + envelope.tag
        let box = try ChaChaPoly.SealedBox(combined: combined)
        do {
            // Authoritative AAD comes from routing, NOT envelope.aad — the
            // receiver passes routing parsed from the wire header, so a
            // mismatched/forged aad can't slip through.
            return try ChaChaPoly.open(box, using: sessionKey, authenticating: routing.infoBytes())
        } catch {
            throw CryptoServiceError.authenticationFailed
        }
    }

    /// AAD composition. Mirrors the v0.2.3 Go encoder shape so
    /// `HybridCryptoService` can reuse this helper unchanged in Sprint 2.
    public static func aadFor(senderUserID: String, recipientUserID: String, version: UInt8) -> Data {
        var aad = Data()
        aad.append(Data(senderUserID.utf8))
        aad.append(Data(recipientUserID.utf8))
        aad.append(version)
        return aad
    }

    fileprivate func aadFor(senderUserID: String, recipientUserID: String, version: UInt8) -> Data {
        Self.aadFor(senderUserID: senderUserID, recipientUserID: recipientUserID, version: version)
    }
}
