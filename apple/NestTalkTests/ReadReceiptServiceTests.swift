import XCTest
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class ReadReceiptServiceTests: XCTestCase {

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

    func test_mark_read_writes_local_receipt_and_posts_ack() async throws {
        nonisolated(unsafe) var ackCount = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/ack") == true {
                ackCount += 1
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), resp)
        }
        let svc = ReadReceiptService(store: store, api: api, sessionToken: { "t" })
        await svc.markRead(rowId: "m-1", serverId: "srv-1")
        // ack POST happens async — give it a tick.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(ackCount, 1)
    }

    func test_mark_read_without_server_id_skips_ack() async throws {
        nonisolated(unsafe) var ackCount = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/ack") == true { ackCount += 1 }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let svc = ReadReceiptService(store: store, api: api, sessionToken: { "t" })
        // Rows still in `sending` have no server id — local stamp only.
        await svc.markRead(rowId: "m-1", serverId: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(ackCount, 0)
    }

    func test_paused_queue_flushes_when_unpaused() async throws {
        // Durable read-acks join read_receipts → messages for the server id,
        // so the inbound rows must exist.
        try store.insert(MessageStore.Message(
            id: "m-1", threadUserId: "mom", outgoing: false,
            plaintext: "a", state: "delivered", sentAt: Date(), serverId: "srv-1"))
        try store.insert(MessageStore.Message(
            id: "m-2", threadUserId: "mom", outgoing: false,
            plaintext: "b", state: "delivered", sentAt: Date(), serverId: "srv-2"))
        nonisolated(unsafe) var ackCount = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/ack") == true { ackCount += 1 }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let svc = ReadReceiptService(store: store, api: api, sessionToken: { "t" })
        await svc.setPaused(true)
        await svc.markRead(rowId: "m-1", serverId: "srv-1")
        await svc.markRead(rowId: "m-2", serverId: "srv-2")
        let queued = await svc._pendingCount()
        XCTAssertEqual(queued, 2)
        XCTAssertEqual(ackCount, 0, "no acks while paused")
        await svc.setPaused(false)
        XCTAssertEqual(ackCount, 2)
        let remaining = await svc._pendingCount()
        XCTAssertEqual(remaining, 0, "all acked after unpause")
    }

    /// Round-16 regression: a read-ack that fails (server unreachable) must
    /// stay durable and be retried on the next flush — never silently
    /// dropped, or the peer never sees "read".
    func test_failed_read_ack_is_retried_on_flush() async throws {
        try store.insert(MessageStore.Message(
            id: "m-9", threadUserId: "mom", outgoing: false,
            plaintext: "x", state: "delivered", sentAt: Date(), serverId: "srv-9"))
        nonisolated(unsafe) var ackShouldFail = true
        nonisolated(unsafe) var ackOk = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/ack") == true {
                if ackShouldFail {
                    return (Data(), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
                }
                ackOk += 1
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let svc = ReadReceiptService(store: store, api: api, sessionToken: { "t" })
        await svc.markRead(rowId: "m-9", serverId: "srv-9")   // POST fails
        let afterFail = await svc._pendingCount()
        XCTAssertEqual(afterFail, 1, "failed ack stays durable")

        ackShouldFail = false
        await svc.flushPendingReadAcks()
        XCTAssertEqual(ackOk, 1)
        let afterRetry = await svc._pendingCount()
        XCTAssertEqual(afterRetry, 0, "retry clears the pending receipt")
    }

    /// Round-52: a PERMANENT read-ack failure (403/404/410 — a purged or
    /// unauthorized id) must be dropped from the durable queue, not block every
    /// later receipt behind it. The flush continues past it and delivers the
    /// newer, valid receipt.
    func test_permanent_read_ack_failure_does_not_wedge_later_receipts() async throws {
        try store.insert(MessageStore.Message(
            id: "m-A", threadUserId: "mom", outgoing: false,
            plaintext: "a", state: "delivered", sentAt: Date(), serverId: "srv-A"))
        try store.insert(MessageStore.Message(
            id: "m-B", threadUserId: "mom", outgoing: false,
            plaintext: "b", state: "delivered", sentAt: Date(), serverId: "srv-B"))
        nonisolated(unsafe) var ackedOk: [String] = []
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/ack") == true {
                let sid = req.url!.deletingLastPathComponent().lastPathComponent
                if sid == "srv-A" {
                    return (Data(), HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
                }
                ackedOk.append(sid)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let svc = ReadReceiptService(store: store, api: api, sessionToken: { "t" })
        await svc.setPaused(true)
        // Queue both durably (acked=0); srv-A sorts first (earlier read_at).
        await svc.markRead(rowId: "m-A", serverId: "srv-A", now: Date(timeIntervalSince1970: 1))
        await svc.markRead(rowId: "m-B", serverId: "srv-B", now: Date(timeIntervalSince1970: 2))
        let queued = await svc._pendingCount()
        XCTAssertEqual(queued, 2)

        await svc.setPaused(false) // triggers flushPendingReadAcks

        let remaining = await svc._pendingCount()
        XCTAssertEqual(remaining, 0,
                       "a permanent failure must not wedge the queue — both ids resolved")
        XCTAssertEqual(ackedOk, ["srv-B"], "the deliverable receipt still flushed past the permanent one")
    }

    func test_ingest_peer_read_marks_outgoing_message_read() async throws {
        // Peer acks arrive keyed by SERVER id, not the local row id.
        try store.insert(MessageStore.Message(
            id: "m-out", threadUserId: "mom", outgoing: true,
            plaintext: "hi", state: "delivered", sentAt: Date(),
            serverId: "srv-out"
        ))
        let svc = ReadReceiptService(store: store, api: api, sessionToken: { "t" })
        await svc.ingestPeerRead(serverId: "srv-out")
        let row = try XCTUnwrap(store.message(id: "m-out"))
        XCTAssertEqual(row.state, "read")
    }

    func test_ingest_peer_delivered_never_downgrades_read() async throws {
        try store.insert(MessageStore.Message(
            id: "m-out2", threadUserId: "mom", outgoing: true,
            plaintext: "hi", state: "read", sentAt: Date(),
            serverId: "srv-out2"
        ))
        let svc = ReadReceiptService(store: store, api: api, sessionToken: { "t" })
        await svc.ingestPeerDelivered(serverId: "srv-out2")
        let row = try XCTUnwrap(store.message(id: "m-out2"))
        XCTAssertEqual(row.state, "read", "delivered must not downgrade read")
    }

    /// Round-14 regression: receipts are broadcast best-effort, so an ack
    /// that lands while the sender is offline is lost. On reconnect the
    /// client must reconcile by querying GET /messages/{id}/status and
    /// lifting still-open outgoing rows.
    func test_reconcile_lifts_outgoing_rows_from_server_status() async throws {
        // Two open outgoing rows + one already-read (must not be re-queried
        // downward) + one without a server id (not reconcilable).
        try store.insert(MessageStore.Message(
            id: "m-a", threadUserId: "mom", outgoing: true,
            plaintext: "a", state: "sent_to_server", sentAt: Date(), serverId: "srv-a"))
        try store.insert(MessageStore.Message(
            id: "m-b", threadUserId: "mom", outgoing: true,
            plaintext: "b", state: "delivered", sentAt: Date(), serverId: "srv-b"))
        try store.insert(MessageStore.Message(
            id: "m-c", threadUserId: "mom", outgoing: true,
            plaintext: "c", state: "sent_to_server", sentAt: Date(), serverId: "srv-c"))

        nonisolated(unsafe) var queried: [String] = []
        SimpleStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            // .../messages/{id}/status
            let id = path.replacingOccurrences(of: "/status", with: "")
                .components(separatedBy: "/").last ?? ""
            queried.append(id)
            let status: String
            switch id {
            case "srv-a": status = "read"        // delivered→read jump
            case "srv-b": status = "read"        // delivered→read
            case "srv-c": status = "pending"     // not yet delivered → leave
            default:      status = "gone"
            }
            let data = try! JSONSerialization.data(withJSONObject: ["status": status])
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let svc = ReadReceiptService(store: store, api: api, sessionToken: { "t" })
        await svc.reconcileOutgoingStatuses()

        XCTAssertEqual(try store.message(id: "m-a")?.state, "read")
        XCTAssertEqual(try store.message(id: "m-b")?.state, "read")
        XCTAssertEqual(try store.message(id: "m-c")?.state, "sent_to_server",
                       "pending status must not change the local row")
        // Only rows with a server id and a non-terminal receipt state are queried.
        XCTAssertEqual(Set(queried), ["srv-a", "srv-b", "srv-c"])
    }
}
