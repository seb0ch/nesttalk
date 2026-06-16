import Foundation
import SwiftUI
import WebRTC
import AVFoundation
#if os(iOS)
import UIKit
#endif

/// App-level call state machine. Composes `RestCallSignaling` (REST +
/// WS relay), `CallService` (peer connection), and the platform ring
/// surface (CallKit on iOS, `IncomingCallSheet` on macOS) into one
/// observable object the UI drives.
///
/// Lifecycle mirror of v0.2.3's `call_service.dart`:
///   * outgoing: relay creds → `POST /calls` → ringing → offer ships
///     over WS while ringing → peer accepts → `call_state_changed
///     (connected)` → active.
///   * incoming: `incoming_call` WS event (retransmitted every 3 s —
///     deduped by callId) → ring UI → accept → `POST /calls/{id}/accept`
///     → media session up → buffered offer flushed → answer ships back.
///   * signals that arrive before the local media session exists are
///     buffered per call and flushed when it comes up.
@MainActor
public final class CallCoordinator: ObservableObject {

    public struct Peer: Equatable, Sendable {
        public let userId: String
        public let displayName: String
        public init(userId: String, displayName: String) {
            self.userId = userId
            self.displayName = displayName
        }
    }

    public enum Phase: Equatable {
        case idle
        case outgoingRinging(callId: String, peer: Peer)
        case incomingRinging(callId: String, peer: Peer, kind: String)
        case active(callId: String, peer: Peer)
    }

    @Published public private(set) var phase: Phase = .idle
    /// True from the instant the user answers an incoming call until the
    /// call is torn down. On iOS the CallKit ring UI dismisses the moment
    /// the user answers (especially a lock-screen answer on a cold launch),
    /// so the in-app overlay must show the connecting call surface
    /// immediately instead of `EmptyView` — otherwise the user lands on the
    /// chat list while `performAccept` sets up media. Gated separately from
    /// `phase` (which stays `.incomingRinging` until media is up) so the
    /// terminal-verb logic that keys off `.incomingRinging` is unaffected.
    @Published public private(set) var isAnswering = false
    /// True while the live call's media is interrupted (ICE `.disconnected`)
    /// — drives a "Reconnecting…" status instead of a frozen "Connected".
    /// Cleared when media recovers (`.connected`) or the call ends.
    @Published public private(set) var isReconnecting = false
    @Published public private(set) var isMuted = false
    @Published public private(set) var isVideoEnabled = true
    @Published public private(set) var remoteVideoTrack: RTCVideoTrack?

    public var localVideoTrack: RTCVideoTrack? { callService.localVideoTrack }

    public var currentCallId: String? {
        switch phase {
        case .idle: return nil
        case .outgoingRinging(let id, _), .incomingRinging(let id, _, _), .active(let id, _):
            return id
        }
    }

    private let signaling: RestCallSignaling
    /// The libbox-local TURN endpoint (`turn:127.0.0.1:<port>?transport=tcp`)
    /// that tunnels to coturn through the REALITY transport. The server's
    /// relay-session `urls` host is NOT reachable from the client (coturn is
    /// pod-internal, only :443/REALITY is exposed), so calls must dial this
    /// local tunnel and use the server only for the HMAC TURN credentials.
    /// nil when no transport is configured (DEBUG fake session / tests).
    private let localTurnURL: String?

    /// Retry budget for `performTerminalAction` — ~1h at the 30s backoff cap.
    /// Replaces the old fixed 6 (≈1 min) so realistic transient outages and
    /// app-backgrounding are covered before falling back to the server sweep.
    private let terminalMaxAttempts = 120
    private let callService: CallService
    private let resolveDisplayName: (String) -> String
    /// Client-side ringing ceiling — slightly past the server's 33 s
    /// window + 3 s grace, so a peer that never saw the terminal event
    /// (best-effort WS) still exits the ringing state on its own.
    /// Injectable for tests.
    private let ringTimeout: TimeInterval
    private var eventsTask: Task<Void, Never>?
    /// Grace after ICE drops to `.disconnected` before we tear the call
    /// down. The peer vanishing (force-quit / crash / network loss) shows as
    /// `.disconnected` within a few seconds, but ICE `.failed` can take 30s+
    /// behind a TURN relay — too long to leave a frozen "Connected". A brief
    /// window lets a real transient blip (network handoff) recover first.
    private var iceDisconnectTask: Task<Void, Never>?
    private static let iceDisconnectGrace: TimeInterval = 15
    private var ringTimeoutTask: Task<Void, Never>?
    /// Signals buffered before the local media session is up. Two
    /// producers fill it: the caller ships its offer while the callee
    /// is still ringing, AND the server's cold-launch replay flushes
    /// queued signals on WS register — which can beat the retransmitted
    /// `incoming_call` by up to one retransmit interval, so buffering
    /// must work even before the call is known (phase == .idle).
    private var pendingSignals: [String: [CallSignalPayload]] = [:]
    /// Parallel byte tally for `pendingSignals`, kept in sync via
    /// `appendBufferedSignal` / `dropBufferedSignals` so the per-call byte
    /// budget below is enforced without re-encoding buffered payloads.
    private var pendingSignalBytes: [String: Int] = [:]
    private static let maxBufferedSignalCalls = 4
    /// Per-call caps on signals buffered before media is ready. The server
    /// bounds its OFFLINE replay queue, but a live caller can still stream
    /// valid-sized SDP/ICE at a ringing callee; without a client cap those
    /// pile up until answer/timeout and can exhaust memory. Mirrors the
    /// server's per-call bounds (manager.go).
    private static let maxBufferedSignalsPerCall = 64
    private static let maxBufferedSignalBytesPerCall = 256 * 1024
    /// True once the WebRTC media session exists (capturer + tracks). The
    /// mute/video toggles are no-ops before this — `CallService` has no
    /// capturer yet — so the UI must disable them during the connecting
    /// window, or a toggle desyncs the on-screen state from the track that
    /// later starts enabled.
    @Published public private(set) var mediaReady = false
    private var activeKind = "video"
    /// Set synchronously when a dial/accept intent is admitted, cleared
    /// when its async flow completes. The phase only changes after the
    /// first await, so without this flag a double tap admits TWO flows
    /// — and the loser's failure cleanup (glare / wrong_state) tears
    /// down the winner's perfectly valid call.
    private var intentInFlight = false
    /// Hang-up pressed while an outgoing setup hadn't yet produced a
    /// call id (phase still idle) — performOutgoing checks it after
    /// every await and cancels the allocated server call.
    private var abortRequested = false
    /// Bumped on every local teardown. Setup flows capture it at entry
    /// and re-check after each await: a hang-up mid-setup must not let
    /// the resuming task resurrect the phase (ghost call after the
    /// user already ended it).
    private var callGeneration: UInt64 = 0
    #if os(iOS)
    private var callKitUUIDByCallId: [String: UUID] = [:]
    /// Set between `startOutgoingCall` (which requests the CallKit
    /// transaction) and the `onStart` action callback (which performs
    /// the dial once CallKit has authorized the call).
    private var pendingOutgoingPeer: Peer?
    /// The CallKit UUID of an outgoing call whose server callId mapping
    /// doesn't exist yet (setup in flight). Lets noteCallKitEnd match an
    /// End that arrives before createCall returns.
    private var pendingOutgoingUUID: UUID?
    /// CallKit answer/end intents that arrived AFTER the hooks were
    /// wired but BEFORE the WS delivered the matching incoming_call —
    /// CallKitProvider only buffers while its hooks are nil, so this
    /// second retention layer covers the hooks-installed-but-idle
    /// window. Drained when the ring lands; the 40s ring timeout (and
    /// the call's own terminal events) bound their lifetime.
    private var pendingCallKitAnswers: Set<UUID> = []
    private var pendingCallKitEnds: Set<UUID> = []
    #endif

    public init(
        signaling: RestCallSignaling,
        callService: CallService = CallService(),
        displayNameResolver: @escaping (String) -> String = { $0 },
        localTurnURL: String? = nil,
        ringTimeout: TimeInterval = 40
    ) {
        self.signaling = signaling
        self.callService = callService
        self.resolveDisplayName = displayNameResolver
        self.localTurnURL = localTurnURL
        self.ringTimeout = ringTimeout
    }

    /// Invoked (best-effort) when a server REST action returns 401 — wired to
    /// the session refresher so an expired/restored token is renewed and the
    /// in-flight terminal action can retry with the fresh token. Optional;
    /// when nil, the durable retry still recovers once any other path
    /// (WS/catch-up 401) refreshes the token.
    public var onAuthFailure: (() async -> Void)?

    /// Subscribe to signaling events and arm platform hooks. Call once
    /// after the messaging stack is up.
    public func start() {
        wireCallServiceCallbacks()
        #if os(iOS)
        wireCallKit()
        // Cold launch: a lock-screen answer may have landed (and been
        // buffered) before this coordinator existed. Accept it now from the
        // push metadata so CallView presents immediately instead of the app
        // settling on the roster while it waits for the WS incoming_call.
        drainPendingAnsweredPush()
        #endif
        eventsTask?.cancel()
        eventsTask = Task { [weak self, signaling] in
            let stream = await signaling.events()
            for await event in stream {
                await self?.handle(event)
            }
        }
    }

    public func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        cleanupLocal()
    }

    /// Server-aware shutdown for sign-out / re-enrollment. Ends any
    /// in-progress call ON THE SERVER (so the peer isn't stranded and
    /// the call row doesn't glare-block the pair until the sweep)
    /// BEFORE local cleanup — the caller must await this while the
    /// session token is still valid (i.e. before deleting credentials).
    public func shutdown() async {
        eventsTask?.cancel()
        eventsTask = nil
        switch phase {
        case .outgoingRinging(let callId, _):
            await performTerminalAction(.cancel, callId: callId)
        case .incomingRinging(let callId, _, _):
            await performTerminalAction(.decline, callId: callId)
        case .active(let callId, _):
            await performTerminalAction(.end, callId: callId)
        case .idle:
            // Setup may be mid-flight with a server call already
            // allocated — abortRequested makes performOutgoing cancel it.
            abortRequested = true
        }
        cleanupLocal()
    }

    // MARK: - User intents

    /// Place a call. On iOS the dial routes through a `CXStartCallAction`
    /// so CallKit owns the audio session (required — `useManualAudio`
    /// means audio stays dead without CallKit's `didActivate`). macOS
    /// dials directly.
    public func startOutgoingCall(to userId: String, displayName: String, kind: String = "video") {
        guard case .idle = phase, !intentInFlight else { return }
        intentInFlight = true
        activeKind = kind
        let peer = Peer(userId: userId, displayName: displayName)
        #if os(iOS)
        pendingOutgoingPeer = peer
        // Capture the outgoing CallKit UUID so a CXEndCallAction arriving
        // DURING setup (before the server callId mapping exists) can be
        // matched and abort the dial — otherwise it would only land in
        // the incoming-only pending set and the callee would ring after
        // the user already ended the call locally.
        let outgoingUUID = UUID()
        pendingOutgoingUUID = outgoingUUID
        CallKitProvider.shared.reportOutgoing(
            uuid: outgoingUUID, remoteUserId: userId, remoteDisplayName: displayName,
            isVideo: kind == "video",
            onDenied: { [weak self] in
                // CallKit refused the transaction (DND policy, etc.) —
                // release the intent gate or the next dial is dead.
                Task { @MainActor in
                    self?.pendingOutgoingPeer = nil
                    self?.intentInFlight = false
                }
            }
        )
        // intentInFlight clears in performOutgoing (via callKitDidStart).
        #else
        Task { await performOutgoing(peer: peer, kind: kind, callKitUUID: nil) }
        #endif
    }

    public func acceptIncomingCall() {
        guard case .incomingRinging(let callId, let peer, let kind) = phase,
              !intentInFlight else { return }
        intentInFlight = true
        // Show the connecting call surface NOW — the CallKit ring UI is
        // already gone once the answer routes here. cleanupLocal() (every
        // teardown path) clears it.
        isAnswering = true
        #if os(iOS)
        // Answering on a LOCKED screen runs the whole accept handshake
        // (relay fetch, POST /accept, SDP answer + ICE over the WS — all
        // tunnelled through the in-process libbox proxy) while the app is
        // backgrounded. CallKit's runtime covers the audio path, NOT
        // arbitrary URLSession + loopback-proxy work, so iOS can suspend us
        // mid-handshake and the call dies right after answer. Hold a finite
        // background assertion until performAccept finishes.
        let bgTask = IncomingAcceptBackgroundTask(callId: callId)
        #endif
        Task {
            await performAccept(callId: callId, peer: peer, kind: kind)
            #if os(iOS)
            bgTask.end()
            #endif
        }
    }

    public func declineIncomingCall() {
        guard case .incomingRinging(let callId, _, _) = phase else { return }
        spawnTerminalAction(.decline, callId: callId)
        cleanupLocal()
    }

    public func hangUp() {
        switch phase {
        case .idle:
            if intentInFlight {
                // Outgoing setup is mid-flight; tell it to cancel the
                // server call as soon as (or right after) it allocates.
                abortRequested = true
            }
            return
        case .outgoingRinging(let callId, _):
            spawnTerminalAction(.cancel, callId: callId)
        case .incomingRinging(let callId, _, _):
            spawnTerminalAction(.decline, callId: callId)
        case .active(let callId, _):
            spawnTerminalAction(.end, callId: callId)
        }
        cleanupLocal()
    }

    enum TerminalVerb { case end, cancel, decline }

    /// Drive a server-side terminal action (end/cancel/decline): retry transient
    /// failures with capped backoff so the server row doesn't linger
    /// `connected`/`ringing` after the user hung up — a stale row glare/busy-
    /// blocks every follow-up call to that peer until the server's sweep. Stops
    /// on success or on a 4xx (the row is already terminal or in a state this
    /// verb can't change — retrying can't help).
    ///
    /// Durability scope: the retry runs in-memory for an extended window
    /// (`terminalMaxAttempts` × up to 30s ≈ 1h) and RESUMES after backgrounding
    /// (a suspended `Task.sleep` continues on foreground), so it covers the
    /// common "transport down for seconds-to-minutes" / "user backgrounded the
    /// app" cases. It is NOT durable across full app TERMINATION: a hang-up whose
    /// POST never lands before the process is killed falls back to the server's
    /// stale-call sweep (a `ringing` row times out to `missed` in ~33s; a
    /// `connected` row is swept once abandoned). A fully cross-restart-durable
    /// teardown (persisted intent queue or a server call lease/heartbeat) is a
    /// larger change tracked separately.
    func performTerminalAction(_ verb: TerminalVerb, callId: String) async {
        // ~1h of retrying while the app lives (mostly at the 30s cap); long
        // enough to outlast realistic transient outages, bounded so a truly
        // dead transport can't spin a zombie task forever.
        let maxAttempts = terminalMaxAttempts
        var delay: UInt64 = 500_000_000 // 0.5s, doubling, capped at 30s
        for attempt in 1...maxAttempts {
            do {
                switch verb {
                case .end: try await signaling.end(callId: callId)
                case .cancel: try await signaling.cancel(callId: callId)
                case .decline: try await signaling.decline(callId: callId)
                }
                return
            } catch APIClient.SendError.http(let code, _) where code == 401 {
                // Auth churn (expired/restored token mid-refresh) — NOT a
                // terminal call state. Trigger a refresh and retry with the
                // fresh token; treating this as "already terminal" would abandon
                // a still-live server row. Falls through to the backoff retry.
                NTLogger.calls.info("terminal \(String(describing: verb)) for \(callId): 401 — refreshing session and retrying")
                await onAuthFailure?()
                if attempt == maxAttempts { return }
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 30_000_000_000)
            } catch APIClient.SendError.http(let code, _) where (400..<500).contains(code) {
                // Already terminal / wrong-state / not-found (404/409/403) — the
                // server won't change state for this verb no matter how often we
                // retry. The call IS terminal, so drop its un-acked signals too;
                // otherwise a lost-ack offer/ICE replays on every reconnect
                // forever (the REST-success path clears them, but this 4xx path
                // skipped that).
                NTLogger.calls.info("terminal \(String(describing: verb)) for \(callId): server returned \(code) — treating as already terminal")
                await signaling.discardUnacked(callId: callId)
                return
            } catch {
                if attempt == maxAttempts {
                    NTLogger.calls.error("terminal \(String(describing: verb)) for \(callId) failed after \(maxAttempts) attempts: \(String(describing: error))")
                    return
                }
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 30_000_000_000)
            }
        }
    }

    /// Fire-and-forget durable teardown: spawn the retrying terminal action so
    /// local UI cleanup can proceed immediately while the server row is brought
    /// terminal in the background.
    func spawnTerminalAction(_ verb: TerminalVerb, callId: String) {
        Task { await self.performTerminalAction(verb, callId: callId) }
    }

    public func toggleMute() {
        isMuted = callService.toggleMute()
    }

    public func toggleVideo() {
        isVideoEnabled.toggle()
        callService.setVideoEnabled(isVideoEnabled)
    }

    // MARK: - Signaling events

    func handle(_ event: RestCallSignaling.Event) async {
        switch event {
        case .incoming(let callId, let from, let kind):
            // Ringing retransmits every 3 s; the same callId is not a
            // new call. A different call while non-idle stays unanswered
            // (busy) — the server's missed sweep will resolve it.
            //
            // `intentInFlight` is the OUTGOING-setup window: phase is still
            // .idle while we await permission / relay / create-call, but an
            // outgoing call is committed. Admitting an incoming call here
            // would let performOutgoing later overwrite the incoming phase,
            // orphaning its server call + CallKit ring. Treat in-flight
            // outgoing intent as busy too.
            guard case .idle = phase, !intentInFlight else { return }
            activeKind = kind
            let peer = Peer(userId: from, displayName: resolveDisplayName(from))
            #if os(iOS)
            // The CallKit UUID derives from the server call id (itself a
            // UUID string) — the SAME uuid PushKitHandler reports from
            // the push payload's call_uuid. One CallKit call, two entry
            // paths, no double ring.
            let uuid = Self.callKitUUID(for: callId)
            let provider = CallKitProvider.shared
            if provider.takePendingEnd(uuid: uuid) || pendingCallKitEnds.remove(uuid) != nil {
                // User declined from the lock screen while the app was
                // still connecting — answer the server, never ring twice.
                pendingCallKitAnswers.remove(uuid)
                spawnTerminalAction(.decline, callId: callId)
                dropBufferedSignals(callId: callId)
                return
            }
            callKitUUIDByCallId[callId] = uuid
            phase = .incomingRinging(callId: callId, peer: peer, kind: kind)
            armRingTimeout(callId: callId)
            if provider.takePendingAnswer(uuid: uuid) || pendingCallKitAnswers.remove(uuid) != nil {
                // User answered from the lock screen before we came up.
                acceptIncomingCall()
            } else {
                Task {
                    do {
                        try await provider.reportIncoming(
                            uuid: uuid, fromUserId: from, from: peer.displayName,
                            isVideo: kind == "video"
                        )
                    } catch {
                        // reportIncoming swallows the benign duplicate (push
                        // already owns the ring); anything that still throws
                        // means CallKit REFUSED the ring (DND/block/etc) — it
                        // will never appear. Decline server-side and drop local
                        // state so the call doesn't linger until the ring
                        // timeout (and the caller learns it was declined).
                        NTLogger.calls.error("reportIncoming rejected: \(String(describing: error)) — declining")
                        // Only tear down if THIS call is still the current
                        // ring. A late throw must not decline a stale call or,
                        // worse, cleanupLocal() a DIFFERENT call that became
                        // current in the meantime.
                        guard case .incomingRinging(let current, _, _) = phase,
                              current == callId else { return }
                        spawnTerminalAction(.decline, callId: callId)
                        cleanupLocal()
                    }
                }
            }
            #else
            phase = .incomingRinging(callId: callId, peer: peer, kind: kind)
            armRingTimeout(callId: callId)
            #endif

        case .signal(let callId, let payloadJSON):
            guard let payload = CallSignalPayload.from(json: payloadJSON) else {
                NTLogger.calls.error("undecodable call_signal payload (\(payloadJSON.count) bytes)")
                return
            }
            if callId == currentCallId {
                if mediaReady {
                    await callService.handleSignal(payload)
                } else {
                    appendBufferedSignal(callId: callId, payload: payload, bytes: payloadJSON.count)
                }
            } else if case .idle = phase {
                // Cold-launch race: the server's register-time replay
                // delivers the queued offer BEFORE the (retransmitted)
                // incoming_call lands. Hold it — the ring arrives within
                // one retransmit interval; dropping it here would strand
                // the call (the server already dequeued its copy).
                guard pendingSignals[callId] != nil
                    || pendingSignals.count < Self.maxBufferedSignalCalls
                else { return }
                appendBufferedSignal(callId: callId, payload: payload, bytes: payloadJSON.count)
            }

        case .stateChanged(let callId, let state, let stale, _):
            let isTerminal = state == "ended" || state == "declined"
                || state == "cancelled" || state == "missed"
            if isTerminal {
                // Drop buffered early signals for ANY call that just
                // died — not only the current one, or the cold-launch
                // buffer above would leak.
                dropBufferedSignals(callId: callId)
            }
            if stale, state == "connected", callId != currentCallId {
                // Reconnect replay of a `connected` call we have no
                // media session for (this process restarted mid-call —
                // its peer connection died with it). End it server-side
                // or the row glare-blocks the pair until the 4h stale
                // sweep; the peer (if any) gets the terminal event and
                // tears down too.
                spawnTerminalAction(.end, callId: callId)
                return
            }
            guard callId == currentCallId else {
                NTLogger.calls.debug("state_changed \(state) for non-current call \(callId) (current=\(self.currentCallId ?? "nil"), stale=\(stale)) — ignored")
                #if os(iOS)
                // A push-reported CallKit ring for a call that never became
                // current must still be torn down on its terminal replay.
                if isTerminal { reconcilePushedCallKitTermination(callId: callId) }
                #endif
                return
            }
            NTLogger.calls.debug("state_changed \(state) for current call \(callId) (stale=\(stale))")
            switch state {
            case "connected":
                if case .outgoingRinging(let id, let peer) = phase {
                    cancelRingTimeout()
                    phase = .active(callId: id, peer: peer)
                }
            case "ended", "declined", "cancelled", "missed":
                cleanupLocal()
            default:
                break
            }

        case .missed(let callId, _):
            dropBufferedSignals(callId: callId)
            if callId == currentCallId {
                cleanupLocal()
            } else {
                #if os(iOS)
                // Missed before the call ever became current (push rang CallKit,
                // then a missed replay arrived) — end the pushed system ring.
                reconcilePushedCallKitTermination(callId: callId)
                #endif
            }
        }
    }

    // MARK: - Flows

    private func performOutgoing(peer: Peer, kind: String, callKitUUID: UUID?) async {
        defer {
            intentInFlight = false
            abortRequested = false
        }
        let gen = callGeneration
        await Self.ensureMediaPermissions(kind: kind)
        guard gen == callGeneration, !abortRequested else { return }
        var allocatedCallId: String?
        do {
            let creds = try await signaling.relaySession()
            if abortRequested || gen != callGeneration { return }
            let callId = try await signaling.createCall(calleeUserId: peer.userId, kind: kind)
            allocatedCallId = callId
            if abortRequested || gen != callGeneration {
                // User hung up while the server call was being created
                // (phase was still idle so hangUp couldn't route it).
                spawnTerminalAction(.cancel, callId: callId)
                return
            }
            #if os(iOS)
            if let callKitUUID { callKitUUIDByCallId[callId] = callKitUUID }
            // callId mapping now exists — a further End routes through
            // currentCallId, so the pending-outgoing window is closed.
            pendingOutgoingUUID = nil
            #endif
            phase = .outgoingRinging(callId: callId, peer: peer)
            armRingTimeout(callId: callId)
            let sig = signaling
            try await callService.startOutgoing(
                kind: kind,
                iceServers: [iceServer(creds)],
                sendSignal: { payload in await sig.sendSignal(callId: callId, payload) }
            )
            guard gen == callGeneration else {
                // hangUp ran mid-setup (cleanupLocal bumped the
                // generation and already cancelled server-side) — don't
                // resurrect the phase; just drop the fresh media.
                callService.end()
                return
            }
            mediaReady = true
            await flushPendingSignals(callId)
        } catch let glare as APIClient.CallGlareError {
            // Simultaneous A→B / B→A: the server already holds a call between
            // this pair (createCall 409'd). Our round-14 busy-guard dropped
            // the incoming_call event, so without this both sides ring until
            // timeout. Pivot to RINGING the existing call ONLY when it's a
            // RINGING call the PEER placed to us (so we're the callee). For a
            // CONNECTED call — or our OWN existing call — synthesizing an
            // incoming ring would route through accept→end and could tear
            // down a live call, so just abandon this dial.
            let peerIsCaller = glare.existingCallerUserId == peer.userId
            guard gen == callGeneration else { return }
            if glare.existingCallState == "ringing", peerIsCaller {
                NTLogger.calls.info("call glare — pivoting to incoming \(glare.existingCallId)")
                intentInFlight = false       // clear so the incoming guard admits the pivot
                // Preserve any offer/ICE already buffered for the call we're
                // pivoting to — cleanupLocal would otherwise discard the only
                // server-accepted offer and the pivoted call would stall.
                cleanupLocal(preservingSignalsFor: glare.existingCallId)
                await handle(.incoming(
                    callId: glare.existingCallId,
                    fromUserId: glare.existingCallerUserId,
                    kind: glare.existingCallKind
                ))
            } else {
                NTLogger.calls.info("call glare (state=\(glare.existingCallState), peerIsCaller=\(peerIsCaller)) — abandoning dial, not pivoting")
                cleanupLocal()
            }
        } catch is APIClient.CallBusyError {
            // The dialed peer is already on a call with someone else. This is
            // terminal — we are NOT a participant in their call, so there is
            // nothing to pivot to. Abandon the dial cleanly.
            NTLogger.calls.info("call busy — dialed peer is on another call; abandoning dial")
            if gen == callGeneration { cleanupLocal() }
        } catch {
            NTLogger.calls.error("outgoing call failed: \(String(describing: error))")
            if let allocatedCallId {
                // The server call exists — cancel it or the callee keeps
                // ringing and glare blocks this pair until the sweep.
                spawnTerminalAction(.cancel, callId: allocatedCallId)
            }
            if gen == callGeneration { cleanupLocal() }
        }
    }

    private func performAccept(callId: String, peer: Peer, kind: String) async {
        defer { intentInFlight = false }
        let gen = callGeneration
        // Tracks whether /accept has connected the call server-side. Before
        // that the row is still `ringing`, where /end is rejected — so a
        // failure in the pre-accept window must transition it terminal with
        // /decline, not /end, or the caller rings until the missed sweep and
        // the active row glare-blocks follow-up calls.
        var accepted = false
        await Self.ensureMediaPermissions(kind: kind)
        guard gen == callGeneration else { return }
        do {
            let creds = try await signaling.relaySession()
            guard gen == callGeneration else { return }
            try await signaling.accept(callId: callId)
            accepted = true
            guard gen == callGeneration else {
                // User hung up while the accept was in flight and the
                // server already connected the call — end it instead of
                // resurrecting a phase the user just left.
                spawnTerminalAction(.end, callId: callId)
                return
            }
            let sig = signaling
            try await callService.startIncoming(
                kind: kind,
                iceServers: [iceServer(creds)],
                sendSignal: { payload in await sig.sendSignal(callId: callId, payload) }
            )
            guard gen == callGeneration else {
                callService.end()
                spawnTerminalAction(.end, callId: callId)
                return
            }
            mediaReady = true
            cancelRingTimeout()
            phase = .active(callId: callId, peer: peer)
            await flushPendingSignals(callId)
        } catch {
            NTLogger.calls.error("accept failed: \(String(describing: error))")
            // Transition the server row terminal with the right verb: /end only
            // applies once /accept connected it; before that the row is ringing
            // and must be /decline'd (which the callee is authorized to do).
            spawnTerminalAction(accepted ? .end : .decline, callId: callId)
            if gen == callGeneration { cleanupLocal() }
        }
    }

    private func flushPendingSignals(_ callId: String) async {
        let buffered = pendingSignals.removeValue(forKey: callId) ?? []
        pendingSignalBytes.removeValue(forKey: callId)
        for payload in buffered {
            await callService.handleSignal(payload)
        }
    }

    /// Bounded local ringing window. Server terminal events are
    /// best-effort; if neither `connected` nor a terminal state arrives
    /// within the window, tear down locally (and tell the server, in
    /// case it still thinks we're ringing).
    private func armRingTimeout(callId: String) {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = Task { [weak self, ringTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(ringTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.currentCallId == callId else { return }
            switch self.phase {
            case .outgoingRinging, .incomingRinging:
                NTLogger.calls.info("ring timeout for \(callId) — local teardown")
                self.hangUp()
            default:
                break
            }
        }
    }

    private func cancelRingTimeout() {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil
    }

    /// Tear down local call state back to `.idle`. `preservingSignalsFor`
    /// keeps the buffered early signals for ONE call id across the wipe — used
    /// by the glare pivot, where an offer for the peer's existing call may have
    /// already been buffered while our outgoing attempt was still idle.
    /// Dropping it would leave the pivoted-to call with media but no offer to
    /// answer, stalling the call.
    /// Test introspection: how many early signals are buffered for a call id.
    func _bufferedSignalCount(forCallId callId: String) -> Int {
        pendingSignals[callId]?.count ?? 0
    }

    /// Buffer an early signal under the per-call count + byte caps. Returns
    /// false (and drops the signal) when either cap would be exceeded, so a
    /// caller flooding a ringing callee can't grow this unbounded.
    @discardableResult
    private func appendBufferedSignal(callId: String, payload: CallSignalPayload, bytes: Int) -> Bool {
        let count = pendingSignals[callId]?.count ?? 0
        let used = pendingSignalBytes[callId] ?? 0
        guard count < Self.maxBufferedSignalsPerCall,
              used + bytes <= Self.maxBufferedSignalBytesPerCall
        else {
            NTLogger.calls.error("dropping buffered call_signal for \(callId) — per-call buffer cap reached (count \(count), bytes \(used))")
            return false
        }
        pendingSignals[callId, default: []].append(payload)
        pendingSignalBytes[callId, default: 0] += bytes
        return true
    }

    /// Drop all buffered signals for one call, keeping the byte tally in sync.
    private func dropBufferedSignals(callId: String) {
        pendingSignals.removeValue(forKey: callId)
        pendingSignalBytes.removeValue(forKey: callId)
    }

    private func cleanupLocal(preservingSignalsFor preserve: String? = nil) {
        callGeneration &+= 1
        cancelRingTimeout()
        iceDisconnectTask?.cancel()
        iceDisconnectTask = nil
        #if os(iOS)
        if let callId = currentCallId, let uuid = callKitUUIDByCallId.removeValue(forKey: callId) {
            CallKitProvider.shared.reportEnded(uuid: uuid)
        }
        pendingOutgoingPeer = nil
        pendingOutgoingUUID = nil
        #endif
        callService.end()
        remoteVideoTrack = nil
        isAnswering = false
        isReconnecting = false
        isMuted = false
        isVideoEnabled = true
        mediaReady = false
        if let preserve, let kept = pendingSignals[preserve] {
            pendingSignals = [preserve: kept]
            pendingSignalBytes = [preserve: pendingSignalBytes[preserve] ?? 0]
        } else {
            pendingSignals.removeAll()
            pendingSignalBytes.removeAll()
        }
        phase = .idle
    }

    // MARK: - Wiring

    /// Prompt for mic (and camera, for video calls) before the peer
    /// connection comes up — a permission dialog mid-ring is bad UX and
    /// a denied prompt mid-ICE looks like a dead call. Denial degrades
    /// gracefully: WebRTC sends silence / no frames.
    private static func ensureMediaPermissions(kind: String) async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        if kind == "video" {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
    }

    /// The TURN URL(s) WebRTC should dial. Prefer the libbox-local tunnel
    /// (coturn is only reachable through REALITY); fall back to the server's
    /// `urls` only when no local tunnel exists (DEBUG / tests). The HMAC
    /// username/credential always come from the relay session.
    nonisolated static func turnURLStrings(
        creds: APIClient.RelayCredentials, localTurnURL: String?
    ) -> [String] {
        if let localTurnURL, !localTurnURL.isEmpty { return [localTurnURL] }
        return creds.urls
    }

    private func iceServer(_ creds: APIClient.RelayCredentials) -> RTCIceServer {
        RTCIceServer(
            urlStrings: Self.turnURLStrings(creds: creds, localTurnURL: localTurnURL),
            username: creds.username,
            credential: creds.password
        )
    }

    private func wireCallServiceCallbacks() {
        callService.onRemoteVideoTrack = { [weak self] track in
            Task { @MainActor in self?.remoteVideoTrack = track }
        }
        callService.onIceConnectionState = { [weak self] state in
            NTLogger.calls.info("ice state → \(state.rawValue)")
            Task { @MainActor in self?.handleIceState(state) }
        }
    }

    /// React to WebRTC ICE transitions. `.failed` is terminal (tear down
    /// now). `.disconnected` arms a short grace: if media doesn't recover we
    /// tear down too — this is what closes the call on THIS side when the
    /// PEER force-quits / crashes (it can't send a /end, and ICE `.failed`
    /// behind a relay is far too slow). `.connected`/`.completed` cancels the
    /// pending grace.
    func handleIceState(_ state: RTCIceConnectionState) {
        // Ignore ICE noise outside a LIVE media session: stale callbacks from
        // a just-closed peer connection, or transitions at idle/ring. Without
        // this a leftover `.failed` could hang up a freshly-started call, or a
        // `.disconnected` at idle could strand `isReconnecting`.
        guard mediaReady, let callId = currentCallId else {
            iceDisconnectTask?.cancel()
            iceDisconnectTask = nil
            isReconnecting = false
            return
        }
        // Pin the generation so the async grace can't tear down a DIFFERENT
        // call that started after this transition.
        let generation = callGeneration
        switch state {
        case .failed:
            iceDisconnectTask?.cancel()
            iceDisconnectTask = nil
            isReconnecting = false
            hangUp()
        case .disconnected:
            guard iceDisconnectTask == nil else { return }
            // Surface "Reconnecting…" rather than a frozen "Connected", and
            // give the media a window to recover before dropping.
            isReconnecting = true
            iceDisconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.iceDisconnectGrace * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.iceDisconnectTask = nil
                // Same call generation AND still current → media never came
                // back (peer force-quit / crash / network loss): tear down.
                guard self.callGeneration == generation, self.currentCallId == callId else { return }
                NTLogger.calls.info("ICE stayed disconnected past grace — ending call \(callId)")
                self.hangUp()
            }
        case .connected, .completed:
            iceDisconnectTask?.cancel()
            iceDisconnectTask = nil
            // Media came back — drop the "Reconnecting…" banner and continue.
            isReconnecting = false
        default:
            break
        }
    }

    #if os(iOS)
    /// Server call ids are UUID strings — derive the CallKit UUID from
    /// the id so the VoIP-push path (which reports with the payload's
    /// `call_uuid` == call id) and this WS path converge on one CallKit
    /// call. Fallback UUID() only fires if the server ever changes its
    /// id format.
    static func callKitUUID(for callId: String) -> UUID {
        UUID(uuidString: callId) ?? UUID()
    }

    /// Cold-launch reconciliation for a call that terminates WITHOUT ever
    /// becoming the current app-level call. PushKit reports a CallKit ring from
    /// the VoIP `call_uuid` (== server call id) before the socket is up; if the
    /// caller cancels or the server marks it missed before WS registration, the
    /// register-time replay delivers ONLY a terminal `call_state_changed` (no
    /// `incoming_call`), so the normal incoming/terminal paths never run. End
    /// that pushed system ring and drain its buffered answer/end intents, or the
    /// lock screen keeps ringing a dead call. The derived UUID matches what
    /// PushKitHandler reported (same `UUID(uuidString: callId)`).
    private func reconcilePushedCallKitTermination(callId: String) {
        let uuid = callKitUUIDByCallId[callId] ?? Self.callKitUUID(for: callId)
        let provider = CallKitProvider.shared
        _ = provider.takePendingAnswer(uuid: uuid)
        _ = provider.takePendingEnd(uuid: uuid)
        pendingCallKitAnswers.remove(uuid)
        pendingCallKitEnds.remove(uuid)
        callKitUUIDByCallId.removeValue(forKey: callId)
        provider.reportEnded(uuid: uuid)
    }

    private func wireCallKit() {
        let provider = CallKitProvider.shared
        provider.onStart = { [weak self] uuid, userId, name in
            await self?.callKitDidStart(uuid: uuid, userId: userId, name: name)
        }
        provider.onAnswer = { [weak self] uuid in
            await MainActor.run { self?.noteCallKitAnswer(uuid: uuid) }
        }
        provider.onEnd = { [weak self] uuid in
            await MainActor.run { self?.noteCallKitEnd(uuid: uuid) }
        }
    }

    /// CallKit answer. If the matching call is current — accept now.
    /// If the WS hasn't delivered the incoming_call yet (cold launch:
    /// the push rings CallKit before the socket is up), retain the
    /// intent; `handle(.incoming)` drains it. The CXAction itself is
    /// fulfilled promptly by CallKitProvider — deferring fulfill until
    /// the server round-trip would trip CallKit's action deadline and
    /// kill the call system-side.
    func noteCallKitAnswer(uuid: UUID) {
        if case .incomingRinging(let callId, _, _) = phase,
           callKitUUIDByCallId[callId] == uuid {
            acceptIncomingCall()
            return
        }
        // Answer landed before the WS delivered incoming_call. If the VoIP
        // push left metadata, synthesize the call and accept NOW rather than
        // waiting (and risking the server ring window closing → "missed",
        // leaving the user on the roster).
        if let meta = CallKitProvider.shared.incomingMeta(for: uuid),
           acceptPushedIncoming(meta) {
            return
        }
        pendingCallKitAnswers.insert(uuid)
    }

    /// Turn a VoIP-pushed incoming call into a real in-app call from its push
    /// metadata — used when a lock-screen answer arrives before the WS
    /// `incoming_call`. Returns false (no-op) unless we're idle and the
    /// metadata carries a routable peer.
    @discardableResult
    private func acceptPushedIncoming(_ meta: IncomingCallMeta) -> Bool {
        guard case .idle = phase, !intentInFlight, !meta.fromUserId.isEmpty else { return false }
        let uuid = Self.callKitUUID(for: meta.callId)
        activeKind = meta.kind
        let peer = Peer(userId: meta.fromUserId, displayName: resolveDisplayName(meta.fromUserId))
        callKitUUIDByCallId[meta.callId] = uuid
        phase = .incomingRinging(callId: meta.callId, peer: peer, kind: meta.kind)
        armRingTimeout(callId: meta.callId)
        acceptIncomingCall()
        return true
    }

    /// Drain a lock-screen answer that was buffered (with push metadata)
    /// before this coordinator existed — cold-launch present-CallView path.
    private func drainPendingAnsweredPush() {
        guard let meta = CallKitProvider.shared.takePendingAnsweredMeta() else { return }
        acceptPushedIncoming(meta)
    }

    /// CallKit end/decline — same retention rule as answers.
    func noteCallKitEnd(uuid: UUID) {
        if let callId = currentCallId, callKitUUIDByCallId[callId] == uuid {
            hangUpFromCallKit()
            return
        }
        // Outgoing call ended DURING setup, before its server callId
        // mapping exists. Abort the in-flight dial: bump the generation
        // (so a resumed performOutgoing bails) and set abortRequested
        // (so it cancels any server call it already created).
        if uuid == pendingOutgoingUUID {
            abortRequested = true
            callGeneration &+= 1
            pendingOutgoingPeer = nil
            pendingOutgoingUUID = nil
            return
        }
        pendingCallKitEnds.insert(uuid)
        pendingCallKitAnswers.remove(uuid)
    }

    private func callKitDidStart(uuid: UUID, userId: String, name: String?) async {
        // End may have arrived between reportOutgoing and this callback.
        if abortRequested {
            abortRequested = false
            intentInFlight = false
            pendingOutgoingPeer = nil
            pendingOutgoingUUID = nil
            CallKitProvider.shared.reportEnded(uuid: uuid)
            return
        }
        let peer = pendingOutgoingPeer ?? Peer(
            userId: userId, displayName: name ?? resolveDisplayName(userId)
        )
        pendingOutgoingPeer = nil
        await performOutgoing(peer: peer, kind: activeKind, callKitUUID: uuid)
    }

    /// CallKit-initiated end (lock-screen hangup, providerDidReset).
    /// Same as hangUp but skips reportEnded — CallKit already knows.
    private func hangUpFromCallKit() {
        callGeneration &+= 1
        switch phase {
        case .idle:
            return
        case .outgoingRinging(let callId, _):
            spawnTerminalAction(.cancel, callId: callId)
        case .incomingRinging(let callId, _, _):
            spawnTerminalAction(.decline, callId: callId)
        case .active(let callId, _):
            spawnTerminalAction(.end, callId: callId)
        }
        if let callId = currentCallId {
            callKitUUIDByCallId.removeValue(forKey: callId)
        }
        callService.end()
        iceDisconnectTask?.cancel()
        iceDisconnectTask = nil
        remoteVideoTrack = nil
        isAnswering = false
        isReconnecting = false
        isMuted = false
        isVideoEnabled = true
        mediaReady = false
        pendingSignals.removeAll()
        pendingSignalBytes.removeAll()
        phase = .idle
    }
    #endif
}

#if os(iOS)
/// Finite background-execution assertion held while an incoming call's
/// accept handshake runs. Without it, answering on a locked screen
/// (app backgrounded) lets iOS suspend the process mid-handshake — the
/// relay fetch / POST /accept / SDP answer all tunnel through the
/// in-process libbox proxy, which CallKit's audio runtime does NOT keep
/// alive — and the call dies right after answer. Auto-ends on expiry so we
/// never leak the assertion.
@MainActor
private final class IncomingAcceptBackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(callId: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: "NestTalk.acceptIncomingCall") { [weak self] in
            NTLogger.calls.error("incoming-accept background task expired for \(callId)")
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
