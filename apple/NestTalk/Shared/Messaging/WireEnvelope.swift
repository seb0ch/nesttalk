import Foundation
import CryptoKit

/// Server-acceptable envelope wire format from v0.2.3
/// (`server/internal/messages/messages.go`). Total layout, exact byte
/// offsets:
///
/// ```
///   0:    1   version (u8)
///   1:   16   sender_user_id   (raw 16 UUID bytes, NOT string)
///  17:   16   sender_device_id (raw 16 UUID bytes)
///  33:   16   recipient_user_id
///  49:   16   recipient_device_id
///  65:   16   message_id (raw UUID, server uses this as messages.id)
///  81:   32   sender ephemeral X25519 pub
/// 113: 1088   ML-KEM-768 ciphertext (zero-padded for stub crypto)
/// 1201: 12    AEAD nonce
/// 1213:  4    ct_len (big-endian u32)
/// 1217:  ct_len bytes ciphertext+tag (ChaChaPoly .combined minus nonce)
/// last: 64    Ed25519 signature (server v0.2.3 doesn't verify; zero-fill OK)
/// ```
///
/// Server's `ParseEnvelope` validates `total_len == 1217 + ct_len + 64`
/// and that `ct_len <= 65536`. Routing UUIDs are parsed as raw bytes
/// and turned back into canonical UUID strings via the
/// `uuidBytesToString` helper for the SQL layer.
public enum WireEnvelope {

    public static let version: UInt8 = 1
    public static let totalHeader = 1217   // version + 5 UUIDs + cipher header
    public static let trailerSig = 64
    public static let aeadTagBytes = 16

    public enum Error: Swift.Error, CustomStringConvertible {
        case malformedUUID(String)
        case ciphertextTooLarge(Int)
        case lengthMismatch(actual: Int, expected: Int)

        public var description: String {
            switch self {
            case .malformedUUID(let s):  return "WireEnvelope: bad UUID '\(s)'"
            case .ciphertextTooLarge(let n): return "WireEnvelope: ct_len \(n) > 65536"
            case .lengthMismatch(let a, let e):
                return "WireEnvelope: total_len \(a) != \(e)"
            }
        }
    }

    /// Build a complete v0.2.3 envelope from the routing UUIDs and an
    /// already-sealed `ChaChaPoly.SealedBox`.
    ///
    /// `signer` receives the envelope body (everything before the
    /// 64-byte trailer) and returns the Ed25519 signature — the v0.2.3
    /// Dart client signed with the device key and VERIFIED on open, so
    /// production senders must pass the device signer; nil (tests,
    /// debug fake-session) zero-fills and any verifying receiver will
    /// reject the envelope.
    public static func encode(
        senderUserId: String,
        senderDeviceId: String,
        recipientUserId: String,
        recipientDeviceId: String,
        messageId: String = UUID().uuidString,
        senderEphemeralX25519Pub: Data,
        kemCiphertext: Data,
        nonce: Data,
        ciphertextWithTag: Data,
        signer: ((Data) throws -> Data)? = nil
    ) throws -> Data {
        var out = Data()
        out.reserveCapacity(totalHeader + ciphertextWithTag.count + trailerSig)

        // version
        out.append(version)
        // routing UUIDs
        try out.appendUUIDBytes(senderUserId)
        try out.appendUUIDBytes(senderDeviceId)
        try out.appendUUIDBytes(recipientUserId)
        try out.appendUUIDBytes(recipientDeviceId)
        try out.appendUUIDBytes(messageId)

        // cipher header — EXACT fixed sizes, fail closed. Padding or
        // truncating a wrong-length field would produce a structurally valid
        // but undecryptable envelope: the receiver verifies the signature over
        // the normalized bytes yet can't open the ciphertext, turning a local
        // construction error (crypto bug / version skew) into silent message
        // loss. Production callers pass correctly-sized CryptoKit output, so a
        // mismatch is a programmer error that must surface, not be hidden.
        guard senderEphemeralX25519Pub.count == 32 else {
            throw Error.lengthMismatch(actual: senderEphemeralX25519Pub.count, expected: 32)
        }
        guard kemCiphertext.count == 1088 else {
            throw Error.lengthMismatch(actual: kemCiphertext.count, expected: 1088)
        }
        guard nonce.count == 12 else {
            throw Error.lengthMismatch(actual: nonce.count, expected: 12)
        }
        out.append(senderEphemeralX25519Pub)
        out.append(kemCiphertext)
        out.append(nonce)

        // ct_len (big-endian)
        guard ciphertextWithTag.count <= 65536 else {
            throw Error.ciphertextTooLarge(ciphertextWithTag.count)
        }
        var ctLen = UInt32(ciphertextWithTag.count).bigEndian
        withUnsafeBytes(of: &ctLen) { out.append(contentsOf: $0) }

        // ciphertext + tag
        out.append(ciphertextWithTag)

        // 64-byte trailer: Ed25519 signature over the body. The server
        // never verifies (it can't be trusted to police itself anyway);
        // RECEIVING CLIENTS verify against the sender's enrolled device
        // key — without it, a compromised server could fabricate
        // decryptable envelopes attributed to any user.
        if let signer {
            let sig = try signer(out)
            guard sig.count == trailerSig else {
                throw Error.lengthMismatch(actual: sig.count, expected: trailerSig)
            }
            out.append(sig)
        } else {
            out.append(Data(count: trailerSig))
        }

        let expectedTotal = totalHeader + ciphertextWithTag.count + trailerSig
        if out.count != expectedTotal {
            throw Error.lengthMismatch(actual: out.count, expected: expectedTotal)
        }
        return out
    }

    /// The signed portion of a raw envelope — everything before the
    /// 64-byte trailer. Receivers verify the trailer signature over
    /// these bytes with the sender's enrolled Ed25519 device key.
    public static func signedBody(_ bytes: Data) -> Data {
        guard bytes.count > trailerSig else { return Data() }
        return Data(bytes.prefix(bytes.count - trailerSig))
    }

    /// Parse a v0.2.3 envelope. Used by `MessageReceiveService` to lift
    /// routing fields + ciphertext for AEAD open.
    public struct Parsed: Sendable {
        public let version: UInt8
        public let senderUserId: String
        public let senderDeviceId: String
        public let recipientUserId: String
        public let recipientDeviceId: String
        public let messageId: String
        public let senderEphemeralX25519Pub: Data
        public let kemCiphertext: Data
        public let nonce: Data
        public let ciphertextWithTag: Data
        public let signature: Data
    }

    public static func parse(_ bytes: Data) throws -> Parsed {
        let MIN_LEN = 1297
        guard bytes.count >= MIN_LEN else {
            throw Error.lengthMismatch(actual: bytes.count, expected: MIN_LEN)
        }
        let arr = [UInt8](bytes)
        var p = 0
        let version = arr[p]; p += 1

        func uuid() -> String {
            let b = Array(arr[p..<p+16]); p += 16
            return formatUUID(b)
        }
        let senderUID = uuid()
        let senderDID = uuid()
        let recipientUID = uuid()
        let recipientDID = uuid()
        let messageID = uuid()

        let xpub = Data(arr[p..<p+32]); p += 32
        let kem  = Data(arr[p..<p+1088]); p += 1088
        let nonce = Data(arr[p..<p+12]); p += 12

        let ctLenBytes = arr[p..<p+4]; p += 4
        let lb = Array(ctLenBytes)
        let ctLen = (Int(lb[0]) << 24) | (Int(lb[1]) << 16) | (Int(lb[2]) << 8) | Int(lb[3])
        guard p + ctLen + 64 == arr.count else {
            throw Error.lengthMismatch(actual: arr.count, expected: p + ctLen + 64)
        }
        let ct = Data(arr[p..<p+ctLen]); p += ctLen
        let sig = Data(arr[p..<p+64])

        return Parsed(
            version: version,
            senderUserId: senderUID,
            senderDeviceId: senderDID,
            recipientUserId: recipientUID,
            recipientDeviceId: recipientDID,
            messageId: messageID,
            senderEphemeralX25519Pub: xpub,
            kemCiphertext: kem,
            nonce: nonce,
            ciphertextWithTag: ct,
            signature: sig
        )
    }

    // ─── helpers ──────────────────────────────────────────────

    /// Convert a canonical UUID string ("550e8400-e29b-41d4-a716-446655440000")
    /// to 16 raw big-endian bytes the server expects. Production paths
    /// always pass real UUIDs (server-issued enrollment uses
    /// `uuid.New().String()`). Tests sometimes pass non-UUID strings
    /// like "mom" — we deterministically hash those to 16 bytes via
    /// SHA-256/prefix so the encoder still produces a valid-shape
    /// envelope. The server would reject those bytes as not matching
    /// any real user, but tests use stub responders that don't parse.
    static func uuidBytes(_ str: String) throws -> Data {
        let hex = str.replacingOccurrences(of: "-", with: "")
        if hex.count == 32, let data = Data(hexString: hex) {
            return data
        }
        // Test-shaped fallback — deterministic, never throws.
        let digest = SHA256.hash(data: Data(str.utf8))
        return Data(digest.prefix(16))
    }

    static func formatUUID(_ b: [UInt8]) -> String {
        precondition(b.count == 16)
        let hex = b.map { String(format: "%02x", $0) }.joined()
        // 8-4-4-4-12
        let parts = [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20),
        ]
        return parts.map(String.init).joined(separator: "-")
    }
}

private extension Data {
    mutating func appendUUIDBytes(_ str: String) throws {
        append(try WireEnvelope.uuidBytes(str))
    }

    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i..<i+2]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self = Data(bytes)
    }
}
