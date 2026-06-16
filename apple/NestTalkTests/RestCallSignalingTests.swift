import XCTest
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class RestCallSignalingTests: XCTestCase {

    private var api: APIClient!
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        session = URLSession(configuration: cfg)
        api = APIClient(baseURL: URL(string: "http://stub.test")!, session: session)
    }

    override func tearDown() async throws {
        SimpleStubURLProtocol.responder = nil
        try await super.tearDown()
    }

    func test_create_call_posts_callee_and_kind_records_active_id() async throws {
        SimpleStubURLProtocol.responder = { req in
            XCTAssertEqual(req.url?.path, "/api/v1/calls")
            XCTAssertEqual(req.httpMethod, "POST")
            let body: [String: Any] = ["call_id": "call-1", "state": "ringing"]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let signaling = RestCallSignaling(api: api, sessionToken: { "t" })
        let callId = try await signaling.createCall(calleeUserId: "mom", kind: "video")
        XCTAssertEqual(callId, "call-1")
        let active = await signaling.activeCallId
        XCTAssertEqual(active, "call-1")
    }

    /// Round-35: a locally-initiated terminal action (end / cancel / decline)
    /// must purge that call's un-acked signals — the initiator can't rely on
    /// receiving its own terminal `call_state_changed`. A lost ack would
    /// otherwise leave a stale offer/ICE that replays on every reconnect.
    func test_local_end_purges_unacked_signals_for_call() async throws {
        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = ["state": "ended"]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let signaling = RestCallSignaling(api: api, sessionToken: { "t" }, sendFrame: { _ in true })
        await signaling.sendSignal(callId: "c1", .offer(sdp: "v=0 keep"))
        await signaling.sendSignal(callId: "other", .offer(sdp: "v=0 other"))
        var count = await signaling._pendingOutCount()
        XCTAssertEqual(count, 2)

        try await signaling.end(callId: "c1")
        count = await signaling._pendingOutCount()
        XCTAssertEqual(count, 1, "only the ended call's un-acked signals are purged")
    }

    /// A FAILED terminal action must NOT purge the call's signals — the server
    /// still believes the call is live, so the signals stay replayable.
    func test_failed_terminal_action_keeps_unacked_signals() async throws {
        SimpleStubURLProtocol.responder = { req in
            (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let signaling = RestCallSignaling(api: api, sessionToken: { "t" }, sendFrame: { _ in true })
        await signaling.sendSignal(callId: "c1", .offer(sdp: "v=0 keep"))
        do {
            try await signaling.end(callId: "c1")
            XCTFail("a 500 terminal action must throw")
        } catch {
            // expected
        }
        let count = await signaling._pendingOutCount()
        XCTAssertEqual(count, 1, "a failed terminal action must not abandon replayable signals")
    }

    /// Round-56: a `call_missed` event is terminal — it must drop the call's
    /// un-acked signals, or a lost-ack offer/ICE replays forever on reconnects.
    func test_call_missed_clears_unacked_signals() async throws {
        let signaling = RestCallSignaling(api: api, sessionToken: { nil }, sendFrame: { _ in true })
        await signaling.sendSignal(callId: "c1", .offer(sdp: "v=0 offer"))
        let before = await signaling._pendingOutCount()
        XCTAssertEqual(before, 1)

        await signaling.ingest(.callMissed(callId: "c1", fromUserId: "mom", atMillis: 1))

        let after = await signaling._pendingOutCount()
        XCTAssertEqual(after, 0, "a missed call must clear its un-acked signals")
    }

    /// Round-49: a transient WS send failure (sendFrame → false) with NO
    /// reconnect must NOT strand the signal. The old pump marked it `sent`
    /// before awaiting, so a failed send left it `sent=true` forever (future
    /// pumps skip it, no ack can remove it). The signal must stay retryable and
    /// the scheduled re-pump must re-send it on its own.
    func test_failed_send_without_reconnect_is_retried() async throws {
        actor FlakySocket {
            private var failNext = true
            private(set) var sent: [ControlOutbound] = []
            func send(_ f: ControlOutbound) -> Bool {
                if failNext { failNext = false; return false } // first send fails
                sent.append(f)
                return true
            }
            func deliveredCount() -> Int { sent.count }
        }
        let socket = FlakySocket()
        let signaling = RestCallSignaling(api: api, sessionToken: { nil },
                                          sendFrame: { await socket.send($0) })

        await signaling.sendSignal(callId: "c1", .offer(sdp: "v=0 retryme"))
        // First send failed → nothing delivered yet, but the signal is retained.
        let early = await socket.deliveredCount()
        XCTAssertEqual(early, 0, "the first send failed")
        let stillPending = await signaling._pendingOutCount()
        XCTAssertEqual(stillPending, 1, "a failed send must keep the signal queued")

        // No reconnect / flush — the scheduled re-pump (1s) must re-send it.
        var delivered = false
        for _ in 0..<40 {
            if await socket.deliveredCount() > 0 { delivered = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(delivered, "a failed send with no reconnect must be retried by the scheduled re-pump")
    }

    /// Round-59: the server withholds `call_signal_ack` when it can't
    /// deliver/queue a signal (peer backpressure, full replay queue),
    /// expecting the sender to retry. A SUCCESSFUL local send marked the
    /// signal `sent` with no ack timer, so it sat in `unacked` forever until
    /// an unrelated reconnect. The ack watchdog must re-send the SAME
    /// signal_id on a deadline — no reconnect needed (the server dedups).
    func test_unacked_signal_is_resent_on_ack_timeout_without_reconnect() async throws {
        actor Recorder {
            private(set) var signalIds: [String] = []
            func record(_ f: ControlOutbound) -> Bool {
                if case .callSignal(_, _, let sid) = f { signalIds.append(sid) }
                return true // local send always succeeds; server never acks
            }
            func ids() -> [String] { signalIds }
        }
        let rec = Recorder()
        let signaling = RestCallSignaling(
            api: api, sessionToken: { nil },
            sendFrame: { await rec.record($0) },
            ackTimeout: 0.05
        )

        await signaling.sendSignal(callId: "c1", .offer(sdp: "v=0 needsack"))

        // No ack is ever ingested — the watchdog must re-send the SAME id.
        var resent = false
        for _ in 0..<60 {
            let ids = await rec.ids()
            if ids.count >= 2, ids[0] == ids[1] { resent = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(resent,
            "a shipped-but-unacked signal must be re-sent on the ack deadline without a reconnect")

        // It stays queued until an ack or a terminal state arrives.
        let pending = await signaling._pendingOutCount()
        XCTAssertEqual(pending, 1, "the signal remains unacked until call_signal_ack or terminal")
    }

    /// Round-33: a `busy` 409 (the dialed peer is on a call with a THIRD
    /// party) must surface as CallBusyError — NEVER as CallGlareError. Decoding
    /// it as glare would let the client synthesize a ring for a call it isn't
    /// part of and try to accept/end it.
    func test_create_call_busy_409_throws_busy_not_glare() async throws {
        SimpleStubURLProtocol.responder = { req in
            // Server busy body: discriminator only, no third-party metadata.
            let body: [String: Any] = ["error": "busy", "busy_user_id": "mom"]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await api.createCall(calleeUserId: "mom", sessionToken: "t")
            XCTFail("expected a 409 to throw")
        } catch let busy as APIClient.CallBusyError {
            XCTAssertEqual(busy.busyUserId, "mom")
        } catch {
            XCTFail("expected CallBusyError, got \(type(of: error)): \(error)")
        }
    }

    /// Defense against version skew: even if an older/buggy server attaches
    /// existing_call_* fields to a busy body, the discriminator gates glare —
    /// `error == "busy"` is never decoded as a recoverable glare.
    func test_create_call_busy_body_with_stray_fields_is_not_glare() async throws {
        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = [
                "error": "busy",
                "busy_user_id": "mom",
                "existing_call_id": "leaked-id",
                "existing_caller_user_id": "third-party",
                "existing_call_kind": "audio",
                "existing_call_state": "connected",
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await api.createCall(calleeUserId: "mom", sessionToken: "t")
            XCTFail("expected a 409 to throw")
        } catch is APIClient.CallBusyError {
            // expected — discriminator wins over stray fields
        } catch is APIClient.CallGlareError {
            XCTFail("a busy discriminator must never be decoded as glare")
        }
    }

    /// Round-46 version-skew: an older server emits a glare body WITHOUT
    /// existing_call_state even for a CONNECTED same-pair call. The client must
    /// fail CLOSED — decode a non-"ringing" state so the coordinator never
    /// synthesizes a ring for what might be a live call.
    func test_create_call_glare_missing_state_does_not_decode_ringing() async throws {
        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = [
                "error": "glare",
                "existing_call_id": "call-x",
                "existing_caller_user_id": "mom",
                "existing_call_kind": "video",
                // no existing_call_state
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await api.createCall(calleeUserId: "mom", sessionToken: "t")
            XCTFail("expected a 409 to throw")
        } catch let glare as APIClient.CallGlareError {
            XCTAssertNotEqual(glare.existingCallState, "ringing",
                              "a missing glare state must not be treated as ringing")
        }
    }

    /// A same-pair `glare` 409 still decodes to CallGlareError with detail.
    func test_create_call_glare_409_throws_glare_with_detail() async throws {
        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = [
                "error": "glare",
                "existing_call_id": "call-9",
                "existing_caller_user_id": "mom",
                "existing_call_kind": "video",
                "existing_call_state": "ringing",
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await api.createCall(calleeUserId: "mom", sessionToken: "t")
            XCTFail("expected a 409 to throw")
        } catch let glare as APIClient.CallGlareError {
            XCTAssertEqual(glare.existingCallId, "call-9")
            XCTAssertEqual(glare.existingCallerUserId, "mom")
            XCTAssertEqual(glare.existingCallState, "ringing")
        }
    }

    func test_sendSignal_failure_queues_and_flush_replays_in_order() async throws {
        actor FlakySocket {
            var up = false
            private(set) var sent: [ControlOutbound] = []
            func setUp(_ v: Bool) { up = v }
            func send(_ f: ControlOutbound) -> Bool {
                guard up else { return false }
                sent.append(f)
                return true
            }
        }
        let socket = FlakySocket()
        let signaling = RestCallSignaling(
            api: api,
            sessionToken: { nil },
            sendFrame: { await socket.send($0) }
        )

        // Socket down: both signals queue, none delivered.
        await signaling.sendSignal(callId: "c1", .offer(sdp: "v=0 one"))
        await signaling.sendSignal(callId: "c1", .ice(candidate: "cand-2", sdpMid: "0", sdpMLineIndex: 0))
        var pending = await signaling._pendingOutCount()
        XCTAssertEqual(pending, 2)
        let sentWhileDown = await socket.sent
        XCTAssertTrue(sentWhileDown.isEmpty)

        // Reconnect → flush replays in original order.
        await socket.setUp(true)
        await signaling.flushPendingSignals()
        let sent = await socket.sent
        XCTAssertEqual(sent.count, 2)
        guard case .callSignal(_, let first, let firstSignalId) = sent[0], case .offer = first else {
            return XCTFail("offer must replay first, got \(sent)")
        }
        // Still un-acked until the server confirms each signal_id.
        pending = await signaling._pendingOutCount()
        XCTAssertEqual(pending, 2, "signals stay retained until acked")

        // Server acks both → the retained set clears.
        for frame in sent {
            if case .callSignal(_, _, let sid) = frame {
                await signaling.ingest(.callSignalAck(signalId: sid, atMillis: 1))
            }
        }
        pending = await signaling._pendingOutCount()
        XCTAssertEqual(pending, 0, "acked signals are dropped")
        _ = firstSignalId
    }

    func test_terminal_state_purges_queued_signals() async throws {
        let signaling = RestCallSignaling(
            api: api,
            sessionToken: { nil },
            sendFrame: { _ in false }   // socket permanently down
        )
        await signaling.ingest(.incomingCall(callId: "c9", fromUserId: "mom", kind: "audio", atMillis: 1))
        await signaling.sendSignal(callId: "c9", .offer(sdp: "v=0 stale"))
        let queuedBefore = await signaling._pendingOutCount()
        XCTAssertEqual(queuedBefore, 1)
        await signaling.ingest(.callStateChanged(callId: "c9", state: "cancelled", stale: false, endedReason: nil, atMillis: 2))
        let queuedAfter = await signaling._pendingOutCount()
        XCTAssertEqual(queuedAfter, 0, "terminal call's queue must purge")
    }

    func test_sendSignal_ships_call_signal_frame_over_ws() async throws {
        actor FrameRecorder {
            private(set) var frames: [ControlOutbound] = []
            func record(_ f: ControlOutbound) { frames.append(f) }
        }
        let recorder = FrameRecorder()
        let signaling = RestCallSignaling(
            api: api,
            sessionToken: { "t" },
            sendFrame: { await recorder.record($0); return true }
        )
        await signaling.sendSignal(callId: "c9", .offer(sdp: "v=0 x"))
        let frames = await recorder.frames
        XCTAssertEqual(frames.count, 1)
        guard case .callSignal(let callId, let payload, let signalId) = frames.first else {
            XCTFail("expected callSignal frame, got \(frames)")
            return
        }
        XCTAssertEqual(callId, "c9")
        XCTAssertEqual(payload, .offer(sdp: "v=0 x"))
        XCTAssertFalse(signalId.isEmpty, "every signal carries a non-empty signal_id")
    }

    func test_accept_decline_cancel_end_post_to_correct_paths() async throws {
        nonisolated(unsafe) var actions: [String] = []
        SimpleStubURLProtocol.responder = { req in
            if let p = req.url?.path { actions.append(p) }
            let body: [String: Any] = ["state": "ended"]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let signaling = RestCallSignaling(api: api, sessionToken: { "t" })
        try await signaling.accept(callId: "c1")
        try await signaling.decline(callId: "c1")
        try await signaling.cancel(callId: "c1")
        try await signaling.end(callId: "c1")
        XCTAssertEqual(actions, [
            "/api/v1/calls/c1/accept",
            "/api/v1/calls/c1/decline",
            "/api/v1/calls/c1/cancel",
            "/api/v1/calls/c1/end",
        ])
    }

    func test_relay_session_decodes_credentials() async throws {
        SimpleStubURLProtocol.responder = { req in
            XCTAssertEqual(req.url?.path, "/api/v1/relay/session")
            let body: [String: Any] = [
                "username": "u", "password": "p", "ttl_seconds": 900,
                "urls": ["turn:turn.example.com:3478"],
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let signaling = RestCallSignaling(api: api, sessionToken: { "t" })
        let creds = try await signaling.relaySession()
        XCTAssertEqual(creds.username, "u")
        XCTAssertEqual(creds.urls, ["turn:turn.example.com:3478"])
        XCTAssertEqual(creds.ttl_seconds, 900)
    }

    func test_ingest_incoming_call_yields_event_and_sets_active_id() async throws {
        let signaling = RestCallSignaling(api: api, sessionToken: { nil })
        let stream = await signaling.events()
        var iter = stream.makeAsyncIterator()
        await signaling.ingest(.incomingCall(callId: "c2", fromUserId: "mom", kind: "audio", atMillis: 1))
        let event = await iter.next()
        XCTAssertEqual(event, .incoming(callId: "c2", fromUserId: "mom", kind: "audio"))
        let active = await signaling.activeCallId
        XCTAssertEqual(active, "c2")
    }

    /// Round-18 regression: CallCoordinator.start subscribes to events()
    /// from a spawned task, so the WS pump can ingest an incoming offer
    /// BEFORE the subscription attaches. The event must be buffered and
    /// drained on subscribe, not dropped into a nil continuation.
    func test_event_ingested_before_subscribe_is_buffered_then_drained() async {
        let signaling = RestCallSignaling(api: api, sessionToken: { nil })
        // No subscriber yet — these arrive into the buffer.
        await signaling.ingest(.incomingCall(callId: "c5", fromUserId: "dad", kind: "video", atMillis: 1))
        await signaling.ingest(.callSignal(callId: "c5", payloadJSON: Data("{}".utf8), atMillis: 2))
        // Subscribe AFTER the fact — buffered events must replay in order.
        let stream = await signaling.events()
        var iter = stream.makeAsyncIterator()
        let e1 = await iter.next()
        XCTAssertEqual(e1, .incoming(callId: "c5", fromUserId: "dad", kind: "video"))
        let e2 = await iter.next()
        guard case .signal(let cid, _) = e2 else {
            return XCTFail("expected buffered signal, got \(String(describing: e2))")
        }
        XCTAssertEqual(cid, "c5")
    }

    func test_ingest_state_changed_ended_clears_active_id() async throws {
        let signaling = RestCallSignaling(api: api, sessionToken: { nil })
        await signaling.ingest(.incomingCall(callId: "c3", fromUserId: "mom", kind: "video", atMillis: 1))
        await signaling.ingest(.callStateChanged(callId: "c3", state: "ended", stale: false, endedReason: "remote_ended", atMillis: 2))
        let active = await signaling.activeCallId
        XCTAssertNil(active)
    }
}

extension RestCallSignalingTests {
    /// Actor re-entrancy: while flushPendingSignals is awaiting the
    /// offer's (slow) send, a fresh ICE signal arrives. It must NOT
    /// overtake the offer — strict head-order delivery.
    func test_flush_is_single_flight_ice_cannot_overtake_offer() async throws {
        actor SlowSocket {
            private(set) var order: [String] = []
            private var up = false
            private var gate: CheckedContinuation<Void, Never>?
            func bringUp() { up = true }
            func send(_ f: ControlOutbound) async -> Bool {
                guard up else { return false }   // down → caller queues
                if case .callSignal(_, let p, _) = f, case .offer = p {
                    // Hold the offer mid-send so an ICE can race it.
                    await withCheckedContinuation { c in gate = c }
                }
                if case .callSignal(_, let p, _) = f {
                    switch p {
                    case .offer: order.append("offer")
                    case .ice:   order.append("ice")
                    default:     order.append("other")
                    }
                }
                return true
            }
            func release() { gate?.resume(); gate = nil }
            func snapshot() -> [String] { order }
        }
        let socket = SlowSocket()
        let signaling = RestCallSignaling(
            api: api, sessionToken: { nil },
            sendFrame: { await socket.send($0) }
        )
        // Socket down → the offer queues instead of sending.
        await signaling.sendSignal(callId: "c1", .offer(sdp: "v=0 offer"))
        let queued = await signaling._pendingOutCount()
        XCTAssertEqual(queued, 1)

        // Bring it up and flush — the offer's send now blocks on the gate.
        await socket.bringUp()
        let flush = Task { await signaling.flushPendingSignals() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let isFlushing = await signaling._isFlushing()
        XCTAssertTrue(isFlushing)
        // Fresh ICE arrives DURING the flush — must queue, not overtake.
        await signaling.sendSignal(callId: "c1", .ice(candidate: "cand", sdpMid: "0", sdpMLineIndex: 0))
        await socket.release()
        await flush.value
        let order = await socket.snapshot()
        XCTAssertEqual(order, ["offer", "ice"], "ICE must not overtake the offer")
    }
}
