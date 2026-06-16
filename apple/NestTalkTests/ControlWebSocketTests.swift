import XCTest
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

/// Pure parser tests for `ControlWebSocket.parse(data:)`. The live WS
/// roundtrip (URLSessionWebSocketTask against a swift-nio echo fixture)
/// is reserved for the live-integration workflow — Sprint 1 unit tests
/// stay parser-bound.
final class ControlWebSocketTests: XCTestCase {

    private func encode(_ json: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: json)
    }

    func test_parses_message_event() {
        let data = encode([
            "type": "message",
            "id": "m-1",
            "from": "mom", "to": "self",
            "envelope": "AAAA", "sent_at": 1, "received_at": 2,
            "reply_to_id": NSNull(),
        ])
        guard case .messageIncoming(let id, let from, _, let env, _, _, let reply) = ControlWebSocket.parse(data: data)! else {
            XCTFail(); return
        }
        XCTAssertEqual(id, "m-1")
        XCTAssertEqual(from, "mom")
        XCTAssertEqual(env, "AAAA")
        XCTAssertNil(reply)
    }

    func test_parses_typing_start_and_stop() {
        let start = encode(["type": "typing_start", "from": "x", "to": "y", "at": 99])
        let stop  = encode(["type": "typing_stop",  "from": "x", "to": "y", "at": 100])
        guard case .typingStart = ControlWebSocket.parse(data: start)! else { XCTFail(); return }
        guard case .typingStop  = ControlWebSocket.parse(data: stop)!  else { XCTFail(); return }
    }

    func test_parses_message_delivered_and_read() {
        let d = encode(["type": "message_delivered", "message_id": "m-1"])
        let r = encode(["type": "message_read",      "message_id": "m-1"])
        XCTAssertEqual(ControlWebSocket.parse(data: d), .messageDelivered(messageId: "m-1"))
        XCTAssertEqual(ControlWebSocket.parse(data: r), .messageRead(messageId: "m-1"))
    }

    func test_parses_incoming_call_event() {
        let data = encode([
            "type": "incoming_call",
            "call_id": "c-1", "from_user_id": "mom", "kind": "video", "at": 42,
        ])
        guard case .incomingCall(let cid, let from, let kind, let at) = ControlWebSocket.parse(data: data)! else {
            XCTFail(); return
        }
        XCTAssertEqual(cid, "c-1")
        XCTAssertEqual(from, "mom")
        XCTAssertEqual(kind, "video")
        XCTAssertEqual(at, 42)
    }

    func test_unknown_type_yields_unknown_case() {
        let data = encode(["type": "made_up", "x": 1])
        XCTAssertEqual(ControlWebSocket.parse(data: data), .unknown(type: "made_up"))
    }

    func test_malformed_returns_nil() {
        XCTAssertNil(ControlWebSocket.parse(data: Data("not json".utf8)))
    }

    func test_outbound_typing_encodes_to_expected_shape() throws {
        let frame = ControlOutbound.typingStart(to: "mom")
        let data = try JSONEncoder().encode(frame)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(json["type"], "typing_start")
        XCTAssertEqual(json["to"], "mom")
    }

    func test_backoff_grows_with_attempt_and_caps_at_30() {
        let b1 = ControlWebSocket.backoffSeconds(forAttempt: 1)
        let b2 = ControlWebSocket.backoffSeconds(forAttempt: 2)
        let b6 = ControlWebSocket.backoffSeconds(forAttempt: 6)
        let b20 = ControlWebSocket.backoffSeconds(forAttempt: 20)
        XCTAssertGreaterThanOrEqual(b2, b1)
        XCTAssertGreaterThan(b6, b1)
        XCTAssertLessThanOrEqual(b20, 30 * 1.15)  // jitter ceiling
    }

    /// Keepalive half-open detection: the bounded ping races the pong
    /// callback against a timeout. Exactly one of them may resume the
    /// awaiting continuation — `PingGate` enforces that. A double resume
    /// traps `withCheckedContinuation`; a missed resume hangs the keepalive
    /// loop forever (the very half-open hang we're guarding against). This
    /// asserts the first caller wins and the loser is a no-op, even under
    /// concurrent fire.
    func test_pingGate_fires_exactly_once_under_concurrency() async {
        let gate = ControlWebSocket.PingGate()
        let counter = FireCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { gate.fire { counter.bump() } }
            }
        }
        XCTAssertEqual(counter.value, 1, "PingGate must invoke the block for exactly one caller")

        // A second fire after the gate is spent stays closed.
        gate.fire { counter.bump() }
        XCTAssertEqual(counter.value, 1, "a spent PingGate must not fire again")
    }
}

/// Lock-guarded tally for the PingGate concurrency test.
private final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

extension ControlWebSocketTests {
    /// Cold-launch race: the server replays queued call signals during
    /// WS registration — possibly before AppState's pump has subscribed.
    /// Events delivered with no subscriber must buffer and replay when
    /// events() attaches, not vanish (a dropped replayed offer has no
    /// REST catch-up).
    func test_events_delivered_before_subscriber_are_replayed() async {
        let ws = ControlWebSocket(baseURL: URL(string: "http://stub.test")!, token: "t")
        await ws.deliver(.callSignal(callId: "c1", payloadJSON: Data("{}".utf8), atMillis: 1))
        await ws.deliver(.typingStart(from: "a", to: "b", atMillis: 2))

        let stream = await ws.events()
        var iter = stream.makeAsyncIterator()
        let first = await iter.next()
        let second = await iter.next()
        if case .callSignal(let id, _, _) = first {
            XCTAssertEqual(id, "c1")
        } else {
            XCTFail("expected buffered callSignal first, got \(String(describing: first))")
        }
        if case .typingStart = second {} else {
            XCTFail("expected buffered typingStart second, got \(String(describing: second))")
        }
        await ws.stop()
    }
}
