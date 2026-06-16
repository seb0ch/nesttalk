import XCTest
import CryptoKit
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class SessionRefresherTests: XCTestCase {

    /// Smoke-only: SessionRefresher's loop hands work to a real
    /// SessionService against a real REALITY transport — that needs
    /// a server. Here we exercise the bookkeeping that doesn't touch
    /// the network: the public API surface compiles, start/stop are
    /// idempotent, and the lead-time constant is sane.
    func test_lead_time_is_five_minutes() {
        XCTAssertEqual(SessionRefresher.leadTime, 5 * 60)
    }

    func test_start_then_stop_does_not_crash() async throws {
        // The refresher constructor needs a SessionService + a
        // DeviceIdentity. Both are built fresh; the test never lets
        // the loop reach the network because it cancels via stop()
        // immediately. A token expiring far in the future means the
        // loop sleeps before the first connect attempt.
        let device = Curve25519.Signing.PrivateKey()
        let identity = DeviceIdentity(privateKey: device)
        let svc = SessionService(baseURL: URL(string: "http://127.0.0.1:1")!)

        let refresher = SessionRefresher(
            session: svc,
            identity: identity,
            onRefresh: { _ in }
        )
        let session = ActiveSession(
            sessionToken: "tok",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            deviceId: "dev"
        )
        await refresher.start(current: session)
        await refresher.stop()
    }

    /// Smoke: refreshNow before any start (no `current`) is a safe no-op —
    /// the server_restored handler may fire before the refresher is seeded.
    /// Behavioral coverage (refreshNow → connect → onRefresh) needs the
    /// e2e harness, like the rest of this file.
    func test_refresh_now_without_current_is_noop() async {
        let device = Curve25519.Signing.PrivateKey()
        let identity = DeviceIdentity(privateKey: device)
        let svc = SessionService(baseURL: URL(string: "http://127.0.0.1:1")!)
        let refresher = SessionRefresher(session: svc, identity: identity, onRefresh: { _ in })
        await refresher.refreshNow()   // no current session → returns immediately
        await refresher.stop()
    }
}
