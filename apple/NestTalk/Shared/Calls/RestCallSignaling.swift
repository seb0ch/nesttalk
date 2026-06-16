import Foundation

/// REST + WS signaling surface for 1:1 calls. Owns the call lifecycle:
///
///   * `createCall(calleeUserId:kind:)` → `POST /api/v1/calls` (server
///     creates a ringing call and broadcasts `incoming_call` to the
///     callee over the control WS).
///   * `.accept` / `.decline` / `.cancel` / `.end` map 1:1 to
///     `POST /api/v1/calls/{id}/{action}`.
///   * `sendSignal(callId:_:)` ships WebRTC offer/answer/ICE payloads
///     to the peer as `call_signal` WS frames (relayed verbatim by
///     `calls.Manager.RelaySignal` server-side).
///   * Inbound WS events `.incomingCall`, `.callSignal`,
///     `.callStateChanged`, `.callMissed` are surfaced via an
///     `AsyncStream<RestCallSignaling.Event>` for `CallCoordinator`.
public actor RestCallSignaling {

    public enum Event: Equatable, Sendable {
        case incoming(callId: String, fromUserId: String, kind: String)
        case stateChanged(callId: String, state: String, stale: Bool, endedReason: String?)
        case missed(callId: String, fromUserId: String)
        case signal(callId: String, payloadJSON: Data)
    }

    private let api: APIClient
    private let sessionToken: @Sendable () -> String?
    /// Outbound WS frame shipper — `ControlWebSocket.send` in production,
    /// a recorder in tests. Returns delivery success; failed call-signal
    /// frames queue in `pendingOut` for `flushPendingSignals`. Optional
    /// so REST-only tests don't need a socket.
    private let sendFrame: (@Sendable (ControlOutbound) async -> Bool)?
    private var continuation: AsyncStream<Event>.Continuation?
    /// Events ingested BEFORE a subscriber attached. `CallCoordinator.start`
    /// installs its `events()` subscription from a spawned task, so the WS
    /// pump can deliver an incoming offer in the gap between start()
    /// returning and the subscription registering — yielding to a nil
    /// continuation would drop it. Buffer here and drain on subscribe.
    /// Bounded so a never-attached subscriber can't grow it without limit.
    private var pendingEvents: [Event] = []
    private static let maxBufferedEvents = 64
    public private(set) var activeCallId: String?

    /// One outbound WebRTC signal awaiting the server's `call_signal_ack`.
    private struct OutSignal {
        let signalId: String
        let callId: String
        let payload: CallSignalPayload
        /// True once shipped on the CURRENT connection. A reconnect resets
        /// this to false so the signal replays.
        var sent: Bool
        /// When this signal was last shipped. The ack-watchdog resets `sent`
        /// to false once this is older than `ackTimeout` with no ack, so a
        /// signal the server deliberately did NOT ack (peer backpressure /
        /// full replay queue) is re-sent instead of stranded until a reconnect.
        var sentAt: Date?
    }
    /// Signals not yet acknowledged by the server. Retained — and replayed
    /// on reconnect — until the matching `call_signal_ack` arrives or the
    /// call terminates. This closes the client→server loss window: the
    /// local WebSocket `send` completing does NOT prove server receipt, so
    /// a disconnect between the two would otherwise silently drop an
    /// offer/answer/ICE. The server dedups by `signal_id`, so a replay the
    /// peer already got is a harmless no-op.
    private var unacked: [OutSignal] = []
    /// Single-flight guard for the send pump — actor re-entrancy during a
    /// send's await would otherwise let a fresh signal overtake older
    /// queued ones (ICE racing ahead of the offer).
    private var pumping = false

    /// How long a shipped-but-unacked signal waits for `call_signal_ack`
    /// before the watchdog re-sends it. The server withholds the ack when it
    /// can't deliver/queue the frame (peer backpressure, full replay queue),
    /// expecting a retry; this is that retry's deadline. Injectable so tests
    /// don't wait seconds.
    private let ackTimeout: TimeInterval

    public init(
        api: APIClient,
        sessionToken: @escaping @Sendable () -> String?,
        sendFrame: (@Sendable (ControlOutbound) async -> Bool)? = nil,
        ackTimeout: TimeInterval = 3.0
    ) {
        self.api = api
        self.sessionToken = sessionToken
        self.sendFrame = sendFrame
        self.ackTimeout = ackTimeout
    }

    public func events() -> AsyncStream<Event> {
        // Single-subscriber: a second call finishes the prior stream
        // before handing back a new one so we never overwrite a live
        // continuation and silently leak its consumer.
        continuation?.finish()
        let (stream, c) = AsyncStream<Event>.makeStream()
        self.continuation = c
        // Drain anything that arrived before this subscriber attached.
        for e in pendingEvents { c.yield(e) }
        pendingEvents.removeAll()
        return stream
    }

    /// Yield to the live subscriber, or buffer until one attaches.
    private func emit(_ event: Event) {
        if let continuation {
            continuation.yield(event)
        } else {
            if pendingEvents.count >= Self.maxBufferedEvents {
                pendingEvents.removeFirst()
            }
            pendingEvents.append(event)
        }
    }

    /// Pump WS events into the signaling stream. Call from the
    /// CallCoordinator bootstrap with the ControlWebSocket.events()
    /// iterator.
    public func ingest(_ event: ControlEvent) {
        switch event {
        case .incomingCall(let callId, let from, let kind, _):
            activeCallId = callId
            emit(.incoming(callId: callId, fromUserId: from, kind: kind))
        case .callStateChanged(let callId, let state, let stale, let endedReason, _):
            emit(.stateChanged(callId: callId, state: state, stale: stale, endedReason: endedReason))
            if state == "ended" || state == "missed" || state == "declined" || state == "cancelled" {
                if activeCallId == callId { activeCallId = nil }
                // A terminal call's un-acked signals must never replay
                // into a future call.
                unacked.removeAll { $0.callId == callId }
            }
        case .callSignal(let callId, let payload, _):
            emit(.signal(callId: callId, payloadJSON: payload))
        case .callSignalAck(let signalId, _):
            // The server accepted (relayed or queued) this signal — stop
            // retaining/replaying it.
            unacked.removeAll { $0.signalId == signalId }
        case .callMissed(let callId, let from, _):
            if activeCallId == callId { activeCallId = nil }
            // A missed call is terminal — drop its un-acked signals so they
            // can't replay forever on later reconnects.
            unacked.removeAll { $0.callId == callId }
            emit(.missed(callId: callId, fromUserId: from))
        default:
            break
        }
    }

    // MARK: - Outbound

    /// `POST /api/v1/calls` — opens the ringing call shell. SDP never
    /// travels over REST; the offer follows via `sendSignal`.
    public func createCall(calleeUserId: String, kind: String) async throws -> String {
        let resp = try await api.createCall(
            calleeUserId: calleeUserId, kind: kind, sessionToken: sessionToken()
        )
        activeCallId = resp.call_id
        return resp.call_id
    }

    /// Ship a WebRTC offer/answer/ICE payload to the call's peer over the
    /// control WS. The signal is retained in `unacked` (with a fresh
    /// `signal_id`) until the server acks it; a failed send or a
    /// disconnect-before-ack is recovered by `flushPendingSignals` on
    /// reconnect. Ordering within a call is preserved by the single-flight
    /// pump.
    public func sendSignal(callId: String, _ payload: CallSignalPayload) async {
        guard sendFrame != nil else { return }
        unacked.append(OutSignal(
            signalId: UUID().uuidString, callId: callId, payload: payload, sent: false
        ))
        await pump()
    }

    /// Single-flight sender: ship every not-yet-sent `unacked` signal in
    /// strict order. Re-entrancy during a send's await is a no-op (the
    /// running pump picks up freshly-appended signals), so a fresh ICE
    /// can't overtake an offer still mid-send.
    private func pump() async {
        guard let sendFrame, !pumping else { return }
        pumping = true
        defer { pumping = false }
        while let idx = unacked.firstIndex(where: { !$0.sent }) {
            // Value copy — stable across the await even if the list mutates
            // (an ack/terminal removing entries, or a fresh sendSignal append).
            let item = unacked[idx]
            let ok = await sendFrame(.callSignal(callId: item.callId, payload: item.payload, signalId: item.signalId))
            // Re-find by signal id: the index may have shifted during the await.
            guard let i = unacked.firstIndex(where: { $0.signalId == item.signalId }) else {
                continue // acked / terminal-removed mid-send — nothing to mark
            }
            if ok {
                unacked[i].sent = true
                unacked[i].sentAt = Date()
            } else {
                // Send FAILED. Leave sent=false so this signal is retried —
                // marking it sent (the old bug) would strand it forever: future
                // pumps skip sent items and no ack can ever remove it, hanging
                // the call's offer/answer/ICE/teardown. Stop the pump (a down
                // socket would otherwise hot-loop) and schedule a backoff
                // re-pump so it recovers even without a reconnect event.
                scheduleRetryPump()
                return
            }
        }
        // Anything shipped but not yet acked needs an ack deadline: the server
        // withholds call_signal_ack when it can't deliver/queue (peer
        // backpressure, full replay queue), so without this a sent-but-unacked
        // signal would sit forever on a live connection until an unrelated
        // reconnect. The watchdog re-sends past the deadline (idempotent — the
        // server dedups by signal_id).
        scheduleAckWatchdog()
    }

    private var retryPumpScheduled = false

    /// Schedule a single delayed re-pump after a send failure. Coalesced so a
    /// burst of failures arms only one timer; self-terminates once the queue
    /// drains (ack/terminal) or a send finally succeeds.
    private func scheduleRetryPump() {
        guard !retryPumpScheduled else { return }
        retryPumpScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            await self?.runRetryPump()
        }
    }

    private func runRetryPump() async {
        retryPumpScheduled = false
        await pump()
    }

    private var ackWatchdogScheduled = false

    /// Arm a single delayed ack check. Coalesced so repeated sends arm only
    /// one timer; re-arms itself while signals remain unacked, and stops once
    /// `unacked` drains (every signal acked, or the call went terminal).
    private func scheduleAckWatchdog() {
        guard !ackWatchdogScheduled, !unacked.isEmpty else { return }
        ackWatchdogScheduled = true
        let delay = ackTimeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            await self?.runAckWatchdog()
        }
    }

    /// Re-send any signal whose ack never arrived within `ackTimeout`. The
    /// server dedups by signal_id, so a re-send the peer already received is a
    /// harmless no-op; this only closes the withheld-ack (backpressure) gap.
    private func runAckWatchdog() async {
        ackWatchdogScheduled = false
        let now = Date()
        var resetAny = false
        for i in unacked.indices where unacked[i].sent {
            if let at = unacked[i].sentAt, now.timeIntervalSince(at) >= ackTimeout {
                unacked[i].sent = false
                unacked[i].sentAt = nil
                resetAny = true
            }
        }
        if resetAny {
            await pump() // re-pump re-arms the watchdog at the end
        } else {
            // Signals still in flight but not yet past their deadline — check
            // again so a withheld ack is eventually retried.
            scheduleAckWatchdog()
        }
    }

    /// Replay un-acked signals after the WS reconnects. The prior
    /// connection dropped, so EVERY un-acked signal must be re-sent (the
    /// server dedups by `signal_id`, so already-relayed ones are no-ops).
    public func flushPendingSignals() async {
        for i in unacked.indices { unacked[i].sent = false }
        await pump()
    }

    /// Test introspection.
    func _pendingOutCount() -> Int { unacked.count }
    func _isFlushing() -> Bool { pumping }

    public func accept(callId: String) async throws {
        _ = try await api.acceptCall(callId, sessionToken: sessionToken())
    }
    public func decline(callId: String) async throws {
        _ = try await api.declineCall(callId, sessionToken: sessionToken())
        clearTerminated(callId)
    }
    public func cancel(callId: String) async throws {
        _ = try await api.cancelCall(callId, sessionToken: sessionToken())
        clearTerminated(callId)
    }
    public func end(callId: String) async throws {
        _ = try await api.endCall(callId, sessionToken: sessionToken())
        clearTerminated(callId)
    }

    /// Drop a locally-terminated call's state. Runs ONLY after the REST
    /// terminal action succeeds (a failed action throws before this), so we
    /// never abandon replayable signals while the server still believes the
    /// call is live. Mirrors the inbound terminal `call_state_changed` purge:
    /// the initiator must not rely on receiving its own terminal event — if an
    /// ack was lost, a stale offer/ICE left in `unacked` would otherwise replay
    /// on every reconnect.
    private func clearTerminated(_ callId: String) {
        if activeCallId == callId { activeCallId = nil }
        unacked.removeAll { $0.callId == callId }
    }

    /// Drop a call's un-acked signals when the call is known terminal but the
    /// REST terminal action itself failed non-recoverably (a 4xx wrong-state /
    /// not-found, e.g. hang-up racing the server's missed/timeout transition).
    /// Without this, an un-acked offer/ICE replays on every reconnect forever —
    /// the server rejects it without acking, so it's never cleared.
    public func discardUnacked(callId: String) {
        unacked.removeAll { $0.callId == callId }
    }

    public func relaySession() async throws -> APIClient.RelayCredentials {
        try await api.relaySession(sessionToken: sessionToken())
    }
}
