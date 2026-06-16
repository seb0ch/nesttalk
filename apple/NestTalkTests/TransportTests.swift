import XCTest
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class TransportConfigTests: XCTestCase {

    private func makeConfig(turn: String? = nil) -> TransportConfig {
        TransportConfig(
            apiUuid: "11111111-2222-3333-4444-555555555555",
            turnUuid: turn,
            bootstrap: .init(
                serverAddress: "nest.example.com",
                serverPort: 443,
                serverName: "cloudflare.com",
                realityPublicKey: "u0RZRvKAKfmzkHRktNdkPaBQE2jcNz0ikt1QBQEb0i0=",
                realityShortID: "a1b2c3d4"
            )
        )
    }

    func test_fingerprint_changes_when_turn_uuid_appears() {
        let before = makeConfig()
        let after  = makeConfig(turn: "99999999-8888-7777-6666-555555555555")
        XCTAssertNotEqual(before.fingerprint, after.fingerprint)
    }

    func test_fingerprint_stable_for_equal_configs() {
        XCTAssertEqual(makeConfig().fingerprint, makeConfig().fingerprint)
    }
}

final class LibboxConfigBuilderTests: XCTestCase {

    func test_api_only_config_has_one_inbound_and_outbound() throws {
        let config = TransportConfig(
            apiUuid: "11111111-2222-3333-4444-555555555555",
            turnUuid: nil,
            bootstrap: .init(
                serverAddress: "nest.example.com",
                serverPort: 443,
                serverName: "cloudflare.com",
                realityPublicKey: "u0RZRvKAKfmzkHRktNdkPaBQE2jcNz0ikt1QBQEb0i0=",
                realityShortID: "a1b2c3d4"
            )
        )
        let json = try LibboxConfigBuilder.build(config: config, apiPort: 62080, turnPort: nil)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        let inbounds  = try XCTUnwrap(parsed["inbounds"]  as? [[String: Any]])
        let outbounds = try XCTUnwrap(parsed["outbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.count,  1)
        XCTAssertEqual(outbounds.count, 1)
        XCTAssertEqual(inbounds[0]["tag"]  as? String, "api-in")
        XCTAssertEqual(inbounds[0]["listen_port"] as? Int, 62080)
        XCTAssertEqual(outbounds[0]["tag"] as? String, "api-out")
        XCTAssertEqual(outbounds[0]["server"] as? String, "nest.example.com")
        XCTAssertEqual(outbounds[0]["server_port"] as? Int, 443)
        XCTAssertEqual(outbounds[0]["uuid"] as? String, config.apiUuid)
    }

    func test_api_plus_turn_config_has_two_inbounds_and_outbounds() throws {
        let config = TransportConfig(
            apiUuid:  "11111111-2222-3333-4444-555555555555",
            turnUuid: "99999999-8888-7777-6666-555555555555",
            bootstrap: .init(
                serverAddress: "nest.example.com",
                serverPort: 443,
                serverName: "cloudflare.com",
                realityPublicKey: "u0RZRvKAKfmzkHRktNdkPaBQE2jcNz0ikt1QBQEb0i0=",
                realityShortID: "a1b2c3d4"
            )
        )
        let json = try LibboxConfigBuilder.build(config: config, apiPort: 62080, turnPort: 62180)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        let inbounds  = try XCTUnwrap(parsed["inbounds"]  as? [[String: Any]])
        let outbounds = try XCTUnwrap(parsed["outbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.count,  2)
        XCTAssertEqual(outbounds.count, 2)
        XCTAssertEqual((inbounds.map  { $0["tag"] as? String }).compactMap { $0 }.sorted(),
                       ["api-in",  "turn-in"])
        XCTAssertEqual((outbounds.map { $0["tag"] as? String }).compactMap { $0 }.sorted(),
                       ["api-out", "turn-out"])

        let route = try XCTUnwrap(parsed["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 2)
    }

    func test_outbound_carries_reality_fingerprint_chrome() throws {
        let config = TransportConfig(
            apiUuid: "11111111-2222-3333-4444-555555555555",
            turnUuid: nil,
            bootstrap: .init(
                serverAddress: "nest.example.com",
                serverPort: 443,
                serverName: "cloudflare.com",
                realityPublicKey: "u0RZRvKAKfmzkHRktNdkPaBQE2jcNz0ikt1QBQEb0i0=",
                realityShortID: "a1b2c3d4"
            )
        )
        let json = try LibboxConfigBuilder.build(config: config, apiPort: 62080, turnPort: nil)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let outbounds = try XCTUnwrap(parsed["outbounds"] as? [[String: Any]])
        let tls       = try XCTUnwrap(outbounds[0]["tls"]  as? [String: Any])
        let utls      = try XCTUnwrap(tls["utls"]          as? [String: Any])
        let reality   = try XCTUnwrap(tls["reality"]       as? [String: Any])
        XCTAssertEqual(utls["fingerprint"]   as? String, "chrome")
        XCTAssertEqual(reality["public_key"] as? String, "u0RZRvKAKfmzkHRktNdkPaBQE2jcNz0ikt1QBQEb0i0=")
        XCTAssertEqual(reality["short_id"]   as? String, "a1b2c3d4")
        XCTAssertEqual(outbounds[0]["flow"]  as? String, "xtls-rprx-vision")
    }
}

/// The fresh-enroll cache purge: a stale libbox cache-file from a prior
/// transport config poisoned the REALITY handshake until the working dir was
/// cleared. `purgeWorkingState()` drops exactly that dir (app-scoped) so a
/// fresh enroll starts clean; the connect path never calls it.
final class RealityTransportPurgeTests: XCTestCase {
    func test_purgeWorkingState_removes_the_working_cache_dir() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nt-purge-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let transport = RealityTransport(basePathOverride: root)
        let working = root.appendingPathComponent("NestTalkTransport/working", isDirectory: true)
        try fm.createDirectory(at: working, withIntermediateDirectories: true)
        let cache = working.appendingPathComponent("cache.db")
        try Data("stale".utf8).write(to: cache)
        XCTAssertTrue(fm.fileExists(atPath: cache.path), "precondition: stale cache present")

        transport.purgeWorkingState()

        XCTAssertFalse(fm.fileExists(atPath: working.path), "purge must remove the working/cache dir")
        // The base dir is left intact — start() recreates working/ via ensureDirectories.
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("NestTalkTransport").path),
                      "purge must NOT nuke the whole transport base")
    }
}
