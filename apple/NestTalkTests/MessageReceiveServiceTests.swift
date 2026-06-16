import XCTest
import CryptoKit
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class MessageReceiveServiceTests: XCTestCase {

    private var store: MessageStore!
    private var api: APIClient!
    private var session: URLSession!
    private var crypto: CryptoService!

    // Routing identifiers must be real UUIDs: the wire format stores the
    // routing fields as raw 16-byte UUIDs, so non-UUID names (e.g. "mom")
    // are hashed on encode and can't round-trip back through `parse`. The
    // receive-service now validates the SIGNED routing fields against the
    // outer event + self identity and reconstructs the AEAD AAD from the
    // signed sender, so the test identities must survive that round-trip.
    private let selfUID    = "11111111-1111-1111-1111-111111111111"
    private let selfDevUID = "22222222-2222-2222-2222-222222222222"
    private let momUID     = "33333333-3333-3333-3333-333333333333"
    private let momDevUID  = "44444444-4444-4444-4444-444444444444"
    private let dadUID     = "55555555-5555-5555-5555-555555555555"
    private let dadDevUID  = "66666666-6666-6666-6666-666666666666"

    override func setUp() async throws {
        try await super.setUp()
        store = try MessageStore.inMemory()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        session = URLSession(configuration: cfg)
        api = APIClient(baseURL: URL(string: "http://stub.test")!, session: session)
        // Sender side identifies itself as `momUID` so the AAD matches what
        // the receive-service reconstructs from the signed envelope sender.
        crypto = DebugCryptoService(selfUserId: momUID)
    }

    override func tearDown() async throws {
        SimpleStubURLProtocol.responder = nil
        try await super.tearDown()
    }

    /// Round-32 regression: across a process restart, catch-up must resume
    /// from the FULL composite cursor `(received_at, id)`. If it dropped the
    /// id and re-queried with `since_received_at` only, the server's
    /// `received_at = ? AND id > ''` branch would replay every row sharing the
    /// checkpoint millisecond — burning the page cap on already-acked rows.
    func test_catchup_resumes_from_composite_cursor_after_restart() async throws {
        // A prior run checkpointed two rows that shared a millisecond; the
        // last persisted cursor is (1700000000011, m-B).
        try store.setCursor(name: MessageReceiveService.cursorName, value: "1700000000011|m-B")

        nonisolated(unsafe) var sawReceivedAt: String?
        nonisolated(unsafe) var sawId: String?
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/pending") == true {
                let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                sawReceivedAt = comps?.queryItems?.first { $0.name == "since_received_at" }?.value
                sawId = comps?.queryItems?.first { $0.name == "since_id" }?.value
            }
            let body: [String: Any] = ["messages": [], "next_cursor": NSNull()]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let svc = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: { "t" }, selfUserId: { self.selfUID }
        )
        _ = await svc.catchUp(limit: 100)

        XCTAssertEqual(sawReceivedAt, "1700000000011")
        XCTAssertEqual(sawId, "m-B", "the persisted message id must be replayed as since_id")
    }

    func test_ws_message_inserts_and_acks() async throws {
        // Build a stub envelope addressed to "self" from "mom". The seal
        // routing MUST match the wire header so the receiver (which
        // reconstructs routing from the parsed envelope) derives the same
        // AAD and decrypts.
        let msgId = "77777777-7777-7777-7777-777777777771"
        let routing = EnvelopeRouting(
            senderUserId: momUID, senderDeviceId: momDevUID,
            recipientUserId: selfUID, recipientDeviceId: selfDevUID,
            messageId: msgId
        )
        let envelope = try await crypto.seal(
            plaintext: Data("hi self".utf8),
            forRecipient: CryptoRecipient(userId: selfUID),
            routing: routing
        )
        let envelopeBytes = try WireEnvelope.encode(
            senderUserId: momUID, senderDeviceId: momDevUID,
            recipientUserId: selfUID, recipientDeviceId: selfDevUID,
            messageId: msgId,
            senderEphemeralX25519Pub: envelope.senderEphemeralX25519Pub,
            kemCiphertext: envelope.kemCiphertext,
            nonce: envelope.nonce,
            ciphertextWithTag: envelope.ciphertext + envelope.tag
        )
        let envelopeBase64 = envelopeBytes.base64EncodedString()

        nonisolated(unsafe) var ackedIds: [String] = []
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/ack") == true {
                ackedIds.append(req.url!.deletingLastPathComponent().lastPathComponent)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = try! JSONSerialization.data(withJSONObject: ["ok": true])
                return (data, resp)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }

        let svc = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: { "t" }, selfUserId: { self.selfUID }
        )
        await svc.handleEvent(.messageIncoming(
            id: msgId, from: momUID, to: selfUID,
            envelopeBase64: envelopeBase64,
            sentAt: 1_700_000_000_000,
            receivedAt: 1_700_000_000_001,
            replyToId: nil
        ))

        let row = try XCTUnwrap(store.message(serverId: msgId))
        XCTAssertEqual(row.direction, "in")
        XCTAssertEqual(row.thread_user_id, momUID)
        XCTAssertEqual(row.state, "delivered")
        XCTAssertEqual(row.plaintext, "hi self")
        XCTAssertEqual(ackedIds, [msgId])
    }

    func test_duplicate_id_does_not_double_insert_but_still_acks() async throws {
        let envelope = try await crypto.seal(
            plaintext: Data("dup".utf8),
            forRecipient: CryptoRecipient(userId: "self")
        )
        let envelopeBase64 = MessageSendService.encodeStubEnvelope(envelope).base64EncodedString()
        nonisolated(unsafe) var ackCount = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/ack") == true { ackCount += 1 }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let svc = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: { "t" }, selfUserId: { "self" }
        )
        for _ in 0..<3 {
            await svc.handleEvent(.messageIncoming(
                id: "m-2", from: "mom", to: "self",
                envelopeBase64: envelopeBase64,
                sentAt: 1, receivedAt: 2, replyToId: nil
            ))
        }
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(ackCount, 3, "duplicate frames should still re-ack")
    }

    func test_catch_up_pulls_pending_advances_cursor() async throws {
        let envelope1 = try await crypto.seal(
            plaintext: Data("c1".utf8),
            forRecipient: CryptoRecipient(userId: selfUID)
        )
        let envelope2 = try await crypto.seal(
            plaintext: Data("c2".utf8),
            forRecipient: CryptoRecipient(userId: selfUID)
        )
        // The signed message id must equal the outer server id (binding) — use
        // real UUIDs for both and reuse them as the /pending row ids.
        let msgIdA = "aaaaaaaa-aaaa-aaaa-aaaa-00000000000a"
        let msgIdB = "bbbbbbbb-bbbb-bbbb-bbbb-00000000000b"
        let env1B64 = try WireEnvelope.encode(
            senderUserId: momUID, senderDeviceId: momDevUID,
            recipientUserId: selfUID, recipientDeviceId: selfDevUID,
            messageId: msgIdA,
            senderEphemeralX25519Pub: envelope1.senderEphemeralX25519Pub,
            kemCiphertext: envelope1.kemCiphertext, nonce: envelope1.nonce,
            ciphertextWithTag: envelope1.ciphertext + envelope1.tag
        ).base64EncodedString()
        let env2B64 = try WireEnvelope.encode(
            senderUserId: dadUID, senderDeviceId: dadDevUID,
            recipientUserId: selfUID, recipientDeviceId: selfDevUID,
            messageId: msgIdB,
            senderEphemeralX25519Pub: envelope2.senderEphemeralX25519Pub,
            kemCiphertext: envelope2.kemCiphertext, nonce: envelope2.nonce,
            ciphertextWithTag: envelope2.ciphertext + envelope2.tag
        ).base64EncodedString()

        let momUID = self.momUID, dadUID = self.dadUID
        nonisolated(unsafe) var pendingCalls = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/pending") == true {
                pendingCalls += 1
                let body: [String: Any] = [
                    "messages": [
                        [
                            "id": msgIdA, "sender_user_id": momUID, "envelope": env1B64,
                            "reply_to_id": NSNull(),
                            "sent_at": 1_700_000_000_001, "received_at": 1_700_000_000_002,
                        ],
                        [
                            "id": msgIdB, "sender_user_id": dadUID, "envelope": env2B64,
                            "reply_to_id": NSNull(),
                            "sent_at": 1_700_000_000_010, "received_at": 1_700_000_000_011,
                        ],
                    ],
                    "next_cursor": NSNull(),  // no more pages
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, resp)
            }
            // ack
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let svc = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: { "t" }, selfUserId: { self.selfUID }
        )
        let inserted = await svc.catchUp(limit: 100)
        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(try store.count(), 2)
        let cursor = try store.cursor(name: MessageReceiveService.cursorName)
        XCTAssertEqual(cursor, "1700000000011|\(msgIdB)",
                       "cursor persists the full composite (received_at|id)")
    }
}

extension MessageReceiveServiceTests {
    /// Sender authenticity (v0.2.3 contract): an envelope whose trailer
    /// signature doesn't verify against the claimed sender's enrolled
    /// Ed25519 key must render as undecryptable — a compromised server
    /// could otherwise fabricate decryptable messages attributed to
    /// anyone.
    func test_forged_signature_renders_undecryptable() async throws {
        let store = try MessageStore.inMemory()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg))
        SimpleStubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), resp)
        }
        defer { SimpleStubURLProtocol.responder = nil }

        let selfId   = "11111111-1111-1111-1111-111111111111"
        let momId    = "33333333-3333-3333-3333-333333333333"
        let crypto = DebugCryptoService(selfUserId: momId)

        // Mom's REAL signing key — the service will verify against it.
        let momSigner = Curve25519.Signing.PrivateKey()
        // The attacker (server) seals valid ciphertext but signs with a
        // DIFFERENT key (it doesn't have mom's private key).
        let forger = Curve25519.Signing.PrivateKey()

        let momDevId = "44444444-4444-4444-4444-444444444444"
        let selfDevId = "22222222-2222-2222-2222-222222222222"
        let msgId = "77777777-7777-7777-7777-777777777772"
        let routing = EnvelopeRouting(
            senderUserId: momId, senderDeviceId: momDevId,
            recipientUserId: selfId, recipientDeviceId: selfDevId,
            messageId: msgId
        )
        let sealed = try await crypto.seal(
            plaintext: Data("forged hello".utf8),
            forRecipient: CryptoRecipient(userId: selfId),
            routing: routing
        )
        let wire = try WireEnvelope.encode(
            senderUserId: momId,
            senderDeviceId: momDevId,
            recipientUserId: selfId,
            recipientDeviceId: selfDevId,
            messageId: msgId,
            senderEphemeralX25519Pub: sealed.senderEphemeralX25519Pub,
            kemCiphertext: sealed.kemCiphertext,
            nonce: sealed.nonce,
            ciphertextWithTag: sealed.ciphertext + sealed.tag,
            signer: { try forger.signature(for: $0) }
        )

        let receive = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: { "t" },
            selfUserId: { selfId },
            senderSigningKey: { _, _ in .found(momSigner.publicKey.rawRepresentation) }
        )
        await receive.handleEvent(.messageIncoming(
            id: msgId, from: momId, to: selfId,
            envelopeBase64: wire.base64EncodedString(),
            sentAt: 1, receivedAt: 2, replyToId: nil
        ))
        // A forged envelope is REJECTED outright — no visible row at all, so
        // a compromised server can't inject placeholder noise into the thread.
        XCTAssertNil(try store.message(serverId: msgId),
                     "forged signature must not create any conversation row")

        // Control: the SAME envelope signed with mom's real key passes.
        let genuine = try WireEnvelope.encode(
            senderUserId: momId,
            senderDeviceId: momDevId,
            recipientUserId: selfId,
            recipientDeviceId: selfDevId,
            messageId: msgId,
            senderEphemeralX25519Pub: sealed.senderEphemeralX25519Pub,
            kemCiphertext: sealed.kemCiphertext,
            nonce: sealed.nonce,
            ciphertextWithTag: sealed.ciphertext + sealed.tag,
            signer: { try momSigner.signature(for: $0) }
        )
        await receive.handleEvent(.messageIncoming(
            id: msgId, from: momId, to: selfId,
            envelopeBase64: genuine.base64EncodedString(),
            sentAt: 3, receivedAt: 4, replyToId: nil
        ))
        let ok = try XCTUnwrap(store.message(serverId: msgId))
        XCTAssertEqual(ok.plaintext, "forged hello")
    }

    /// Round-23 regression: when authenticity verification is configured,
    /// an UNPARSEABLE envelope can't be authenticated, so a compromised
    /// server must not be able to inject a visible placeholder row — it's
    /// rejected (ack + drop), never inserted.
    func test_unparseable_envelope_under_verification_is_rejected() async throws {
        let store = try MessageStore.inMemory()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg))
        nonisolated(unsafe) var ackCount = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/ack") == true { ackCount += 1 }
            return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        defer { SimpleStubURLProtocol.responder = nil }

        let selfId = "11111111-1111-1111-1111-111111111111"
        let momId  = "33333333-3333-3333-3333-333333333333"
        let receive = MessageReceiveService(
            store: store, api: api, crypto: DebugCryptoService(),
            sessionToken: { "t" }, selfUserId: { selfId },
            senderSigningKey: { _, _ in .found(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation) }
        )
        // Garbage bytes — won't parse as a WireEnvelope.
        await receive.handleEvent(.messageIncoming(
            id: "srv-garbage", from: momId, to: selfId,
            envelopeBase64: Data(repeating: 0x00, count: 40).base64EncodedString(),
            sentAt: 1, receivedAt: 2, replyToId: nil
        ))
        XCTAssertNil(try store.message(serverId: "srv-garbage"),
                     "unparseable envelope under verification must not be stored")
        XCTAssertEqual(ackCount, 1, "rejected envelope is still acked so the spool advances")
    }

    /// Round-51 regression: a relay can deliver a VALID signed envelope under a
    /// DIFFERENT outer server id than its signed message id. The receiver must
    /// reject it — storing localId from the signed payload while keying
    /// serverId/ack on the wrong outer id would desync receipts, reactions, and
    /// sender status (the same binding signed reactions enforce).
    func test_message_id_binding_mismatch_is_rejected_not_stored() async throws {
        let store = try MessageStore.inMemory()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg))
        let selfId = "11111111-1111-1111-1111-111111111111"
        let momId  = "33333333-3333-3333-3333-333333333333"
        let signedMsgId = "77777777-7777-7777-7777-7777777777aa"
        let crypto = DebugCryptoService(selfUserId: momId)
        let sealed = try await crypto.seal(plaintext: Data("hi".utf8), forRecipient: CryptoRecipient(userId: selfId))
        let wire = try WireEnvelope.encode(
            senderUserId: momId, senderDeviceId: "44444444-4444-4444-4444-444444444444",
            recipientUserId: selfId, recipientDeviceId: "22222222-2222-2222-2222-222222222222",
            messageId: signedMsgId,
            senderEphemeralX25519Pub: sealed.senderEphemeralX25519Pub,
            kemCiphertext: sealed.kemCiphertext, nonce: sealed.nonce,
            ciphertextWithTag: sealed.ciphertext + sealed.tag
        ).base64EncodedString()

        let receive = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: { "t" }, selfUserId: { selfId }
        )
        // Delivered under an outer id that does NOT equal the signed message id.
        await receive.handleEvent(.messageIncoming(
            id: "99999999-9999-9999-9999-999999999999", from: momId, to: selfId,
            envelopeBase64: wire, sentAt: 1, receivedAt: 2, replyToId: nil
        ))
        XCTAssertEqual(try store.count(), 0,
                       "a message whose signed id != outer id must not be stored")
        XCTAssertNil(try store.message(serverId: "99999999-9999-9999-9999-999999999999"))
        XCTAssertNil(try store.message(localId: signedMsgId))
    }

    /// Round-12 regression: the server can deliver a VALID envelope under
    /// a mis-routed outer event (wrong `to`, or re-attributed `from`). The
    /// receiver must reject on the SIGNED routing fields — never store a
    /// row whose signed recipient isn't us, or whose signed sender differs
    /// from the outer event.
    func test_routing_mismatch_is_rejected_not_stored() async throws {
        let store = try MessageStore.inMemory()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg))
        nonisolated(unsafe) var ackCount = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/ack") == true { ackCount += 1 }
            return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        defer { SimpleStubURLProtocol.responder = nil }

        let selfId   = "11111111-1111-1111-1111-111111111111"
        let momId    = "33333333-3333-3333-3333-333333333333"
        let strangerId = "99999999-9999-9999-9999-999999999999"
        let crypto = DebugCryptoService(selfUserId: momId)

        // Envelope is genuinely addressed to `strangerId`, NOT us.
        let sealed = try await crypto.seal(
            plaintext: Data("not for you".utf8),
            forRecipient: CryptoRecipient(userId: strangerId)
        )
        let wire = try WireEnvelope.encode(
            senderUserId: momId,
            senderDeviceId: "44444444-4444-4444-4444-444444444444",
            recipientUserId: strangerId,
            recipientDeviceId: "22222222-2222-2222-2222-222222222222",
            senderEphemeralX25519Pub: sealed.senderEphemeralX25519Pub,
            kemCiphertext: sealed.kemCiphertext,
            nonce: sealed.nonce,
            ciphertextWithTag: sealed.ciphertext + sealed.tag
        )
        let receive = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: { "t" }, selfUserId: { selfId }
        )
        // Server lies: claims it's `to: selfId`.
        await receive.handleEvent(.messageIncoming(
            id: "srv-misrouted", from: momId, to: selfId,
            envelopeBase64: wire.base64EncodedString(),
            sentAt: 1, receivedAt: 2, replyToId: nil
        ))
        XCTAssertNil(try store.message(serverId: "srv-misrouted"),
                     "mis-routed envelope must not be stored")
        XCTAssertEqual(try store.count(), 0)
        XCTAssertEqual(ackCount, 1, "rejected envelope is still acked so the spool advances")
    }

    /// Round-12/51 regression: a compromised server can re-wrap the SAME
    /// signed envelope under a fresh outer server id to replay a message. The
    /// signed-message-id↔outer-id binding (round-51) rejects the re-wrap
    /// outright — its outer id no longer matches the signed id — so the replay
    /// never reaches a second insert (the signed-id dedup remains as
    /// defense-in-depth for the same-outer-id case).
    func test_replay_under_fresh_server_id_is_deduped() async throws {
        let store = try MessageStore.inMemory()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg))
        nonisolated(unsafe) var ackCount = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/ack") == true { ackCount += 1 }
            return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        defer { SimpleStubURLProtocol.responder = nil }

        let selfId = "11111111-1111-1111-1111-111111111111"
        let momId  = "33333333-3333-3333-3333-333333333333"
        let signedMsgId = "77777777-7777-7777-7777-777777777777"
        let crypto = DebugCryptoService(selfUserId: momId)

        let sealed = try await crypto.seal(
            plaintext: Data("hi once".utf8),
            forRecipient: CryptoRecipient(userId: selfId)
        )
        let wire = try WireEnvelope.encode(
            senderUserId: momId,
            senderDeviceId: "44444444-4444-4444-4444-444444444444",
            recipientUserId: selfId,
            recipientDeviceId: "22222222-2222-2222-2222-222222222222",
            messageId: signedMsgId,
            senderEphemeralX25519Pub: sealed.senderEphemeralX25519Pub,
            kemCiphertext: sealed.kemCiphertext,
            nonce: sealed.nonce,
            ciphertextWithTag: sealed.ciphertext + sealed.tag
        ).base64EncodedString()

        let receive = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: { "t" }, selfUserId: { selfId }
        )
        // First delivery under its OWN id (signed == outer, as an honest server
        // sends) → inserts. Re-wrap under a fresh outer id → rejected by the
        // binding (outer id != signed id), so it never double-inserts.
        await receive.handleEvent(.messageIncoming(
            id: signedMsgId, from: momId, to: selfId, envelopeBase64: wire,
            sentAt: 1, receivedAt: 2, replyToId: nil
        ))
        await receive.handleEvent(.messageIncoming(
            id: "88888888-8888-8888-8888-888888888888", from: momId, to: selfId, envelopeBase64: wire,
            sentAt: 1, receivedAt: 3, replyToId: nil
        ))
        XCTAssertEqual(try store.count(), 1, "replayed/re-wrapped envelope must not double-insert")
        XCTAssertEqual(ackCount, 2, "both deliveries acked so the server stops re-spooling")
    }
}

extension MessageReceiveServiceTests {
    /// The server emits next_cursor as an OBJECT {"received_at","id"}
    /// whenever a page is non-empty. Modeling it as String? rejected
    /// every non-empty page — offline catch-up silently did nothing.
    func test_pending_response_decodes_server_shaped_object_cursor() throws {
        let json = """
        {"messages":[{"id":"m1","sender_user_id":"u1","envelope":"AAAA",
          "reply_to_id":null,"sent_at":1,"received_at":2}],
         "next_cursor":{"received_at":2,"id":"m1"}}
        """
        let resp = try JSONDecoder().decode(APIClient.PendingResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.messages.count, 1)
        XCTAssertEqual(resp.next_cursor?.received_at, 2)
        XCTAssertEqual(resp.next_cursor?.id, "m1")
    }

    func test_reactions_page_decodes_server_shaped_object_cursor() throws {
        let json = """
        {"reactions":[{"id":"r1","message_id":"m1","sender_user_id":"u1",
          "envelope":"AAAA","sent_at":1,"received_at":2}],
         "next_cursor":{"received_at":2,"id":"r1"}}
        """
        let resp = try JSONDecoder().decode(APIClient.ReactionsPage.self, from: Data(json.utf8))
        XCTAssertEqual(resp.reactions.count, 1)
        XCTAssertEqual(resp.next_cursor?.id, "r1")
    }
}

extension MessageReceiveServiceTests {
    /// Transient key-lookup failure must NOT insert or ACK — otherwise
    /// the valid envelope is deduped away on later catch-up and the
    /// plaintext is lost forever. (Distinct from a forged signature,
    /// which IS stored undecryptable + acked.)
    func test_key_lookup_failure_defers_without_ack() async throws {
        let store = try MessageStore.inMemory()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg))
        nonisolated(unsafe) var ackCount = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/ack") == true { ackCount += 1 }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), resp)
        }
        defer { SimpleStubURLProtocol.responder = nil }

        let selfId = "11111111-1111-1111-1111-111111111111"
        let momId  = "33333333-3333-3333-3333-333333333333"
        let msgId = "cccccccc-cccc-cccc-cccc-00000000000c"
        let crypto = DebugCryptoService(selfUserId: momId)
        let sealed = try await crypto.seal(
            plaintext: Data("hi".utf8), forRecipient: CryptoRecipient(userId: selfId)
        )
        let wire = try WireEnvelope.encode(
            senderUserId: momId, senderDeviceId: "44444444-4444-4444-4444-444444444444",
            recipientUserId: selfId, recipientDeviceId: "22222222-2222-2222-2222-222222222222",
            messageId: msgId,
            senderEphemeralX25519Pub: sealed.senderEphemeralX25519Pub,
            kemCiphertext: sealed.kemCiphertext, nonce: sealed.nonce,
            ciphertextWithTag: sealed.ciphertext + sealed.tag,
            signer: { try Curve25519.Signing.PrivateKey().signature(for: $0) }
        )
        let receive = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: { "t" }, selfUserId: { selfId },
            senderSigningKey: { _, _ in .lookupFailed }   // lookup ALWAYS fails (transient)
        )
        await receive.handleEvent(.messageIncoming(
            id: msgId, from: momId, to: selfId,
            envelopeBase64: wire.base64EncodedString(),
            sentAt: 1, receivedAt: 2, replyToId: nil
        ))
        XCTAssertNil(try store.message(serverId: msgId), "lookup failure must not insert")
        XCTAssertEqual(ackCount, 0, "lookup failure must not ack (catch-up retries)")
    }
}

extension MessageReceiveServiceTests {
    /// catchUp must NOT advance its cursor past a message whose sender
    /// key lookup failed — otherwise the server's composite cursor skips
    /// it forever. After the key resolves, a later catchUp ingests it.
    func test_catchup_cursor_holds_at_deferred_message() async throws {
        let store = try MessageStore.inMemory()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg))
        let selfId = "11111111-1111-1111-1111-111111111111"
        let momId  = "33333333-3333-3333-3333-333333333333"
        let momDev = "44444444-4444-4444-4444-444444444444"
        let selfDev = "22222222-2222-2222-2222-222222222222"
        let msgId = "77777777-7777-7777-7777-777777777773"
        let crypto = DebugCryptoService(selfUserId: momId)
        let momSigner = Curve25519.Signing.PrivateKey()
        let routing = EnvelopeRouting(
            senderUserId: momId, senderDeviceId: momDev,
            recipientUserId: selfId, recipientDeviceId: selfDev,
            messageId: msgId
        )
        let sealed = try await crypto.seal(plaintext: Data("hi".utf8), forRecipient: CryptoRecipient(userId: selfId), routing: routing)
        let wire = try WireEnvelope.encode(
            senderUserId: momId, senderDeviceId: momDev,
            recipientUserId: selfId, recipientDeviceId: selfDev,
            messageId: msgId,
            senderEphemeralX25519Pub: sealed.senderEphemeralX25519Pub,
            kemCiphertext: sealed.kemCiphertext, nonce: sealed.nonce,
            ciphertextWithTag: sealed.ciphertext + sealed.tag,
            signer: { try momSigner.signature(for: $0) }
        ).base64EncodedString()

        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = [
                "messages": [[
                    "id": msgId, "sender_user_id": momId, "envelope": wire,
                    "reply_to_id": NSNull(), "sent_at": 1, "received_at": 500,
                ]],
                "next_cursor": ["received_at": 500, "id": msgId],
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        // Phase 1: key lookup fails → deferred, cursor must NOT advance.
        nonisolated(unsafe) var keyAvailable = false
        let receive = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: { "t" }, selfUserId: { selfId },
            senderSigningKey: { _, _ in keyAvailable ? .found(momSigner.publicKey.rawRepresentation) : .lookupFailed }
        )
        _ = await receive.catchUp()
        XCTAssertNil(try store.message(serverId: msgId), "deferred message must not be stored")
        XCTAssertNil(try store.cursor(name: MessageReceiveService.cursorName),
                     "cursor must not advance past the deferred message")

        // Phase 2: key resolves → next catchUp ingests + advances.
        keyAvailable = true
        _ = await receive.catchUp()
        let row = try XCTUnwrap(store.message(serverId: msgId))
        XCTAssertEqual(row.plaintext, "hi")
        XCTAssertEqual(try store.cursor(name: MessageReceiveService.cursorName), "500|\(msgId)")
    }
}

extension MessageReceiveServiceTests {
    /// Round-19 regression: a 401 during catch-up (cold launch after a
    /// missed server restore) must trigger the re-handshake hook so the
    /// client recovers immediately instead of waiting out the token TTL.
    func test_catchup_401_triggers_auth_failure_hook() async throws {
        let store = try MessageStore.inMemory()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg))
        SimpleStubURLProtocol.responder = { req in
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        defer { SimpleStubURLProtocol.responder = nil }

        nonisolated(unsafe) var authFailures = 0
        let receive = MessageReceiveService(
            store: store, api: api, crypto: DebugCryptoService(),
            sessionToken: { "stale-token" }, selfUserId: { "11111111-1111-1111-1111-111111111111" },
            onAuthFailure: { authFailures += 1 }
        )
        _ = await receive.catchUp()
        XCTAssertEqual(authFailures, 1, "a 401 catch-up must trigger the re-handshake hook")
    }
}

extension MessageReceiveServiceTests {
    /// Round-15 regression: a stored message whose delivered-ack POST fails
    /// must NOT advance the catch-up cursor — otherwise the server keeps it
    /// spooled (sender never sees "delivered") and it's never re-acked.
    /// Once the ack endpoint recovers, the next catch-up re-acks and the
    /// cursor advances.
    func test_ack_failure_holds_cursor_until_ack_succeeds() async throws {
        let store = try MessageStore.inMemory()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg))
        let selfId = "11111111-1111-1111-1111-111111111111"
        let momId  = "33333333-3333-3333-3333-333333333333"
        let msgId = "dddddddd-dddd-dddd-dddd-00000000000d"
        let crypto = DebugCryptoService(selfUserId: momId)
        let sealed = try await crypto.seal(plaintext: Data("hi".utf8), forRecipient: CryptoRecipient(userId: selfId))
        let wire = try WireEnvelope.encode(
            senderUserId: momId, senderDeviceId: "44444444-4444-4444-4444-444444444444",
            recipientUserId: selfId, recipientDeviceId: "22222222-2222-2222-2222-222222222222",
            messageId: msgId,
            senderEphemeralX25519Pub: sealed.senderEphemeralX25519Pub,
            kemCiphertext: sealed.kemCiphertext, nonce: sealed.nonce,
            ciphertextWithTag: sealed.ciphertext + sealed.tag
        ).base64EncodedString()

        nonisolated(unsafe) var ackShouldFail = true
        SimpleStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/ack") {
                let code = ackShouldFail ? 500 : 200
                return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            // pending page
            let body: [String: Any] = [
                "messages": [[
                    "id": msgId, "sender_user_id": momId, "envelope": wire,
                    "reply_to_id": NSNull(), "sent_at": 1, "received_at": 500,
                ]],
                "next_cursor": ["received_at": 500, "id": msgId],
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        defer { SimpleStubURLProtocol.responder = nil }

        let receive = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: { "t" }, selfUserId: { selfId }
        )
        // Phase 1: stored, but ack fails → cursor must NOT advance.
        _ = await receive.catchUp()
        XCTAssertNotNil(try store.message(serverId: msgId), "message is stored even when the ack fails")
        XCTAssertNil(try store.cursor(name: MessageReceiveService.cursorName),
                     "ack failure must not advance the cursor")

        // Phase 2: ack endpoint recovers → next catch-up re-acks + advances.
        ackShouldFail = false
        _ = await receive.catchUp()
        XCTAssertEqual(try store.cursor(name: MessageReceiveService.cursorName), "500|\(msgId)")
        XCTAssertEqual(try store.count(), 1, "re-ack must not double-insert")
    }
}
