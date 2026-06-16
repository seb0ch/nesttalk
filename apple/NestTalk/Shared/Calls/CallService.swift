import Foundation
import WebRTC

/// Owns one WebRTC peer connection per call — the Swift port of
/// v0.2.3's `call_media_session.dart` semantics:
///
///   * Caller: `startOutgoing` → createOffer → setLocal → emit
///     `{"kind":"offer"}` via `sendSignal`.
///   * Callee: `startIncoming` → wait; the remote offer arrives through
///     `handleSignal`, which sets it, creates the answer, and emits
///     `{"kind":"answer"}`.
///   * ICE candidates flow both ways as `{"kind":"ice"}` payloads;
///     remote candidates that arrive before the remote description are
///     buffered and flushed once it lands.
///
/// The factory is long-lived (WebRTC best practice — factory creation is
/// expensive); per-call state resets in `end()`.
public final class CallService {

    public enum CallError: Error, CustomStringConvertible {
        case offerFailed(String)
        case remoteSDPFailed(String)
        case peerConnectionFailed

        public var description: String {
            switch self {
            case .offerFailed(let m):      return "CallService offer failed: \(m)"
            case .remoteSDPFailed(let m):  return "CallService remote SDP: \(m)"
            case .peerConnectionFailed:    return "CallService: peerConnection(with:) returned nil"
            }
        }
    }

    public let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private let delegateAdapter = PeerConnectionDelegateAdapter()
    private var sendSignal: (@Sendable (CallSignalPayload) async -> Void)?

    /// Remote-candidate buffer — guarded by `signalLock` because
    /// `handleSignal` (app side) and `didGenerate` (WebRTC signaling
    /// thread) race on it.
    private let signalLock = NSLock()
    private var hasRemoteDescription = false
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    /// Cap on remote ICE candidates buffered before the remote description
    /// lands. A real ICE gather is a few dozen candidates; an authenticated
    /// peer could otherwise stream `ice` frames before ever sending an
    /// offer/answer and grow this without bound (the server caps frame size,
    /// not pre-SDP relay). Excess candidates are dropped.
    private static let maxPendingRemoteCandidates = 128

    public private(set) var videoCapturer: VideoCapturer?
    private var localAudioTrack: RTCAudioTrack?

    /// UI hooks — set by the coordinator before `start*`. Both are
    /// invoked on the WebRTC signaling thread; consumers hop to
    /// MainActor themselves.
    public var onRemoteVideoTrack: (@Sendable (RTCVideoTrack?) -> Void)?
    public var onIceConnectionState: (@Sendable (RTCIceConnectionState) -> Void)?

    public var localVideoTrack: RTCVideoTrack? { videoCapturer?.videoTrack }

    public init() {
        // RTCInitializeSSL is process-global; the matched RTCCleanupSSL
        // tears down OpenSSL state for the whole process, so subsequent
        // CallService instances can fail to re-init cleanly. The init
        // call lives here as a no-op-on-second-call safe path; cleanup
        // is intentionally NOT called from deinit.
        Self.bootstrapSSLOnce()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        delegateAdapter.service = self
    }

    deinit {
        peerConnection?.close()
        // Do NOT call RTCCleanupSSL here — see bootstrapSSLOnce() docs.
    }

    /// Initialize WebRTC's process-global SSL state at most once for the
    /// process lifetime. Safe to call from any thread.
    private static let _sslBootstrap: Void = {
        RTCInitializeSSL()
    }()
    public static func bootstrapSSLOnce() {
        _ = _sslBootstrap
    }

    // MARK: - Session lifecycle

    /// Caller side: build the peer, add local media, create + emit the
    /// SDP offer. `kind` is "audio" or "video" (v0.2.3 call kinds).
    public func startOutgoing(
        kind: String,
        iceServers: [RTCIceServer],
        sendSignal: @escaping @Sendable (CallSignalPayload) async -> Void
    ) async throws {
        try await prepare(kind: kind, iceServers: iceServers, sendSignal: sendSignal)
        guard let pc = peerConnection else { throw CallError.peerConnectionFailed }

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            pc.offer(for: Self.offerConstraints()) { sdp, err in
                if let err { cont.resume(throwing: CallError.offerFailed(err.localizedDescription)); return }
                guard let sdp else { cont.resume(throwing: CallError.offerFailed("nil sdp")); return }
                cont.resume(returning: sdp)
            }
        }
        try await setLocalDescription(offer, on: pc)
        await sendSignal(.offer(sdp: offer.sdp))
    }

    /// Callee side: build the peer and wait — the remote offer arrives
    /// via `handleSignal`, which produces and ships the answer.
    public func startIncoming(
        kind: String,
        iceServers: [RTCIceServer],
        sendSignal: @escaping @Sendable (CallSignalPayload) async -> Void
    ) async throws {
        try await prepare(kind: kind, iceServers: iceServers, sendSignal: sendSignal)
    }

    /// Process an inbound `call_signal` payload from the peer.
    public func handleSignal(_ payload: CallSignalPayload) async {
        guard let pc = peerConnection else { return }
        switch payload {
        case .offer(let sdp), .iceRestartOffer(let sdp):
            guard !sdp.isEmpty else { return }
            do {
                try await setRemoteDescription(.init(type: .offer, sdp: sdp), on: pc)
                markRemoteDescriptionAndFlush(on: pc)
                let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
                    pc.answer(for: Self.offerConstraints()) { sdp, err in
                        if let err { cont.resume(throwing: CallError.offerFailed(err.localizedDescription)); return }
                        guard let sdp else { cont.resume(throwing: CallError.offerFailed("nil answer sdp")); return }
                        cont.resume(returning: sdp)
                    }
                }
                try await setLocalDescription(answer, on: pc)
                if case .iceRestartOffer = payload {
                    await sendSignal?(.iceRestartAnswer(sdp: answer.sdp))
                } else {
                    await sendSignal?(.answer(sdp: answer.sdp))
                }
            } catch {
                NTLogger.calls.error("handleSignal offer failed: \(String(describing: error))")
            }
        case .answer(let sdp), .iceRestartAnswer(let sdp):
            guard !sdp.isEmpty else { return }
            do {
                try await setRemoteDescription(.init(type: .answer, sdp: sdp), on: pc)
                markRemoteDescriptionAndFlush(on: pc)
            } catch {
                NTLogger.calls.error("handleSignal answer failed: \(String(describing: error))")
            }
        case .ice(let candidate, let sdpMid, let sdpMLineIndex):
            guard !candidate.isEmpty else { return }
            let ice = RTCIceCandidate(
                sdp: candidate, sdpMLineIndex: sdpMLineIndex ?? 0, sdpMid: sdpMid
            )
            signalLock.lock()
            let ready = hasRemoteDescription
            var dropped = false
            if !ready {
                if pendingRemoteCandidates.count < Self.maxPendingRemoteCandidates {
                    pendingRemoteCandidates.append(ice)
                } else {
                    dropped = true
                }
            }
            signalLock.unlock()
            if dropped {
                NTLogger.calls.error("dropping remote ICE candidate — pre-SDP buffer cap (\(Self.maxPendingRemoteCandidates)) reached")
            }
            if ready {
                pc.add(ice) { _ in /* best-effort, mirrors v0.2.3 */ }
            }
        }
    }

    /// Returns the new mute state (true = muted).
    @discardableResult
    public func toggleMute() -> Bool {
        guard let track = localAudioTrack else { return false }
        track.isEnabled.toggle()
        return !track.isEnabled
    }

    public func setVideoEnabled(_ enabled: Bool) {
        videoCapturer?.videoTrack.isEnabled = enabled
    }

    /// Test introspection: number of remote ICE candidates buffered pre-SDP.
    func _pendingRemoteCandidateCount() -> Int {
        signalLock.lock()
        defer { signalLock.unlock() }
        return pendingRemoteCandidates.count
    }

    public func end() {
        videoCapturer?.stop()
        videoCapturer = nil
        localAudioTrack = nil
        peerConnection?.close()
        peerConnection = nil
        sendSignal = nil
        onRemoteVideoTrack?(nil)
        signalLock.lock()
        hasRemoteDescription = false
        pendingRemoteCandidates.removeAll()
        signalLock.unlock()
    }

    // MARK: - Config

    /// Relay-only RTC configuration matching v0.2.3 policy: no direct ICE
    /// candidates, all media goes through coturn.
    static func relayOnlyConfig() -> RTCConfiguration {
        let cfg = RTCConfiguration()
        cfg.iceTransportPolicy = .relay
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        cfg.sdpSemantics = .unifiedPlan
        return cfg
    }

    /// `RTCConfiguration` populated with TURN credentials from
    /// `GET /api/v1/relay/session`. Relay-only policy remains enforced —
    /// direct candidates never escape.
    public static func relayOnlyConfig(creds: APIClient.RelayCredentials) -> RTCConfiguration {
        let cfg = relayOnlyConfig()
        cfg.iceServers = [
            RTCIceServer(
                urlStrings: creds.urls,
                username: creds.username,
                credential: creds.password
            )
        ]
        return cfg
    }

    // MARK: - Internals

    private func prepare(
        kind: String,
        iceServers: [RTCIceServer],
        sendSignal: @escaping @Sendable (CallSignalPayload) async -> Void
    ) async throws {
        // A fresh call always starts from a clean slate.
        if peerConnection != nil { end() }
        self.sendSignal = sendSignal

        let config = Self.relayOnlyConfig()
        config.iceServers = iceServers
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let pc = factory.peerConnection(
            with: config, constraints: constraints, delegate: delegateAdapter
        ) else {
            throw CallError.peerConnectionFailed
        }
        self.peerConnection = pc

        // Audio track — always.
        let audioSource = factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: nil
        ))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        pc.add(audioTrack, streamIds: ["nesttalk-stream"])
        self.localAudioTrack = audioTrack

        // Video track — only for video calls. Camera failure degrades to
        // an audio-only leg rather than killing the call (v0.2.3 parity).
        if kind == "video" {
            let capturer = VideoCapturer(factory: factory)
            pc.add(capturer.videoTrack, streamIds: ["nesttalk-stream"])
            self.videoCapturer = capturer
            do {
                try await capturer.start()
            } catch {
                NTLogger.calls.error("camera start failed, audio-only leg: \(String(describing: error))")
            }
        }
    }

    private static func offerConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )
    }

    private func setLocalDescription(_ desc: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(desc) { err in
                if let err { cont.resume(throwing: CallError.offerFailed("setLocal: \(err.localizedDescription)")); return }
                cont.resume(returning: ())
            }
        }
    }

    private func setRemoteDescription(_ desc: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(desc) { err in
                if let err { cont.resume(throwing: CallError.remoteSDPFailed(err.localizedDescription)); return }
                cont.resume(returning: ())
            }
        }
    }

    private func markRemoteDescriptionAndFlush(on pc: RTCPeerConnection) {
        signalLock.lock()
        hasRemoteDescription = true
        let buffered = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        signalLock.unlock()
        for ice in buffered {
            pc.add(ice) { _ in }
        }
    }

    // Called from the delegate adapter (WebRTC signaling thread).
    fileprivate func emitLocalCandidate(_ candidate: RTCIceCandidate) {
        guard let sendSignal else { return }
        let payload = CallSignalPayload.ice(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        )
        Task { await sendSignal(payload) }
    }

    fileprivate func remoteTrackArrived(_ track: RTCMediaStreamTrack) {
        if let video = track as? RTCVideoTrack {
            onRemoteVideoTrack?(video)
        }
    }

    fileprivate func iceStateChanged(from pc: RTCPeerConnection, _ state: RTCIceConnectionState) {
        // Drop callbacks from a peer connection we've already replaced or
        // closed: a stale `.failed` from the PREVIOUS call must never reach
        // the coordinator and tear down a newly-started one. The single
        // shared delegate adapter stays the delegate of the old PC until it's
        // released, so identity-filter here at the source.
        guard pc === peerConnection else { return }
        onIceConnectionState?(state)
    }
}

// MARK: - WebRTC delegate glue

private final class PeerConnectionDelegateAdapter: NSObject, RTCPeerConnectionDelegate {
    weak var service: CallService?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // Plan-B fallback path; unified-plan peers use didAdd:streams:.
        if let video = stream.videoTracks.first {
            service?.remoteTrackArrived(video)
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        service?.iceStateChanged(from: peerConnection, newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        service?.emitLocalCandidate(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        if let track = rtpReceiver.track {
            service?.remoteTrackArrived(track)
        }
    }
}
