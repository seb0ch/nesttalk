import Foundation

/// Background refresher that reissues the session token before it
/// expires. Sleeps until ~5 minutes before `ActiveSession.expiresAt`,
/// runs `SessionService.connect`, persists, repeats.
///
/// Cancel via `stop()` on sign-out / `appState.transition(to: .error)`.
public actor SessionRefresher {

    /// How early to refresh before nominal expiry. Server tokens are
    /// typically 24h; 5-minute headroom is enough for jittered
    /// network paths to settle.
    public static let leadTime: TimeInterval = 5 * 60

    private let session: SessionService
    private let identity: DeviceIdentity
    private let onRefresh: @Sendable (ActiveSession) -> Void
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?
    /// The freshest session — seeded by `start`, advanced after each
    /// refresh, and used by `refreshNow` to know which device to re-connect.
    private var current: ActiveSession?
    /// Single-flight guard for `refreshNow`: a flood of 401s (every queued
    /// request failing at once after a restore) must collapse into ONE
    /// re-handshake, not a thundering herd that cancels itself repeatedly.
    private var forcing = false

    public init(
        session: SessionService,
        identity: DeviceIdentity,
        onRefresh: @escaping @Sendable (ActiveSession) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.identity = identity
        self.onRefresh = onRefresh
        self.now = now
    }

    /// Begin the refresh loop seeded with `current`. Idempotent — a
    /// second call cancels the prior loop and starts over.
    public func start(current: ActiveSession) {
        self.current = current
        task?.cancel()
        task = Task { [weak self] in
            await self?.loop(seed: current)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Force an immediate re-connect, bypassing the expiry sleep. Called
    /// when the current token is invalidated out of band — e.g. a
    /// `server_restored` event after a backup restore rotates the JWT
    /// signing key and closes our socket. Without this the client would
    /// keep reconnecting with the rejected token until the expiry-based
    /// loop eventually runs (up to ~an hour later). Resumes the normal
    /// loop from the fresh session.
    public func refreshNow() async {
        guard let cur = current, !forcing else { return }
        forcing = true
        defer { forcing = false }
        task?.cancel()
        do {
            let next = try await session.connect(deviceId: cur.deviceId, identity: identity)
            current = next
            onRefresh(next)
            task = Task { [weak self] in await self?.loop(seed: next) }
        } catch {
            NTLogger.identity.error("forced session refresh failed: \(error)")
            // Resume the loop with an ALREADY-DUE seed — never the old
            // token's real expiry. The current token is invalidated (server
            // restore), so sleeping out its remaining lifetime (up to 24h)
            // would strand the client offline. An expiry of `now()` makes
            // the loop's first iteration attempt a reconnect immediately and
            // then retry on its bounded 30s backoff until it succeeds.
            let dueNow = ActiveSession(
                sessionToken: cur.sessionToken,
                expiresAt: now(),
                deviceId: cur.deviceId
            )
            task = Task { [weak self] in await self?.loop(seed: dueNow) }
        }
    }

    /// Hard cap so a misformatted `expiresAt` (e.g., the year-50000
    /// regression we hit when the server's millisecond `expires_at`
    /// was misread as seconds) can't try to sleep for thousands of
    /// years — `UInt64(secs * 1e9)` would crash on the >UInt64.max
    /// double-to-int conversion.
    public static let maxSleep: TimeInterval = 24 * 60 * 60  // 24 hours

    private func loop(seed: ActiveSession) async {
        var active = seed
        while !Task.isCancelled {
            let raw = active.expiresAt.timeIntervalSince(now()) - Self.leadTime
            let sleepFor = max(0, min(raw, Self.maxSleep))
            if sleepFor > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepFor * 1_000_000_000))
                if Task.isCancelled { return }
            }
            do {
                let next = try await session.connect(
                    deviceId: active.deviceId,
                    identity: identity
                )
                onRefresh(next)
                active = next
                current = next
            } catch {
                // Transient network failure — back off 30s and retry.
                // A persistent failure (token expired AND we can't refresh)
                // surfaces via the next API call's 401, which higher layers
                // will translate into an .error phase.
                NTLogger.identity.error("session refresh failed: \(error)")
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }
}
