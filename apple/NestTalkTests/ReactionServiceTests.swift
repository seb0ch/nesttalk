import XCTest
import CryptoKit
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class ReactionServiceTests: XCTestCase {

    // WireEnvelope routing headers carry raw UUID bytes, so every
    // user / device id in these tests must be UUID-shaped.
    private static let selfId   = "11111111-1111-1111-1111-111111111111"
    private static let selfDev  = "22222222-2222-2222-2222-222222222222"
    private static let momId    = "33333333-3333-3333-3333-333333333333"
    private static let momDev   = "44444444-4444-4444-4444-444444444444"
    private static let serverMessageId = "55555555-5555-5555-5555-555555555555"

    private var store: MessageStore!
    private var api: APIClient!
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        store = try MessageStore.inMemory()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        session = URLSession(configuration: cfg)
        api = APIClient(baseURL: URL(string: "http://stub.test")!, session: session)
    }

    override func tearDown() async throws {
        SimpleStubURLProtocol.responder = nil
        try await super.tearDown()
    }

    private func makeService() -> ReactionService {
        ReactionService(
            store: store, api: api,
            crypto: DebugCryptoService(selfUserId: Self.selfId),
            sessionToken: { "t" },
            selfUserId: { Self.selfId },
            selfDeviceId: { Self.selfDev }
        )
    }

    /// Routes the keys lookup (device-id resolution) and the reaction
    /// PUT through one stub; records reaction-PUT bodies.
    private static func stubRouting(
        reactionStatus: Int,
        onReactionPut: (@Sendable () -> Void)? = nil
    ) {
        SimpleStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            if path.contains("/keys/message/") {
                let body: [String: Any] = ["devices": [[
                    "device_id": momDev,
                    "public_key": Data(repeating: 1, count: 32).base64EncodedString(),
                    "message_pubkey": Data(repeating: 2, count: 1216).base64EncodedString(),
                    "enrolled_at": 1,
                ]]]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            onReactionPut?()
            let body: [String: Any] = ["id": "rx-1", "received_at": 1]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: reactionStatus, httpVersion: nil, headerFields: nil)!)
        }
    }

    func test_set_reaction_optimistic_and_persists_on_success() async throws {
        Self.stubRouting(reactionStatus: 200)
        let svc = makeService()
        let outcome = await svc.setReaction(
            messageRowId: "m-1", serverMessageId: Self.serverMessageId,
            toUserId: Self.momId, emoji: "🧡"
        )
        XCTAssertEqual(outcome, .applied)
        let stored = try store.reactions(forMessageId: "m-1")
        XCTAssertEqual(stored.first?.reaction, "🧡")
        XCTAssertEqual(stored.first?.user_id, Self.selfId)
    }

    func test_set_reaction_without_server_id_is_refused() async throws {
        // No responder — any network call would crash the stub. A
        // message still in `sending` has no server id; nothing would
        // ever re-transmit the reaction once the id binds, so claiming
        // success would show the sender a reaction the recipient never
        // receives. Refuse and leave no local trace.
        let svc = makeService()
        let outcome = await svc.setReaction(
            messageRowId: "m-1", serverMessageId: nil,
            toUserId: Self.momId, emoji: "🧡"
        )
        XCTAssertEqual(outcome, .rolledBack(code: -5))
        let stored = try store.reactions(forMessageId: "m-1")
        XCTAssertTrue(stored.isEmpty, "refused reaction must not linger locally")
    }

    func test_catchup_does_not_checkpoint_past_unstored_reaction() async throws {
        // Reaction catch-up races message catch-up: the parent message
        // isn't local yet. The cursor must NOT advance past the
        // reaction, or it is lost forever once checkpointed.
        let envelope = MessageSendService.encodeStubEnvelope // placeholder; not used
        _ = envelope
        nonisolated(unsafe) var pages = 0
        SimpleStubURLProtocol.responder = { req in
            pages += 1
            let body: [String: Any] = [
                "reactions": [[
                    "id": "rx-orphan",
                    "message_id": Self.serverMessageId,
                    "sender_user_id": Self.momId,
                    "envelope": Data(repeating: 0xAB, count: 8).base64EncodedString(),
                    "sent_at": 1, "received_at": 777,
                ]],
                "next_cursor": NSNull(),
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let svc = makeService()
        _ = await svc.catchUp()
        // Envelope was undecodable → skipped permanently, cursor moves.
        // Now simulate the REAL stall case: decodable envelope, missing
        // parent. DebugCryptoService opens its own stub-format seal —
        // build one.
        // The reaction binds to its parent message: the wire message_id
        // IS the parent server message id, and the seal routing must match
        // so the receiver's parsed-routing AAD decrypts and the parent-id
        // check passes.
        let reactionRouting = EnvelopeRouting(
            senderUserId: Self.momId, senderDeviceId: Self.momDev,
            recipientUserId: Self.selfId, recipientDeviceId: Self.selfDev,
            messageId: Self.serverMessageId
        )
        let sealed = try await DebugCryptoService(selfUserId: Self.momId).seal(
            plaintext: Data("🧡".utf8),
            forRecipient: CryptoRecipient(userId: Self.selfId),
            routing: reactionRouting
        )
        let wire = try WireEnvelope.encode(
            senderUserId: Self.momId, senderDeviceId: Self.momDev,
            recipientUserId: Self.selfId, recipientDeviceId: Self.selfDev,
            messageId: Self.serverMessageId,
            senderEphemeralX25519Pub: sealed.senderEphemeralX25519Pub,
            kemCiphertext: sealed.kemCiphertext,
            nonce: sealed.nonce,
            ciphertextWithTag: sealed.ciphertext + sealed.tag
        ).base64EncodedString()
        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = [
                "reactions": [[
                    "id": "rx-stall",
                    "message_id": Self.serverMessageId,
                    "sender_user_id": Self.momId,
                    "envelope": wire,
                    "sent_at": 2, "received_at": 999,
                ]],
                "next_cursor": NSNull(),
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = await svc.catchUp()
        let cursorAfterStall = try store.cursor(name: ReactionService.cursorName)
        XCTAssertNotEqual(cursorAfterStall, "999",
                          "cursor must not checkpoint past an unstored reaction")

        // Parent arrives → next catch-up ingests it and advances.
        try store.insert(MessageStore.Message(
            id: "local-row-1", threadUserId: Self.momId, outgoing: true,
            plaintext: "hi", state: "sent_to_server", sentAt: Date(),
            serverId: Self.serverMessageId
        ))
        _ = await svc.catchUp()
        let stored = try store.reactions(forMessageId: "local-row-1")
        XCTAssertEqual(stored.first?.reaction, "🧡")
        XCTAssertEqual(try store.cursor(name: ReactionService.cursorName), "999|rx-stall",
                       "cursor persists the full composite (received_at|id)")
    }

    func test_catchup_dead_letters_reaction_to_a_tombstoned_parent() async throws {
        // Round-30: the parent was REJECTED by the receive pipeline (forged /
        // unparseable / mis-routed), so it has no local row and never will. A
        // valid reaction targeting it must be dead-lettered — the cursor
        // advances instead of pinning forever (which would wedge ALL later
        // reaction catch-up behind one permanently missing parent).
        try store.tombstoneRejected(serverId: Self.serverMessageId)

        let reactionRouting = EnvelopeRouting(
            senderUserId: Self.momId, senderDeviceId: Self.momDev,
            recipientUserId: Self.selfId, recipientDeviceId: Self.selfDev,
            messageId: Self.serverMessageId
        )
        let sealed = try await DebugCryptoService(selfUserId: Self.momId).seal(
            plaintext: Data("🧡".utf8),
            forRecipient: CryptoRecipient(userId: Self.selfId),
            routing: reactionRouting
        )
        let wire = try WireEnvelope.encode(
            senderUserId: Self.momId, senderDeviceId: Self.momDev,
            recipientUserId: Self.selfId, recipientDeviceId: Self.selfDev,
            messageId: Self.serverMessageId,
            senderEphemeralX25519Pub: sealed.senderEphemeralX25519Pub,
            kemCiphertext: sealed.kemCiphertext,
            nonce: sealed.nonce,
            ciphertextWithTag: sealed.ciphertext + sealed.tag
        ).base64EncodedString()
        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = [
                "reactions": [[
                    "id": "rx-deadletter",
                    "message_id": Self.serverMessageId,
                    "sender_user_id": Self.momId,
                    "envelope": wire,
                    "sent_at": 2, "received_at": 999,
                ]],
                "next_cursor": NSNull(),
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let svc = makeService()
        _ = await svc.catchUp()
        XCTAssertEqual(try store.cursor(name: ReactionService.cursorName), "999|rx-deadletter",
                       "a reaction to a tombstoned parent must be dead-lettered, advancing the cursor")
    }

    func test_set_reaction_rolls_back_on_5xx() async throws {
        try store.upsertReaction(MessageStore.Reaction(
            messageId: "m-1", userId: Self.selfId, reaction: "👍", setAt: Date()
        ))
        Self.stubRouting(reactionStatus: 500)
        let svc = makeService()
        let outcome = await svc.setReaction(
            messageRowId: "m-1", serverMessageId: Self.serverMessageId,
            toUserId: Self.momId, emoji: "🧡"
        )
        if case .rolledBack(let code) = outcome {
            XCTAssertEqual(code, 500)
        } else {
            XCTFail("expected rollback, got \(outcome)")
        }
        let stored = try store.reactions(forMessageId: "m-1")
        XCTAssertEqual(stored.first?.reaction, "👍", "previous reaction must be restored")
    }

    func test_clear_reaction_then_rollback_restores_emoji() async throws {
        try store.upsertReaction(MessageStore.Reaction(
            messageId: "m-1", userId: Self.selfId, reaction: "🧡", setAt: Date()
        ))
        Self.stubRouting(reactionStatus: 500)
        let svc = makeService()
        _ = await svc.setReaction(
            messageRowId: "m-1", serverMessageId: Self.serverMessageId,
            toUserId: Self.momId, emoji: nil
        )
        let stored = try store.reactions(forMessageId: "m-1")
        XCTAssertEqual(stored.first?.reaction, "🧡")
    }

    func test_ingest_remote_reaction_maps_server_id_to_local_row() async throws {
        // Peer reactions arrive keyed by SERVER message id and must
        // land on the local row that carries it.
        try store.insert(MessageStore.Message(
            id: "local-row-1", threadUserId: Self.momId, outgoing: true,
            plaintext: "hi", state: "sent_to_server", sentAt: Date(),
            serverId: Self.serverMessageId
        ))
        let svc = makeService()
        await svc.ingest(
            serverMessageId: Self.serverMessageId,
            senderUserId: Self.momId, emoji: "✨", setAt: Date()
        )
        let stored = try? store.reactions(forMessageId: "local-row-1")
        XCTAssertEqual(stored?.first?.reaction, "✨")
        XCTAssertEqual(stored?.first?.user_id, Self.momId)
    }

    func test_undecodable_update_does_not_clear_existing_reaction() async throws {
        // Peer's reaction exists locally; a later envelope we can't
        // decrypt (e.g. sealed for our revoked pre-rotation device)
        // must be DROPPED — interpreting it as "" would silently clear
        // the reaction.
        try store.insert(MessageStore.Message(
            id: "local-row-1", threadUserId: Self.momId, outgoing: true,
            plaintext: "hi", state: "sent_to_server", sentAt: Date(),
            serverId: Self.serverMessageId
        ))
        try store.upsertReaction(MessageStore.Reaction(
            messageId: "local-row-1", userId: Self.momId, reaction: "🧡", setAt: Date()
        ))
        let svc = makeService()
        await svc.ingestUpdate(
            serverMessageId: Self.serverMessageId,
            senderUserId: Self.momId,
            envelopeBase64: Data(repeating: 0xAB, count: 64).base64EncodedString(), // unparseable
            receivedAtMillis: 2
        )
        let stored = try store.reactions(forMessageId: "local-row-1")
        XCTAssertEqual(stored.first?.reaction, "🧡", "undecodable envelope must not clear the reaction")
    }

    func test_rotation_response_invalidates_caches_and_retries_once() async throws {
        nonisolated(unsafe) var putCount = 0
        nonisolated(unsafe) var keysInvalidated: [String] = []
        SimpleStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            if path.contains("/keys/message/") {
                let body: [String: Any] = ["devices": [[
                    "device_id": Self.momDev,
                    "public_key": Data(repeating: 1, count: 32).base64EncodedString(),
                    "message_pubkey": Data(repeating: 2, count: 1216).base64EncodedString(),
                    "enrolled_at": 1,
                ]]]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            putCount += 1
            if putCount == 1 {
                let body: [String: Any] = [
                    "error": "recipient_device_rotated",
                    "active_recipient_device_id": "99999999-9999-9999-9999-999999999999",
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
            let body: [String: Any] = ["id": "rx-1", "received_at": 1]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let svc = ReactionService(
            store: store, api: api,
            crypto: DebugCryptoService(selfUserId: Self.selfId),
            sessionToken: { "t" },
            selfUserId: { Self.selfId },
            selfDeviceId: { Self.selfDev },
            invalidateKeys: { uid in keysInvalidated.append(uid) }
        )
        let outcome = await svc.setReaction(
            messageRowId: "m-1", serverMessageId: Self.serverMessageId,
            toUserId: Self.momId, emoji: "🧡"
        )
        XCTAssertEqual(outcome, .applied, "rotation must be retried, not rolled back")
        XCTAssertEqual(putCount, 2, "exactly one retry")
        XCTAssertEqual(keysInvalidated, [Self.momId], "recipient keys cache must be invalidated")
    }

    func test_ingest_for_unknown_parent_is_dropped() async throws {
        let svc = makeService()
        await svc.ingest(
            serverMessageId: "99999999-9999-9999-9999-999999999999",
            senderUserId: Self.momId, emoji: "✨", setAt: Date()
        )
        // No parent row → nothing stored anywhere.
        let count = try XCTUnwrap(try? store.reactions(forMessageId: "99999999-9999-9999-9999-999999999999"))
        XCTAssertTrue(count.isEmpty)
    }
}

extension ReactionServiceTests {
    /// Overlapping updates for the SAME message must serialize: a slow
    /// first update that ends in rollback must not erase a second
    /// update that the user made (and saw succeed) in the meantime.
    func test_overlapping_updates_serialize_slow_failure_cannot_erase_newer_success() async throws {
        // PUT counter, lock-guarded so the test thread can observe A's PUT
        // arriving without racing the URLProtocol worker thread. The slow
        // 500 is assigned to the FIRST PUT; gating B's start on putCount==1
        // (below) makes that first PUT deterministically A's, instead of
        // relying on the scheduling order of two `async let` tasks (the
        // source of this test's old flakiness — whichever PUT happened to
        // arrive first got the 500, sometimes inverting A/B's outcomes).
        let putLock = NSLock()
        nonisolated(unsafe) var putCount = 0
        let bumpPut: @Sendable () -> Int = {
            putLock.lock(); defer { putLock.unlock() }
            putCount += 1
            return putCount
        }
        let readPut: @Sendable () -> Int = {
            putLock.lock(); defer { putLock.unlock() }
            return putCount
        }
        SimpleStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            if path.contains("/keys/message/") {
                let body: [String: Any] = ["devices": [[
                    "device_id": Self.momDev,
                    "public_key": Data(repeating: 1, count: 32).base64EncodedString(),
                    "message_pubkey": Data(repeating: 2, count: 1216).base64EncodedString(),
                    "enrolled_at": 1,
                ]]]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if bumpPut() == 1 {
                // First update (A): slow 500 — Thread.sleep is fine in
                // the URLProtocol's worker thread.
                Thread.sleep(forTimeInterval: 0.15)
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            let body: [String: Any] = ["id": "rx-2", "received_at": 2]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let svc = makeService()

        // Fire A (will fail slowly), then wait until A's PUT is actually in
        // flight before firing B — so the slow 500 is deterministically A's
        // and the fast 200 is B's, regardless of task-start scheduling.
        async let a = svc.setReaction(
            messageRowId: "m-1", serverMessageId: Self.serverMessageId,
            toUserId: Self.momId, emoji: "👍"
        )
        var spins = 0
        while readPut() < 1 {
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            spins += 1
            if spins > 5_000 { XCTFail("A's PUT never reached the stub"); break }
        }
        async let b = svc.setReaction(
            messageRowId: "m-1", serverMessageId: Self.serverMessageId,
            toUserId: Self.momId, emoji: "🧡"
        )
        let (outcomeA, outcomeB) = await (a, b)

        if case .rolledBack = outcomeA {} else {
            XCTFail("A should have rolled back, got \(outcomeA)")
        }
        XCTAssertEqual(outcomeB, .applied)
        // The user's final intent (B = 🧡) must survive A's rollback.
        let stored = try store.reactions(forMessageId: "m-1")
        XCTAssertEqual(stored.first?.reaction, "🧡",
                       "slow rollback of A erased the newer successful B")
    }
}
