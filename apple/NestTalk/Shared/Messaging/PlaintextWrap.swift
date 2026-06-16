import Foundation
import CryptoKit

/// AEAD wrap around plaintext message bodies persisted in
/// `pending_queue.plaintext_wrapped`. Sealed under the `dbWrapKey`
/// (Keychain `com.nesttalk.dbwrap.v1`); decrypted only in-memory at
/// retry time so the database file never carries plaintext at rest
/// even when SQLCipher is not yet wired.
public enum PlaintextWrap {
    public static let aad = Data("nesttalk.outbox.v1".utf8)

    public static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let sealed = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad)
        // `combined` carries nonce(12) || ciphertext || tag(16) — exactly
        // what we want to persist.
        return sealed.combined
    }

    public static func open(_ wrapped: Data, using key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: wrapped)
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }
}
