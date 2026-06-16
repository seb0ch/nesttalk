import XCTest
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class EnrolledIdentityStoreTests: XCTestCase {

    override func tearDown() {
        EnrolledIdentityStore.delete()
        super.tearDown()
    }

    func test_round_trip_returns_same_identity() throws {
        let id = EnrolledIdentity(
            userId: "u-1", deviceId: "d-1",
            displayName: "Mom", colorHint: 3
        )
        try EnrolledIdentityStore.save(id)
        let loaded = try XCTUnwrap(EnrolledIdentityStore.load())
        XCTAssertEqual(loaded, id)
    }

    func test_load_returns_nil_when_absent() {
        EnrolledIdentityStore.delete()
        XCTAssertNil(EnrolledIdentityStore.load())
    }

    func test_save_overwrites_existing_entry() throws {
        try EnrolledIdentityStore.save(EnrolledIdentity(
            userId: "u-1", deviceId: "d-1", displayName: "Old", colorHint: 0
        ))
        try EnrolledIdentityStore.save(EnrolledIdentity(
            userId: "u-2", deviceId: "d-2", displayName: "New", colorHint: 1
        ))
        XCTAssertEqual(EnrolledIdentityStore.load()?.displayName, "New")
        XCTAssertEqual(EnrolledIdentityStore.load()?.userId, "u-2")
    }
}

final class SessionTokenStoreTests: XCTestCase {

    override func tearDown() {
        SessionTokenStore.delete()
        super.tearDown()
    }

    func test_round_trip_preserves_token_and_expiry() throws {
        let s = ActiveSession(
            sessionToken: "tok-abc",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            deviceId: "dev-1"
        )
        try SessionTokenStore.save(s)
        let loaded = try XCTUnwrap(SessionTokenStore.load())
        XCTAssertEqual(loaded.sessionToken, s.sessionToken)
        XCTAssertEqual(loaded.deviceId, s.deviceId)
        XCTAssertEqual(loaded.expiresAt.timeIntervalSince1970, s.expiresAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_delete_clears_storage() throws {
        try SessionTokenStore.save(ActiveSession(
            sessionToken: "x", expiresAt: Date(), deviceId: "d"
        ))
        SessionTokenStore.delete()
        XCTAssertNil(SessionTokenStore.load())
    }
}

final class TransportConfigStoreTests: XCTestCase {

    override func tearDown() {
        TransportConfigStore.delete()
        super.tearDown()
    }

    func test_round_trip_preserves_all_fields() throws {
        let cfg = TransportConfig(
            apiUuid: "API-UUID",
            turnUuid: "TURN-UUID",
            bootstrap: TransportConfig.Bootstrap(
                serverAddress: "nest.example.com",
                serverPort: 443,
                serverName: "cloudflare.com",
                realityPublicKey: "BASE64KEY",
                realityShortID: "deadbeef"
            )
        )
        try TransportConfigStore.save(cfg)
        let loaded = try XCTUnwrap(TransportConfigStore.load())
        XCTAssertEqual(loaded.apiUuid, "API-UUID")
        XCTAssertEqual(loaded.turnUuid, "TURN-UUID")
        XCTAssertEqual(loaded.bootstrap.serverAddress, "nest.example.com")
        XCTAssertEqual(loaded.bootstrap.realityShortID, "deadbeef")
        XCTAssertEqual(loaded.fingerprint, cfg.fingerprint)
    }

    func test_save_with_nil_turn_uuid() throws {
        let cfg = TransportConfig(
            apiUuid: "A",
            turnUuid: nil,
            bootstrap: TransportConfig.Bootstrap(
                serverAddress: "h", serverPort: 1, serverName: "s",
                realityPublicKey: "k", realityShortID: "i"
            )
        )
        try TransportConfigStore.save(cfg)
        XCTAssertNil(TransportConfigStore.load()?.turnUuid)
    }
}
