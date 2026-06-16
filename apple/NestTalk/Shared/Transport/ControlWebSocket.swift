import Foundation

/// Decoded events lifted off the v0.2.3 `/api/v1/ws/control` socket.
/// Each case mirrors a server-side `ws.Event.Type` literal — see
/// `server/internal/ws/events.go` for canonical shapes.
public enum ControlEvent: Equatable, Sendable {
    case messageIncoming(id: String, from: String, to: String, envelopeBase64: String, sentAt: Int64, receivedAt: Int64, replyToId: String?)
    case messageDelivered(messageId: String)
    case messageRead(messageId: String)
    case reactionUpdate(messageId: String, reactionId: String, senderUserId: String, envelopeBase64: String, sentAt: Int64, receivedAt: Int64)
    case typingStart(from: String, to: String, atMillis: Int64)
    case typingStop(from: String, to: String, atMillis: Int64)
    case incomingCall(callId: String, fromUserId: String, kind: String, atMillis: Int64)
    case callSignal(callId: String, payloadJSON: Data, atMillis: Int64)
    case callSignalAck(signalId: String, atMillis: Int64)
    case callStateChanged(callId: String, state: String, stale: Bool, endedReason: String?, atMillis: Int64)
    case callMissed(callId: String, fromUserId: String, atMillis: Int64)
    case presenceChanged(userId: String, online: Bool, atMillis: Int64)
    case serverRestored(generation: Int64, jwtKid: String, atMillis: Int64)
    case unknown(type: String)
}

public enum ControlWebSocketStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(after: TimeInterval)
}

/// Outbound control-frame shapes — typing plus the WebRTC signaling
/// relay. `call_signal` payloads are forwarded verbatim to the call's
/// peer by the server (`calls.Manager.RelaySignal`).
public enum ControlOutbound: Encodable, Sendable {
    case typingStart(to: String)
    case typingStop(to: String)
    case callSignal(callId: String, payload: CallSignalPayload, signalId: String)

    enum CodingKeys: String, CodingKey {
        case type, to
        case callId = "call_id"
        case signalId = "signal_id"
        case payload
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .typingStart(let to):
            try c.encode("typing_start", forKey: .type)
            try c.encode(to, forKey: .to)
        case .typingStop(let to):
            try c.encode("typing_stop", forKey: .type)
            try c.encode(to, forKey: .to)
        case .callSignal(let callId, let payload, let signalId):
            try c.encode("call_signal", forKey: .type)
            try c.encode(callId, forKey: .callId)
            try c.encode(signalId, forKey: .signalId)
            try c.encode(payload, forKey: .payload)
        }
    }
}

/// Actor-isolated `URLSessionWebSocketTask` client for
/// `/api/v1/ws/control`. State (task, stopped flag, reconnect counter,
/// continuations) is serialized through the actor; tests and SwiftUI
/// view-models access it via `await`.
///
/// **Auth.** Token is passed via `URLSession.webSocketTask(with:protocols:)`
/// — URLSession owns subprotocol negotiation and refuses to honor a
/// manually-set `Sec-WebSocket-Protocol` header. The v0.2.3 server's
/// `bearerToken()` helper reads the first subprotocol value and echoes
/// it back via `AcceptOptions.Subprotocols`.
///
/// **Stream lifecycle.** `events()` and `status()` are single-subscriber.
/// Calling them more than once finishes the previous stream so the
/// new caller becomes the sole subscriber — the alternative (silent
/// continuation overwrite) would leak the prior consumer.
public actor ControlWebSocket {

    private let baseURL: URL
    private let session: URLSession
    /// Read the bearer fresh on every (re)connect. SessionRefresher
    /// rotates the token underneath us; pinning the value at init
    /// time would leave us looping with a stale token → server-side
    /// 401 → -1011 handshake failure forever.
    private let tokenProvider: @Sendable () -> String?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var continuation: AsyncStream<ControlEvent>.Continuation?
    private var statusContinuation: AsyncStream<ControlWebSocketStatus>.Continuation?
    private var stopped = false
    private var reconnectAttempts = 0

    public init(
        baseURL: URL,
        tokenProvider: @escaping @Sendable () -> String?,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

    /// Convenience for callers (and tests) that have a static token
    /// in hand. Wraps it in a closure so the rest of the actor sees
    /// only the provider-shaped path.
    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokenProvider = { token }
        self.session = session
    }

    /// AsyncStream of decoded events. Single-subscriber — a second call
    /// finishes the prior stream before handing back a new one so the
    /// caller's ownership is always exclusive.
    ///
    /// Implementation note: `AsyncStream`'s build closure runs
    /// synchronously on the caller's executor, not the actor. We use
    /// `AsyncStream.makeStream()` so the continuation is captured
    /// inside the actor-isolated context and assigned to `self.*`
    /// without crossing concurrency domains — strict-concurrency-safe.
    public func events() -> AsyncStream<ControlEvent> {
        continuation?.finish()
        let (stream, c) = AsyncStream<ControlEvent>.makeStream()
        self.continuation = c
        // Replay anything that arrived before the subscriber attached —
        // the server's register-time call replay can race app bring-up,
        // and a dropped replayed offer has no REST catch-up.
        for e in pendingEvents { c.yield(e) }
        pendingEvents.removeAll()
        return stream
    }

    public func status() -> AsyncStream<ControlWebSocketStatus> {
        statusContinuation?.finish()
        let (stream, c) = AsyncStream<ControlWebSocketStatus>.makeStream()
        self.statusContinuation = c
        for st in pendingStatus { c.yield(st) }
        pendingStatus.removeAll()
        return stream
    }

    /// Events/status that landed before a subscriber attached. Bounded;
    /// overflow drops the OLDEST entries (the newest state is the one a
    /// late subscriber needs).
    private var pendingEvents: [ControlEvent] = []
    private var pendingStatus: [ControlWebSocketStatus] = []
    private static let maxPendingBuffer = 256

    func deliver(_ event: ControlEvent) {
        if let continuation {
            continuation.yield(event)
            return
        }
        pendingEvents.append(event)
        if pendingEvents.count > Self.maxPendingBuffer {
            pendingEvents.removeFirst(pendingEvents.count - Self.maxPendingBuffer)
        }
    }

    private func deliverStatus(_ s: ControlWebSocketStatus) {
        if let statusContinuation {
            statusContinuation.yield(s)
            return
        }
        pendingStatus.append(s)
        if pendingStatus.count > Self.maxPendingBuffer {
            pendingStatus.removeFirst(pendingStatus.count - Self.maxPendingBuffer)
        }
    }

    /// Start the connection. Idempotent — multiple calls are no-ops.
    public func start() {
        guard task == nil, !stopped else { return }
        connect()
    }

    public func stop() {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        continuation?.finish()
        continuation = nil
        statusContinuation?.finish()
        statusContinuation = nil
    }

    /// Send a typed outbound frame. Returns false when the socket is
    /// down or the send failed — typing callers ignore the result
    /// (best-effort by design); call signaling queues failed frames
    /// for replay (`RestCallSignaling.flushPendingSignals`).
    @discardableResult
    public func send(_ frame: ControlOutbound) async -> Bool {
        guard let task else { return false }
        do {
            let data = try JSONEncoder().encode(frame)
            try await task.send(.data(data))
            return true
        } catch {
            // Don't crash the app on a transient send failure.
            return false
        }
    }

    // MARK: - Internals

    private func connect() {
        deliverStatus(.connecting)

        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/ws/control"), resolvingAgainstBaseURL: false)!
        if let scheme = components.scheme {
            components.scheme = (scheme == "https") ? "wss" : "ws"
        }
        // v0.2.3 auth: token as the first WebSocket subprotocol — the
        // server's bearerToken() helper reads it out of the upgrade
        // request's `Sec-WebSocket-Protocol` header.
        //
        // Apple's URLSessionWebSocketTask owns the subprotocol header
        // and ignores anything the caller sets via
        // setValue(_:forHTTPHeaderField:). Subprotocols MUST be passed
        // via webSocketTask(with:protocols:).
        let token = tokenProvider() ?? ""
        let task = session.webSocketTask(with: components.url!, protocols: [token])
        self.task = task
        announcedConnected = false
        task.resume()
        // NOTE: do not reset `reconnectAttempts` here — backoff has to
        // keep ramping until the upgrade is PROVEN (pong or first
        // inbound frame). Resetting on connect() would let a token
        // still-being-rotated hammer the server in a tight loop.

        // Probe the upgrade with a ping. Waiting for receive() alone
        // only proves the socket once the server happens to send a
        // frame — which can be never on a quiet channel, leaving
        // `.connected` (and the signal-replay flush that hangs off it)
        // stuck forever after a silent reconnect.
        Task { [weak self] in
            await self?.probeOpen(task: task)
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task: task)
        }

        // Upgrade watchdog. If neither the ping probe nor a first inbound
        // frame proves the socket within this window, force a reconnect.
        // Without it a socket that wedges DURING the upgrade (half-open
        // handshake) leaves probeOpen and receiveLoop both blocked forever
        // and keepalive never starts (it starts in markConnected) — so no
        // reconnect ever fires and the terminal-state replay is never pulled.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
            await self?.failIfNotConnected(task: task)
        }
    }

    /// Connection-establishment timeout — generous, since a healthy upgrade
    /// completes in well under a second.
    private static let connectTimeout: TimeInterval = 15

    private func failIfNotConnected(task: URLSessionWebSocketTask) {
        // Still this attempt, still un-proven → the upgrade wedged. Cancel so
        // receiveLoop's receive() throws and schedules a reconnect.
        guard !stopped, self.task === task, !announcedConnected else { return }
        NTLogger.transport.debug("control WS upgrade timed out — forcing reconnect")
        task.cancel(with: .goingAway, reason: nil)
    }

    /// Set per connection attempt; gates the `.connected` announcement
    /// so the ping-probe and the first-frame path can't double-fire.
    private var announcedConnected = false

    private func markConnected() {
        guard !announcedConnected else { return }
        announcedConnected = true
        reconnectAttempts = 0
        deliverStatus(.connected)
        startKeepalive()
    }

    // MARK: - Keepalive

    /// Application-level WS ping cadence. `URLSessionWebSocketTask` does NOT
    /// ping on its own. Without a keepalive a half-open connection (NAT
    /// rebind, REALITY idle reap, a network change mid-call) is never
    /// detected because `receive()` blocks forever waiting for bytes that
    /// will never come — so the server's live `call_state_changed: ended`
    /// is dropped into a dead socket and NO reconnect fires to pull the
    /// terminal replay (OnWSRegister), stranding the peer in an active call.
    /// Pinging also keeps idle middleboxes from reaping the connection.
    private static let keepaliveInterval: TimeInterval = 20
    /// How long to wait for a pong before declaring the socket dead. A true
    /// half-open socket buffers the ping with no RST, so the callback may
    /// never fire — bound it so the loop can force a reconnect.
    private static let keepaliveTimeout: TimeInterval = 10

    /// Exactly-once resume guard. The bounded ping races the pong callback
    /// against a timeout; whichever lands first resumes the continuation and
    /// the other becomes a no-op. A double resume traps
    /// `withCheckedContinuation`, so this lock-guarded latch is mandatory.
    final class PingGate: @unchecked Sendable {
        private let lock = NSLock()
        private var spent = false
        func fire(_ block: () -> Void) {
            lock.lock()
            let first = !spent
            spent = true
            lock.unlock()
            if first { block() }
        }
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        guard let task else { return }
        keepaliveTask = Task { [weak self] in
            await self?.keepaliveLoop(task: task)
        }
    }

    private func keepaliveLoop(task: URLSessionWebSocketTask) async {
        while !stopped, self.task === task {
            try? await Task.sleep(nanoseconds: UInt64(Self.keepaliveInterval * 1_000_000_000))
            guard !stopped, self.task === task else { return }
            let alive = await pingOnce(task: task, timeout: Self.keepaliveTimeout)
            guard !stopped, self.task === task else { return }
            if !alive {
                // Dead / half-open — drop the socket so receiveLoop unblocks
                // and reconnects; the server then replays terminal call state.
                NTLogger.transport.debug("control WS keepalive failed — forcing reconnect")
                task.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    /// Send a ping, returning true if a pong arrives before `timeout`. The
    /// `PingGate` guarantees the continuation resumes exactly once whether
    /// the pong callback or the timeout wins.
    private func pingOnce(task: URLSessionWebSocketTask, timeout: TimeInterval) async -> Bool {
        let gate = PingGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            task.sendPing { error in
                gate.fire { cont.resume(returning: error == nil) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                gate.fire { cont.resume(returning: false) }
            }
        }
    }

    private func probeOpen(task: URLSessionWebSocketTask) async {
        let opened: Bool = await withCheckedContinuation { cont in
            task.sendPing { error in
                cont.resume(returning: error == nil)
            }
        }
        guard opened, !stopped, self.task === task else { return }
        markConnected()
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        // A successful receive() also proves the upgrade landed —
        // belt-and-suspenders alongside the ping probe.
        while !stopped {
            do {
                let message = try await task.receive()
                markConnected()
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                if let event = Self.parse(data: data) {
                    deliver(event)
                }
            } catch {
                // Drop and reconnect.
                break
            }
        }
        if !stopped {
            await scheduleReconnect()
        }
    }

    private func scheduleReconnect() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        reconnectAttempts += 1
        let delay = Self.backoffSeconds(forAttempt: reconnectAttempts)
        deliverStatus(.reconnecting(after: delay))
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !stopped else { return }
        task = nil
        connect()
    }

    /// Backoff schedule: 1s, 2s, 4s, ... capped at 30s. Adds ±15% jitter.
    public static func backoffSeconds(forAttempt attempt: Int) -> TimeInterval {
        let base = min(pow(2.0, Double(max(1, attempt) - 1)), 30.0)
        let jitter = Double.random(in: -0.15...0.15) * base
        return max(0.5, base + jitter)
    }

    /// Parse a single inbound frame into a `ControlEvent`. Returns nil
    /// when the frame is shape-valid JSON but lacks fields we route on.
    public static func parse(data: Data) -> ControlEvent? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            return nil
        }
        switch type {
        case "message":
            guard
                let id = json["id"] as? String,
                let from = json["from"] as? String,
                let to = json["to"] as? String,
                let env = json["envelope"] as? String,
                let sentAt = parseInt64(json["sent_at"]),
                let receivedAt = parseInt64(json["received_at"])
            else { return .unknown(type: type) }
            return .messageIncoming(
                id: id, from: from, to: to,
                envelopeBase64: env,
                sentAt: sentAt, receivedAt: receivedAt,
                replyToId: json["reply_to_id"] as? String
            )
        case "message_delivered":
            return (json["message_id"] as? String).map(ControlEvent.messageDelivered) ?? .unknown(type: type)
        case "message_read":
            return (json["message_id"] as? String).map(ControlEvent.messageRead) ?? .unknown(type: type)
        case "reaction":
            guard
                let id = json["id"] as? String,
                let reactionId = json["reaction_id"] as? String,
                let sender = json["sender_user_id"] as? String,
                let env = json["envelope"] as? String,
                let sentAt = parseInt64(json["sent_at"]),
                let receivedAt = parseInt64(json["received_at"])
            else { return .unknown(type: type) }
            return .reactionUpdate(messageId: id, reactionId: reactionId, senderUserId: sender, envelopeBase64: env, sentAt: sentAt, receivedAt: receivedAt)
        case "typing_start", "typing_stop":
            guard
                let from = json["from"] as? String,
                let to = json["to"] as? String,
                let at = parseInt64(json["at"])
            else { return .unknown(type: type) }
            return type == "typing_start"
                ? .typingStart(from: from, to: to, atMillis: at)
                : .typingStop(from: from, to: to, atMillis: at)
        case "incoming_call":
            guard
                let callId = json["call_id"] as? String,
                let from = json["from_user_id"] as? String,
                let kind = json["kind"] as? String,
                let at = parseInt64(json["at"])
            else { return .unknown(type: type) }
            return .incomingCall(callId: callId, fromUserId: from, kind: kind, atMillis: at)
        case "call_signal":
            guard
                let callId = json["call_id"] as? String,
                let at = parseInt64(json["at"])
            else { return .unknown(type: type) }
            let payload = (json["payload"] as? [String: Any]) ?? [:]
            let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return .callSignal(callId: callId, payloadJSON: payloadData, atMillis: at)
        case "call_signal_ack":
            guard
                let signalId = json["signal_id"] as? String,
                let at = parseInt64(json["at"])
            else { return .unknown(type: type) }
            return .callSignalAck(signalId: signalId, atMillis: at)
        case "call_state_changed":
            guard
                let callId = json["call_id"] as? String,
                let state = json["state"] as? String,
                let at = parseInt64(json["at"])
            else { return .unknown(type: type) }
            return .callStateChanged(
                callId: callId, state: state,
                stale: (json["stale"] as? Bool) ?? false,
                endedReason: json["ended_reason"] as? String,
                atMillis: at
            )
        case "call_missed":
            guard
                let callId = json["call_id"] as? String,
                let from = json["from_user_id"] as? String,
                let at = parseInt64(json["at"])
            else { return .unknown(type: type) }
            return .callMissed(callId: callId, fromUserId: from, atMillis: at)
        case "presence_changed":
            guard
                let userId = json["user_id"] as? String,
                let online = json["online"] as? Bool,
                let at = parseInt64(json["at"])
            else { return .unknown(type: type) }
            return .presenceChanged(userId: userId, online: online, atMillis: at)
        case "server_restored":
            guard
                let gen = parseInt64(json["generation"]),
                let kid = json["jwt_kid"] as? String,
                let at = parseInt64(json["at"])
            else { return .unknown(type: type) }
            return .serverRestored(generation: gen, jwtKid: kid, atMillis: at)
        default:
            return .unknown(type: type)
        }
    }

    /// JSONSerialization bridges JSON Numbers as `NSNumber` regardless
    /// of magnitude. Casting NSNumber to Int64 directly fails; go
    /// through Int64Value.
    private static func parseInt64(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let i = value as? Int { return Int64(i) }
        if let i = value as? Int64 { return i }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}
