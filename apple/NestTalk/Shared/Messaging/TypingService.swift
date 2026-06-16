import Foundation

/// Outbound typing indicator. Sends `typing_start` over the WS control
/// channel after a 300 ms keystroke debounce, coalesces follow-up
/// keystrokes for 3 s, and emits `typing_stop` after 5 s of idle (or on
/// `flush()` from `ScenePhase.background`). Caps outbound traffic at
/// 10 frames per minute per (sender, recipient) pair.
///
/// The wire shape is JSON over the WebSocket — `{"type":"typing_start","to":"<userId>"}`.
/// Server side is `server/internal/messages/typing.go`.
public actor TypingService {

    private let send: (ControlOutbound) async -> Void
    private var lastSendAt: [String: Date] = [:]
    private var idleTimers: [String: Task<Void, Never>] = [:]
    private var minuteRing: [Date] = []
    private static let cap = 10
    private static let idleAfter: TimeInterval = 5.0
    private static let coalesceWindow: TimeInterval = 3.0
    public static let debounceMillis: Int = 300

    public init(send: @escaping (ControlOutbound) async -> Void) {
        self.send = send
    }

    /// Called on each keystroke — emits typing_start (if outside the
    /// coalesce window AND under the 10/min cap) and (re)arms the
    /// implicit-stop timer.
    public func keystroke(toUserId: String, now: Date = Date()) async {
        // Cap: prune ring to last minute, refuse if at limit.
        minuteRing = minuteRing.filter { now.timeIntervalSince($0) < 60 }
        if minuteRing.count >= Self.cap { return }

        // Coalesce: skip if we just sent a typing_start within window.
        if let last = lastSendAt[toUserId], now.timeIntervalSince(last) < Self.coalesceWindow {
            armIdleTimer(toUserId: toUserId)
            return
        }

        lastSendAt[toUserId] = now
        minuteRing.append(now)
        await send(.typingStart(to: toUserId))
        armIdleTimer(toUserId: toUserId)
    }

    /// Force a typing_stop now, e.g., on ScenePhase.background.
    public func flush(toUserId: String? = nil) async {
        if let toUserId {
            await stopAndCancel(toUserId: toUserId)
            return
        }
        // Snapshot keys before iterating — Dictionary.Keys is a view
        // over live storage; mutating `lastSendAt` (which stopAndCancel
        // does) while iterating is undefined behavior in Swift and can
        // crash with "index out of bounds".
        for k in Array(lastSendAt.keys) {
            await stopAndCancel(toUserId: k)
        }
    }

    private func armIdleTimer(toUserId: String) {
        idleTimers[toUserId]?.cancel()
        idleTimers[toUserId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleAfter * 1_000_000_000))
            guard let self else { return }
            if Task.isCancelled { return }
            await self.stopAndCancel(toUserId: toUserId)
        }
    }

    private func stopAndCancel(toUserId: String) async {
        idleTimers[toUserId]?.cancel()
        idleTimers.removeValue(forKey: toUserId)
        if lastSendAt.removeValue(forKey: toUserId) != nil {
            await send(.typingStop(to: toUserId))
        }
    }

    /// Test introspection.
    public func _trafficCount() -> Int { minuteRing.count }
}

/// Inbound typing state — driven by ControlEvent.typingStart / .typingStop.
/// Holds a `[userId: Bool]` published map for SwiftUI consumers (the
/// chat-list "typing…" preview, the thread-header subtitle).
@MainActor
public final class TypingObserver: ObservableObject {
    /// Shared no-op instance for previews / tests — never fed events.
    public static let inert = TypingObserver()

    @Published public private(set) var typing: [String: Bool] = [:]
    private var stopTimers: [String: Task<Void, Never>] = [:]

    public init() {}

    public func ingest(_ event: ControlEvent) {
        switch event {
        case .typingStart(let from, _, _):
            typing[from] = true
            armStopTimer(for: from)
        case .typingStop(let from, _, _):
            typing[from] = false
            stopTimers[from]?.cancel()
            stopTimers.removeValue(forKey: from)
        default:
            break
        }
    }

    private func armStopTimer(for userId: String) {
        stopTimers[userId]?.cancel()
        stopTimers[userId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(7 * 1_000_000_000))
            guard let self else { return }
            if Task.isCancelled { return }
            await MainActor.run {
                self.typing[userId] = false
                self.stopTimers.removeValue(forKey: userId)
            }
        }
    }
}
