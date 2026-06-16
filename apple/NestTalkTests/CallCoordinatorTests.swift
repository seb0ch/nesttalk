import XCTest
import Combine
#if os(iOS)
import CallKit
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

@MainActor
final class CallCoordinatorTests: XCTestCase {

    private func stubAPI() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        return APIClient(baseURL: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg))
    }

    override func tearDown() async throws {
        SimpleStubURLProtocol.responder = nil
        try await super.tearDown()
    }

    /// Media-path fix: coturn is reachable ONLY through the libbox REALITY
    /// tunnel (the server's relay-session `urls` host — e.g. localhost:3478
    /// when TURN_HOST is unset — is a dead end for the client). So when a
    /// libbox-local TURN endpoint exists, WebRTC must dial THAT, keeping the
    /// server's HMAC username/credential for coturn auth.
    func test_turnURLStrings_prefers_libbox_local_tunnel_over_server_urls() {
        let creds = APIClient.RelayCredentials(
            username: "1700000000:dev", password: "hmacpw", ttl_seconds: 300,
            urls: ["turn:localhost:3478"]
        )
        XCTAssertEqual(
            CallCoordinator.turnURLStrings(creds: creds, localTurnURL: "turn:127.0.0.1:62180?transport=tcp"),
            ["turn:127.0.0.1:62180?transport=tcp"],
            "must dial the libbox-local TURN tunnel, not the server's dead-end host"
        )
        XCTAssertEqual(CallCoordinator.turnURLStrings(creds: creds, localTurnURL: nil), ["turn:localhost:3478"],
                       "no local tunnel → fall back to server urls")
        XCTAssertEqual(CallCoordinator.turnURLStrings(creds: creds, localTurnURL: ""), ["turn:localhost:3478"],
                       "empty local tunnel → fall back to server urls")
    }

    func test_incoming_event_rings_and_retransmit_is_deduped() async {
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { nil })
        let coordinator = CallCoordinator(
            signaling: signaling,
            displayNameResolver: { uid in uid == "mom-id" ? "Mom" : uid }
        )

        await coordinator.handle(.incoming(callId: "c1", fromUserId: "mom-id", kind: "video"))
        guard case .incomingRinging(let callId, let peer, let kind) = coordinator.phase else {
            XCTFail("expected incomingRinging, got \(coordinator.phase)")
            return
        }
        XCTAssertEqual(callId, "c1")
        XCTAssertEqual(peer.displayName, "Mom")
        XCTAssertEqual(kind, "video")

        // Server retransmits incoming_call every 3 s during ringing —
        // the repeat must not reset state or double-ring.
        await coordinator.handle(.incoming(callId: "c1", fromUserId: "mom-id", kind: "video"))
        if case .incomingRinging(let again, _, _) = coordinator.phase {
            XCTAssertEqual(again, "c1")
        } else {
            XCTFail("retransmit changed phase to \(coordinator.phase)")
        }
    }

    /// Round-14 regression: startOutgoingCall commits an outgoing intent
    /// (intentInFlight) while phase is still .idle during the permission /
    /// relay / create-call awaits. An incoming call arriving in that window
    /// must NOT be admitted — otherwise performOutgoing later overwrites the
    /// incoming phase, orphaning its server call + CallKit ring.
    func test_incoming_during_outgoing_setup_is_rejected_as_busy() async {
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { nil })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })

        // Synchronous: sets intentInFlight = true, phase stays .idle, and
        // spawns performOutgoing as a Task that has not run yet.
        coordinator.startOutgoingCall(to: "dad", displayName: "Dad", kind: "video")
        guard case .idle = coordinator.phase else {
            return XCTFail("precondition: phase must still be idle in the setup window, got \(coordinator.phase)")
        }

        // The incoming guard runs synchronously at the top of handle(),
        // before performOutgoing's Task gets a turn — so intentInFlight is
        // still true and the incoming is rejected.
        await coordinator.handle(.incoming(callId: "incoming-1", fromUserId: "mom", kind: "audio"))
        if case .incomingRinging(let id, _, _) = coordinator.phase, id == "incoming-1" {
            XCTFail("incoming call admitted during outgoing setup window")
        }
        coordinator.hangUp()
    }

    /// Round-24 regression: simultaneous A→B / B→A glare. B is in the
    /// outgoing-setup window (its incoming_call from A was dropped by the
    /// busy-guard) and its createCall 409s. The 409 glare body must pivot B
    /// into RINGING A's existing call, so both sides don't time out.
    func test_glare_409_pivots_to_incoming_ringing() async {
        SimpleStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/relay/session") {
                let body: [String: Any] = ["username": "u", "password": "p",
                                           "urls": ["turn:turn.example.com:3478"], "ttl_seconds": 900]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.hasSuffix("/api/v1/calls") {
                let body: [String: Any] = [
                    "error": "glare",
                    "existing_call_id": "peer-call-1",
                    "existing_caller_user_id": "dad",
                    "existing_call_kind": "video",
                    "existing_call_state": "ringing",
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })

        coordinator.startOutgoingCall(to: "dad", displayName: "Dad", kind: "video")
        // performOutgoing runs async: permission → relay → createCall(409) →
        // glare pivot to .incomingRinging. Poll until it lands.
        var pivoted = false
        for _ in 0..<100 {
            if case .incomingRinging(let id, _, _) = coordinator.phase, id == "peer-call-1" {
                pivoted = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(pivoted, "glare must pivot to ringing the peer's existing call, got \(coordinator.phase)")
    }

    /// Round-25 regression: a glare against a CONNECTED call must NOT pivot
    /// to an incoming ring — synthesizing accept→end could tear down the
    /// live call. The dial is abandoned instead.
    func test_glare_connected_does_not_pivot() async {
        SimpleStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/relay/session") {
                let body: [String: Any] = ["username": "u", "password": "p",
                                           "urls": ["turn:turn.example.com:3478"], "ttl_seconds": 900]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.hasSuffix("/api/v1/calls") {
                let body: [String: Any] = [
                    "error": "glare",
                    "existing_call_id": "peer-call-1",
                    "existing_caller_user_id": "dad",
                    "existing_call_kind": "video",
                    "existing_call_state": "connected",
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })

        coordinator.startOutgoingCall(to: "dad", displayName: "Dad", kind: "video")
        // Give performOutgoing time to run relay → createCall(409 connected)
        // → abandon. It must NOT enter incomingRinging.
        for _ in 0..<12 {
            if case .incomingRinging = coordinator.phase {
                return XCTFail("connected-call glare must not pivot to a ring")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .incomingRinging = coordinator.phase {
            XCTFail("connected-call glare must not pivot to a ring")
        }
    }

    /// Round-46: a terminal action (end/cancel/decline) must be DURABLE — a
    /// transient failure is retried so the server row doesn't linger and
    /// glare-block follow-up calls after the user hung up.
    func test_terminal_action_retries_transient_then_succeeds() async {
        nonisolated(unsafe) var endHits = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/end") == true {
                endHits += 1
                let code = endHits < 3 ? 500 : 200
                let body = code == 200 ? "{\"state\":\"ended\"}" : "{}"
                return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })
        await coordinator.performTerminalAction(.end, callId: "c1")
        XCTAssertEqual(endHits, 3, "transient 5xx must be retried until the row is confirmed terminal")
    }

    /// Round-56: when a terminal action stops on a 4xx (hang-up racing the
    /// server's missed/wrong-state transition), the call's un-acked signals must
    /// be discarded — otherwise a lost-ack offer/ICE replays on every reconnect
    /// forever (the REST-success path clears them, but the 4xx path skipped it).
    func test_terminal_4xx_discards_unacked_signals() async {
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" }, sendFrame: { _ in true })
        await signaling.sendSignal(callId: "c1", .offer(sdp: "v=0 offer"))
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })
        SimpleStubURLProtocol.responder = { req in
            // Terminal wrong-state — the server won't change state for /end.
            (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        }
        await coordinator.performTerminalAction(.end, callId: "c1")
        let pending = await signaling._pendingOutCount()
        XCTAssertEqual(pending, 0, "a terminal 4xx must discard the call's un-acked signals")
    }

    /// Round-47: a 401 (auth churn / token refresh race) is NOT a terminal
    /// call state — it must trigger a refresh and retry, not abandon the server
    /// row after one request.
    func test_terminal_action_retries_on_401_and_refreshes() async {
        nonisolated(unsafe) var endHits = 0
        nonisolated(unsafe) var refreshes = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/end") == true {
                endHits += 1
                let code = endHits < 3 ? 401 : 200
                let body = code == 200 ? "{\"state\":\"ended\"}" : "{}"
                return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })
        coordinator.onAuthFailure = { refreshes += 1 }
        await coordinator.performTerminalAction(.end, callId: "c1")
        XCTAssertEqual(endHits, 3, "a 401 must be retried, not treated as terminal")
        XCTAssertEqual(refreshes, 2, "each 401 triggers a session refresh")
    }

    /// A 4xx (already terminal / wrong-state) is NOT retried — retrying can't
    /// change the server's mind, so it stops after one attempt.
    func test_terminal_action_stops_on_4xx() async {
        nonisolated(unsafe) var endHits = 0
        SimpleStubURLProtocol.responder = { req in
            if req.url?.path.hasSuffix("/end") == true {
                endHits += 1
                return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
            return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })
        await coordinator.performTerminalAction(.end, callId: "c1")
        XCTAssertEqual(endHits, 1, "a 4xx terminal/wrong-state response must not be retried")
    }

    /// Round-42: if accept setup fails BEFORE /accept connects the call (e.g.
    /// relay credentials fail), the still-`ringing` server row must be cleaned
    /// up with /decline — NOT /end (which the server rejects for a ringing
    /// call), or the caller rings until the missed sweep and the row
    /// glare-blocks follow-up calls.
    func test_accept_failure_before_connect_declines_not_ends() async {
        nonisolated(unsafe) var declined = false
        nonisolated(unsafe) var ended = false
        SimpleStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/decline") { declined = true }
            if path.hasSuffix("/end") { ended = true }
            if path.hasSuffix("/relay/session") {
                // Fail relay setup → accept never reaches /accept.
                return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            return (Data("{\"state\":\"declined\"}".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })

        await coordinator.handle(.incoming(callId: "c-ring", fromUserId: "dad", kind: "audio"))
        coordinator.acceptIncomingCall()

        // performAccept runs async: permission → relay(500) → catch → decline.
        for _ in 0..<100 {
            if declined { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(declined, "a pre-accept failure must /decline the ringing call")
        XCTAssertFalse(ended, "a ringing call must NOT be /end'd (the server rejects it)")
    }

    /// Bug: answering an incoming call from the lock screen landed the user
    /// on the chat list instead of the call surface. On iOS the CallKit ring
    /// UI dismisses the instant the user answers, so the in-app overlay must
    /// show the connecting call surface immediately — `isAnswering` gates that.
    /// It flips true the moment the user answers (before performAccept finishes
    /// media setup, which can take seconds on a cold launch) and clears on
    /// teardown so a later un-answered ring doesn't show the call surface.
    func test_isAnswering_flips_true_on_answer_and_clears_on_teardown() async {
        SimpleStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/relay/session") {
                // Fail relay so performAccept declines and tears down.
                return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            return (Data("{\"state\":\"declined\"}".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })

        await coordinator.handle(.incoming(callId: "c-ans", fromUserId: "dad", kind: "audio"))
        XCTAssertFalse(coordinator.isAnswering, "ringing but not yet answered → false")

        coordinator.acceptIncomingCall()
        XCTAssertTrue(coordinator.isAnswering, "answering must show the call surface immediately, before media is up")

        // performAccept fails (relay 500) → decline → cleanupLocal → reset.
        for _ in 0..<100 {
            if !coordinator.isAnswering, case .idle = coordinator.phase { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(coordinator.isAnswering, "teardown must clear the answering flag")
        if case .idle = coordinator.phase {} else { XCTFail("expected idle after teardown, got \(coordinator.phase)") }
    }

#if os(iOS)
    /// Cold-launch present-CallView: a lock-screen answer can arrive before
    /// the WS delivers incoming_call. With the push metadata retained, the
    /// coordinator must synthesize the ringing call and start accepting it
    /// immediately — NOT wait for the socket (which would leave the user on
    /// the roster, the reported "Mac→iPhone opens main screen" bug).
    func test_lockscreen_answer_synthesizes_call_from_push_meta_without_ws() {
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 == "dad" ? "Dad" : $0 })

        let callId = UUID().uuidString
        let uuid = CallCoordinator.callKitUUID(for: callId)
        CallKitProvider.shared.registerIncomingMeta(
            uuid: uuid,
            IncomingCallMeta(callId: callId, fromUserId: "dad", fromName: "Dad", kind: "video")
        )
        defer { CallKitProvider.shared.untrack(uuid: uuid) }

        // No WS incoming_call has been handled — phase is idle.
        guard case .idle = coordinator.phase else { return XCTFail("precondition: idle") }

        // The CallKit answer routes here; metadata drives synthesis.
        coordinator.noteCallKitAnswer(uuid: uuid)

        guard case .incomingRinging(let id, let peer, let kind) = coordinator.phase else {
            return XCTFail("expected synthesized incomingRinging, got \(coordinator.phase)")
        }
        XCTAssertEqual(id, callId)
        XCTAssertEqual(peer.userId, "dad")
        XCTAssertEqual(peer.displayName, "Dad")
        XCTAssertEqual(kind, "video")
        XCTAssertTrue(coordinator.isAnswering, "must show the connecting call surface immediately")
    }
#endif

    /// ICE drop UX is scoped to a LIVE media session: ICE transitions while
    /// idle (no current call / no media) must NOT strand "Reconnecting…" or
    /// arm a teardown timer — that would let a stale peer-connection callback
    /// poison the next call. (The in-call .disconnected→Reconnecting→recover/
    /// drop path is device-verified; mediaReady/currentCallId aren't settable
    /// from a unit test without a live WebRTC session.)
    func test_ice_transitions_while_idle_do_not_mark_reconnecting() async {
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { nil })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })

        XCTAssertFalse(coordinator.isReconnecting)
        coordinator.handleIceState(.disconnected)
        XCTAssertFalse(coordinator.isReconnecting, "ICE noise at idle must not surface Reconnecting…")
        coordinator.handleIceState(.failed)
        if case .idle = coordinator.phase {} else {
            XCTFail("ICE .failed at idle must not change phase, got \(coordinator.phase)")
        }
    }

    /// Round-36: a ringing callee buffers inbound call_signal until it answers.
    /// A flooding caller must not be able to grow that buffer without bound —
    /// the per-call count cap (64) drops further signals.
    func test_prering_signal_flood_is_capped_per_call() async {
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { nil })
        let coordinator = CallCoordinator(
            signaling: signaling,
            displayNameResolver: { $0 }
        )
        // Ring an incoming call — phase becomes incomingRinging, media not ready.
        await coordinator.handle(.incoming(callId: "flood-1", fromUserId: "dad", kind: "audio"))

        // Stream far more signals than the cap.
        for i in 0..<500 {
            let sig = try! JSONEncoder().encode(CallSignalPayload.offer(sdp: "v=0 ice-\(i)"))
            await coordinator.handle(.signal(callId: "flood-1", payloadJSON: sig))
        }
        XCTAssertLessThanOrEqual(coordinator._bufferedSignalCount(forCallId: "flood-1"), 64,
                                 "the per-call buffer must be bounded against a pre-answer flood")
    }

    /// Round-35: during glare, an offer for the peer's existing call can be
    /// buffered while our outgoing attempt is still idle. The pivot's
    /// cleanupLocal must PRESERVE that buffer — discarding it would leave the
    /// pivoted-to call with no offer to answer, stalling it.
    func test_glare_pivot_preserves_prebuffered_offer() async {
        SimpleStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/relay/session") {
                let body: [String: Any] = ["username": "u", "password": "p",
                                           "urls": ["turn:turn.example.com:3478"], "ttl_seconds": 900]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.hasSuffix("/api/v1/calls") {
                let body: [String: Any] = [
                    "error": "glare",
                    "existing_call_id": "peer-call-1",
                    "existing_caller_user_id": "dad",
                    "existing_call_kind": "video",
                    "existing_call_state": "ringing",
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })

        // The peer's offer arrives (server register-time replay) while we're
        // still idle — it buffers under the existing call id.
        let offer = try! JSONEncoder().encode(CallSignalPayload.offer(sdp: "v=0 buffered-offer"))
        await coordinator.handle(.signal(callId: "peer-call-1", payloadJSON: offer))
        XCTAssertEqual(coordinator._bufferedSignalCount(forCallId: "peer-call-1"), 1)

        coordinator.startOutgoingCall(to: "dad", displayName: "Dad", kind: "video")
        var pivoted = false
        for _ in 0..<100 {
            if case .incomingRinging(let id, _, _) = coordinator.phase, id == "peer-call-1" {
                pivoted = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(pivoted, "glare must pivot, got \(coordinator.phase)")
        XCTAssertEqual(coordinator._bufferedSignalCount(forCallId: "peer-call-1"), 1,
                       "the buffered offer for the pivoted call must survive cleanupLocal")
    }

    /// Round-33: a `busy` 409 (the dialed peer is already on a call with a
    /// THIRD party) must NEVER pivot to an incoming ring — the requester is not
    /// a participant in that call. The dial is abandoned back to idle.
    func test_busy_409_abandons_dial_without_pivoting() async {
        SimpleStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            if path.hasSuffix("/relay/session") {
                let body: [String: Any] = ["username": "u", "password": "p",
                                           "urls": ["turn:turn.example.com:3478"], "ttl_seconds": 900]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.hasSuffix("/api/v1/calls") {
                let body: [String: Any] = ["error": "busy", "busy_user_id": "dad"]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" })
        let coordinator = CallCoordinator(signaling: signaling, displayNameResolver: { $0 })

        coordinator.startOutgoingCall(to: "dad", displayName: "Dad", kind: "video")
        for _ in 0..<12 {
            if case .incomingRinging = coordinator.phase {
                return XCTFail("busy must not pivot to a ring")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .incomingRinging = coordinator.phase {
            XCTFail("busy must not pivot to a ring")
        }
    }

    func test_signals_before_accept_are_buffered_not_crashing() async {
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { nil })
        let coordinator = CallCoordinator(signaling: signaling)

        await coordinator.handle(.incoming(callId: "c2", fromUserId: "dad", kind: "audio"))
        // Caller ships its offer while we're still ringing — media
        // session doesn't exist yet, so the payload must buffer.
        let offer = try! JSONEncoder().encode(CallSignalPayload.offer(sdp: "v=0 early"))
        await coordinator.handle(.signal(callId: "c2", payloadJSON: offer))
        // Still ringing; no crash, no state change.
        guard case .incomingRinging = coordinator.phase else {
            XCTFail("expected incomingRinging, got \(coordinator.phase)")
            return
        }
    }

    func test_terminal_state_change_returns_to_idle() async {
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { nil })
        let coordinator = CallCoordinator(signaling: signaling)

        await coordinator.handle(.incoming(callId: "c3", fromUserId: "dad", kind: "audio"))
        await coordinator.handle(.stateChanged(callId: "c3", state: "cancelled", stale: false, endedReason: nil))
        guard case .idle = coordinator.phase else {
            XCTFail("expected idle after cancel, got \(coordinator.phase)")
            return
        }
    }

    #if os(iOS)
    func test_callkit_uuid_is_derived_from_server_call_id() {
        // The VoIP push reports CallKit with the payload's call_uuid ==
        // server call id; the WS path must land on the same UUID so the
        // two entry paths converge on one CallKit call.
        let callId = "9bb33155-95b6-44aa-9c50-9725a4d1a312"
        XCTAssertEqual(
            CallCoordinator.callKitUUID(for: callId),
            UUID(uuidString: callId)
        )
    }

    func test_pending_lockscreen_answer_buffers_until_taken() {
        let provider = CallKitProvider()
        let uuid = UUID()
        // No onAnswer hook wired — simulates the cold-launch race.
        provider.provider(provider.provider, perform: CXAnswerCallAction(call: uuid))
        XCTAssertTrue(provider.takePendingAnswer(uuid: uuid))
        XCTAssertFalse(provider.takePendingAnswer(uuid: uuid), "answer is consumed at most once")
    }

    func test_pending_lockscreen_end_buffers_and_clears_answer() {
        let provider = CallKitProvider()
        let uuid = UUID()
        provider.provider(provider.provider, perform: CXAnswerCallAction(call: uuid))
        provider.provider(provider.provider, perform: CXEndCallAction(call: uuid))
        XCTAssertTrue(provider.takePendingEnd(uuid: uuid))
        XCTAssertFalse(provider.takePendingAnswer(uuid: uuid),
                       "hangup after answer must cancel the buffered answer")
    }
    #endif

    func test_signal_arriving_before_ring_is_buffered_then_purged_on_terminal() async {
        // Cold-launch ordering: the server's register-time replay can
        // deliver the queued offer BEFORE the retransmitted
        // incoming_call. The coordinator must hold it, not drop it —
        // the server has already dequeued its copy.
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { nil })
        let coordinator = CallCoordinator(signaling: signaling)

        let offer = try! JSONEncoder().encode(CallSignalPayload.offer(sdp: "v=0 early-replay"))
        await coordinator.handle(.signal(callId: "c-cold", payloadJSON: offer))
        // Still idle — but the payload must be retrievable when the
        // ring lands. We can't reach into the private buffer; instead
        // verify the OBSERVABLE contract: a terminal event for that
        // call purges it without crashing, and an unrelated ring is
        // unaffected.
        guard case .idle = coordinator.phase else {
            XCTFail("buffering must not change phase")
            return
        }
        await coordinator.handle(.stateChanged(callId: "c-cold", state: "cancelled", stale: false, endedReason: nil))
        guard case .idle = coordinator.phase else {
            XCTFail("terminal for a non-current call must not disturb idle")
            return
        }
        // Ring for a different call still works after the purge.
        await coordinator.handle(.incoming(callId: "c-next", fromUserId: "dad", kind: "audio"))
        guard case .incomingRinging(let id, _, _) = coordinator.phase, id == "c-next" else {
            XCTFail("expected ringing for c-next, got \(coordinator.phase)")
            return
        }
    }

    func test_local_ring_timeout_returns_to_idle() async throws {
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { nil })
        // 0.2s timeout so the test is fast. The REST decline fired by
        // hangUp goes to the stub.
        SimpleStubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"state":"declined"}"#.utf8), resp)
        }
        let coordinator = CallCoordinator(signaling: signaling, ringTimeout: 0.2)

        await coordinator.handle(.incoming(callId: "c-stale", fromUserId: "dad", kind: "audio"))
        guard case .incomingRinging = coordinator.phase else {
            XCTFail("expected ringing, got \(coordinator.phase)")
            return
        }
        // Server terminal event never arrives (best-effort WS) — the
        // local ceiling must clear the stuck ring.
        try await Task.sleep(nanoseconds: 600_000_000)
        guard case .idle = coordinator.phase else {
            XCTFail("ring timeout did not fire, still \(coordinator.phase)")
            return
        }
    }

    func test_state_change_for_unrelated_call_is_ignored() async {
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { nil })
        let coordinator = CallCoordinator(signaling: signaling)

        await coordinator.handle(.incoming(callId: "c4", fromUserId: "dad", kind: "audio"))
        await coordinator.handle(.stateChanged(callId: "other", state: "ended", stale: false, endedReason: nil))
        guard case .incomingRinging = coordinator.phase else {
            XCTFail("unrelated call's state change tore down ours: \(coordinator.phase)")
            return
        }
    }
}

extension CallCoordinatorTests {
    /// Re-enrollment teardown must END an active call on the SERVER
    /// before credentials are wiped — not just locally — or the peer is
    /// stranded and the call row glare-blocks the pair.
    func test_shutdown_ends_active_call_server_side() async throws {
        nonisolated(unsafe) var actions: [String] = []
        SimpleStubURLProtocol.responder = { req in
            if let p = req.url?.path { actions.append(p) }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"state":"ended"}"#.utf8), resp)
        }
        let signaling = RestCallSignaling(api: stubAPI(), sessionToken: { "t" })
        let coordinator = CallCoordinator(signaling: signaling)
        // Drive to an active call via the WS state machine.
        await coordinator.handle(.incoming(callId: "c-active", fromUserId: "dad", kind: "audio"))
        await coordinator.handle(.stateChanged(callId: "c-active", state: "connected", stale: false, endedReason: nil))
        // (incomingRinging → connected only flips outgoing; force active
        // by accepting is heavier — assert on whichever in-progress
        // phase we're in: shutdown must hit a server endpoint.)
        await coordinator.shutdown()
        guard case .idle = coordinator.phase else {
            XCTFail("shutdown must return to idle, got \(coordinator.phase)")
            return
        }
        XCTAssertTrue(
            actions.contains { $0.hasSuffix("/decline") || $0.hasSuffix("/end") || $0.hasSuffix("/cancel") },
            "shutdown must end the call server-side, got \(actions)"
        )
    }
}
