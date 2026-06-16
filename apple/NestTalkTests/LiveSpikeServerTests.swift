import XCTest
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

/// Live integration against the production server at `ssh nesttalk`
/// (24.199.101.94:443, v0.2.3 server, unchanged). Skipped unless
/// `NESTTALK_LIVE_SERVER=1` is set in the test environment — so CI and
/// sandbox-bound test runs don't try to reach the network.
///
/// Run manually:
///   NESTTALK_LIVE_SERVER=1 \
///   NESTTALK_SPIKE_INVITE='nesttalk://i/…' \
///   xcodebuild test -scheme NestTalk-macOS \
///     -destination 'platform=macOS' \
///     -only-testing:NestTalkTests/LiveSpikeServerTests
///
/// The invite is issued once per test run via:
///   ssh nesttalk "podman exec nesttalk-cli nesttalk-cli enroll spike-test-$(date +%s)"
final class LiveSpikeServerTests: XCTestCase {

    private var transport: RealityTransport!

    override func setUp() async throws {
        try await super.setUp()
        // The legacy `NESTTALK_LIVE_SPIKE` name is accepted as a transitional
        // alias so devs running the spike-era invocation form keep working;
        // CI and the live-integration workflow drive the new name.
        let env = ProcessInfo.processInfo.environment
        let enabled = env["NESTTALK_LIVE_SERVER"] == "1" || env["NESTTALK_LIVE_SPIKE"] == "1"
        try XCTSkipIf(
            !enabled,
            "Set NESTTALK_LIVE_SERVER=1 to run live-server integration tests"
        )
    }

    override func tearDown() async throws {
        transport?.stop()
        try await super.tearDown()
    }

    // MARK: - The Day 1 deferred test: real /health roundtrip through REALITY

    func test_health_roundtrip_through_reality() async throws {
        let invite = try requireInvite()
        let payload = EnrollmentPayload.parse(invite)
        let bootstrap = try XCTUnwrap(payload.bootstrap, "invite missing REALITY bootstrap")

        // During enrollment we only have the API UUID; turn UUID is absent
        // until connect completes.
        let config = TransportConfig(
            apiUuid:  payload.apiUuid ?? "",
            turnUuid: nil,
            bootstrap: bootstrap
        )
        XCTAssertFalse(config.apiUuid.isEmpty, "invite carries no api_uuid — re-issue with v0.2.3+ CLI")

        // Isolate each test into its own base path so libbox's cache-file
        // and command-server port don't collide when tests run sequentially.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nesttalk-live-\(UUID().uuidString)", isDirectory: true)
        transport = RealityTransport(basePathOverride: scratch)
        let snapshot = try transport.start(config: config)
        print("[spike] RealityTransport up at \(snapshot.apiBaseURL)")

        let client = APIClient(baseURL: snapshot.apiBaseURL)

        // Retry loop — libbox takes a second to finish REALITY handshake.
        var lastError: Error?
        var rtMillis: Double = -1
        for attempt in 1...15 {
            do {
                let start = Date()
                let health = try await client.health()
                rtMillis = Date().timeIntervalSince(start) * 1000
                XCTAssertTrue(health.ok, "server reported !ok")
                XCTAssertEqual(health.api_version, "v0.2.0", "api_version mismatch")
                print("[spike] attempt \(attempt): ok=\(health.ok) api_version=\(health.api_version) gen=\(health.generation) rt=\(Int(rtMillis))ms")
                lastError = nil
                break
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        if let lastError { XCTFail("health never succeeded: \(lastError)") }
    }

    // MARK: - The Day 2 deferred test: real enroll/start handshake

    func test_enroll_start_returns_real_challenge() async throws {
        let invite = try requireInvite()
        let payload = EnrollmentPayload.parse(invite)
        let bootstrap = try XCTUnwrap(payload.bootstrap)
        let code = payload.code
        XCTAssertFalse(code.isEmpty)

        let config = TransportConfig(apiUuid: payload.apiUuid ?? "", turnUuid: nil, bootstrap: bootstrap)
        // Isolate each test into its own base path so libbox's cache-file
        // and command-server port don't collide when tests run sequentially.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("nesttalk-live-\(UUID().uuidString)", isDirectory: true)
        transport = RealityTransport(basePathOverride: scratch)
        let snapshot = try transport.start(config: config)

        // Wait for libbox to come up
        let client = APIClient(baseURL: snapshot.apiBaseURL)
        for _ in 1...15 {
            if (try? await client.health()) != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Manually POST /auth/enroll/start — the full SessionService.enroll
        // would require a valid hybrid-PQC message_pubkey, which the spike
        // doesn't produce. We validate only that the transport + endpoint
        // returns a base64 challenge. /enroll/complete is validated
        // post-spike when mlkem_native is wired.
        let url = snapshot.apiBaseURL.appendingPathComponent("api/v1/auth/enroll/start")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200, "body: \(String(data: data, encoding: .utf8) ?? "?")")
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let b64 = try XCTUnwrap(body?["challenge"] as? String)
        let challenge = try XCTUnwrap(Data(base64Encoded: b64))
        XCTAssertFalse(challenge.isEmpty, "server returned empty challenge")
        print("[spike] enroll/start challenge: \(challenge.count) bytes")
    }

    // MARK: - helpers

    private func requireInvite() throws -> String {
        let invite = ProcessInfo.processInfo.environment["NESTTALK_SPIKE_INVITE"] ?? ""
        try XCTSkipIf(invite.isEmpty, "Set NESTTALK_SPIKE_INVITE=<nesttalk://...> to run live test")
        return invite
    }
}
