import XCTest
import WebRTC
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class CallServiceTests: XCTestCase {

    /// Records every payload a CallService ships through sendSignal.
    private actor SignalRecorder {
        private(set) var payloads: [CallSignalPayload] = []
        func record(_ p: CallSignalPayload) { payloads.append(p) }
    }

    func test_startOutgoing_emits_offer_with_audio_media_line() async throws {
        let service = CallService()
        let recorder = SignalRecorder()

        try await service.startOutgoing(
            kind: "audio",
            iceServers: [],
            sendSignal: { await recorder.record($0) }
        )

        let payloads = await recorder.payloads
        guard case .offer(let sdp) = payloads.first else {
            XCTFail("expected first signal to be an offer, got \(payloads)")
            return
        }
        XCTAssertTrue(sdp.contains("v=0"),     "SDP should start with v=0")
        XCTAssertTrue(sdp.contains("m=audio"), "SDP should contain audio media line")

        service.end()
    }

    /// Two CallServices complete the offer/answer SDP handshake through
    /// an in-memory signal loop — the full caller↔callee signaling path
    /// without a network. (ICE stays empty: relay-only policy with no
    /// TURN server yields no candidates, which is exactly the policy.)
    func test_offer_answer_handshake_between_two_services() async throws {
        let caller = CallService()
        let callee = CallService()
        let answered = expectation(description: "caller received answer")

        // Callee first — its peer connection must exist before the
        // caller's offer arrives.
        try await callee.startIncoming(
            kind: "audio",
            iceServers: [],
            sendSignal: { payload in
                // Callee → caller leg.
                await caller.handleSignal(payload)
                if case .answer = payload { answered.fulfill() }
            }
        )

        try await caller.startOutgoing(
            kind: "audio",
            iceServers: [],
            sendSignal: { payload in
                // Caller → callee leg: the offer triggers the callee's
                // answer, which loops back above.
                await callee.handleSignal(payload)
            }
        )

        await fulfillment(of: [answered], timeout: 10)
        caller.end()
        callee.end()
    }

    func test_handleSignal_without_peer_connection_is_noop() async {
        let service = CallService()
        // No start* call — must not crash.
        await service.handleSignal(.answer(sdp: "v=0\r\n"))
        await service.handleSignal(.ice(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0))
    }

    /// Round-38: a peer can stream `ice` frames before sending an offer/answer.
    /// The pre-SDP candidate buffer must be bounded so a flood can't grow client
    /// memory without limit while the call is still setting up.
    func test_pre_sdp_ice_flood_is_capped() async throws {
        let service = CallService()
        // Bring up a peer connection (outgoing offer) but never apply a remote
        // description — candidates stay buffered.
        try await service.startOutgoing(kind: "audio", iceServers: [], sendSignal: { _ in })
        for i in 0..<1000 {
            await service.handleSignal(.ice(candidate: "candidate:\(i) 1 udp 1 1.2.3.4 5 typ host", sdpMid: "0", sdpMLineIndex: 0))
        }
        XCTAssertLessThanOrEqual(service._pendingRemoteCandidateCount(), 128,
                                 "pre-SDP ICE buffer must be bounded against a flood")
    }

    func test_relayOnlyConfig_enforces_relay_policy() {
        let cfg = CallService.relayOnlyConfig()
        XCTAssertEqual(cfg.iceTransportPolicy, .relay)
        XCTAssertEqual(cfg.bundlePolicy,       .maxBundle)
        XCTAssertEqual(cfg.rtcpMuxPolicy,      .require)
        XCTAssertEqual(cfg.sdpSemantics,       .unifiedPlan)
    }

    func test_toggleMute_flips_audio_track() async throws {
        let service = CallService()
        try await service.startOutgoing(kind: "audio", iceServers: [], sendSignal: { _ in })
        XCTAssertTrue(service.toggleMute(),  "first toggle mutes")
        XCTAssertFalse(service.toggleMute(), "second toggle unmutes")
        service.end()
    }
}

final class CallSignalPayloadTests: XCTestCase {

    /// The JSON shapes are frozen by v0.2.3's call_media_session.dart —
    /// `kind` discriminator + sdp / candidate / sdpMid / sdpMLineIndex.
    func test_offer_roundtrip_and_wire_keys() throws {
        let payload = CallSignalPayload.offer(sdp: "v=0 test")
        let data = try JSONEncoder().encode(payload)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["kind"] as? String, "offer")
        XCTAssertEqual(obj["sdp"] as? String, "v=0 test")
        XCTAssertEqual(CallSignalPayload.from(json: data), payload)
    }

    func test_ice_roundtrip_with_optional_fields() throws {
        let payload = CallSignalPayload.ice(candidate: "candidate:1 udp", sdpMid: "0", sdpMLineIndex: 1)
        let data = try JSONEncoder().encode(payload)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["kind"] as? String, "ice")
        XCTAssertEqual(obj["candidate"] as? String, "candidate:1 udp")
        XCTAssertEqual(obj["sdpMid"] as? String, "0")
        XCTAssertEqual(obj["sdpMLineIndex"] as? Int, 1)
        XCTAssertEqual(CallSignalPayload.from(json: data), payload)
    }

    func test_unknown_kind_decodes_to_nil() {
        let data = Data(#"{"kind":"hologram","sdp":"x"}"#.utf8)
        XCTAssertNil(CallSignalPayload.from(json: data))
    }

    func test_outbound_frame_matches_server_contract() throws {
        let frame = ControlOutbound.callSignal(
            callId: "call-7", payload: .answer(sdp: "v=0 a"), signalId: "sig-1"
        )
        let data = try JSONEncoder().encode(frame)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "call_signal")
        XCTAssertEqual(obj["call_id"] as? String, "call-7")
        XCTAssertEqual(obj["signal_id"] as? String, "sig-1")
        let inner = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(inner["kind"] as? String, "answer")
    }
}
