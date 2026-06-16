import Foundation
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

/// Test-only ergonomics for the routing-bound `CryptoService` API.
///
/// Production `seal`/`open` require an `EnvelopeRouting` (version + the
/// five routing UUIDs) so the AEAD binds the wire header. Most unit tests
/// only exercise a DIRECT seal→open round-trip where the routing is
/// irrelevant to the assertion — they just need the two halves to agree.
/// These convenience overloads supply one shared fixture so those tests
/// stay terse. Tests that go through the WIRE (encode → parse → open)
/// must instead pass routing that matches the wire header, so they call
/// the real 3-argument API directly.
extension EnvelopeRouting {
    static let testFixture = EnvelopeRouting(
        senderUserId:      "00000000-0000-0000-0000-0000000000a1",
        senderDeviceId:    "00000000-0000-0000-0000-0000000000a2",
        recipientUserId:   "00000000-0000-0000-0000-0000000000b1",
        recipientDeviceId: "00000000-0000-0000-0000-0000000000b2",
        messageId:         "00000000-0000-0000-0000-0000000000c1"
    )
}

extension CryptoService {
    func seal(plaintext: Data, forRecipient recipient: CryptoRecipient) async throws -> Envelope {
        try await seal(plaintext: plaintext, forRecipient: recipient, routing: .testFixture)
    }

    func open(_ envelope: Envelope, fromRecipient recipient: CryptoRecipient) async throws -> Data {
        try await open(envelope, fromRecipient: recipient, routing: .testFixture)
    }
}
