import XCTest
import CryptoKit
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class SessionServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func test_enroll_happy_path_signs_challenge_and_returns_identity() async throws {
        let device = try DeviceIdentity.createAndPersist(tag: testTag)
        defer { try? DeviceIdentity.delete(tag: testTag) }

        let challenge = Data("server-challenge-bytes".utf8)

        StubURLProtocol.handler = { req in
            switch req.url!.path {
            case "/api/v1/auth/enroll/start":
                let reqBody = try! JSONDecoder().decode([String: String].self, from: StubURLProtocol.bodyOf(req)!)
                XCTAssertEqual(reqBody["code"], "family-invite-code")
                return StubURLProtocol.json(200, [
                    "challenge": challenge.base64EncodedString()
                ])
            case "/api/v1/auth/enroll/complete":
                let body = StubURLProtocol.bodyOf(req)!
                let parsed = try! JSONSerialization.jsonObject(with: body) as! [String: String]
                XCTAssertEqual(parsed["code"], "family-invite-code")
                XCTAssertEqual(parsed["device_pubkey"],
                               device.publicKey.rawRepresentation.base64EncodedString())
                let sig = Data(base64Encoded: parsed["attestation"]!)!
                XCTAssertTrue(device.publicKey.isValidSignature(sig, for: challenge))
                return StubURLProtocol.json(200, [
                    "user_id": "user-001",
                    "device_id": "dev-001",
                    "display_name": "Mom",
                    "color_hint": 3,
                ])
            default:
                XCTFail("unexpected path \(req.url!.path)")
                return StubURLProtocol.json(500, ["error": "unexpected"])
            }
        }

        let service = SessionService(
            baseURL: URL(string: "https://stub.local")!,
            session: StubURLProtocol.session()
        )
        let enrolled = try await service.enroll(
            code: "family-invite-code",
            identity: device,
            messagePubKey: Data(repeating: 0xab, count: 1216)
        )
        XCTAssertEqual(enrolled.userId,      "user-001")
        XCTAssertEqual(enrolled.deviceId,    "dev-001")
        XCTAssertEqual(enrolled.displayName, "Mom")
        XCTAssertEqual(enrolled.colorHint,   3)
    }

    func test_enroll_maps_server_error_body() async throws {
        let device = try DeviceIdentity.createAndPersist(tag: testTag)
        defer { try? DeviceIdentity.delete(tag: testTag) }

        StubURLProtocol.handler = { _ in
            StubURLProtocol.json(410, ["error": "enrollment code expired"])
        }

        let service = SessionService(
            baseURL: URL(string: "https://stub.local")!,
            session: StubURLProtocol.session()
        )
        do {
            _ = try await service.enroll(
                code: "bad", identity: device,
                messagePubKey: Data(repeating: 0, count: 32)
            )
            XCTFail("expected httpStatus")
        } catch SessionService.Error.httpStatus(let code, let reason) {
            XCTAssertEqual(code, 410)
            XCTAssertEqual(reason, "enrollment code expired")
        }
    }

    func test_connect_happy_path_returns_session_token() async throws {
        let device = try DeviceIdentity.createAndPersist(tag: testTag)
        defer { try? DeviceIdentity.delete(tag: testTag) }

        let nonceBytes = Data("server-nonce-abcdefg".utf8)
        let nonceB64   = nonceBytes.base64EncodedString()

        StubURLProtocol.handler = { req in
            switch req.url!.path {
            case "/api/v1/auth/connect/challenge":
                let parsed = try! JSONSerialization.jsonObject(with: StubURLProtocol.bodyOf(req)!) as! [String: String]
                XCTAssertEqual(parsed["device_id"], "dev-001")
                return StubURLProtocol.json(200, ["nonce": nonceB64])
            case "/api/v1/auth/connect/complete":
                let parsed = try! JSONSerialization.jsonObject(with: StubURLProtocol.bodyOf(req)!) as! [String: Any]
                XCTAssertEqual(parsed["device_id"] as? String, "dev-001")
                XCTAssertEqual(parsed["nonce"]     as? String, nonceB64)
                let sig = Data(base64Encoded: parsed["attestation"] as! String)!
                XCTAssertTrue(device.publicKey.isValidSignature(sig, for: nonceBytes))
                return StubURLProtocol.json(200, [
                    "session_token": "sess_xyz",
                    // server returns expires_at as unix MILLISECONDS
                    "expires_at":    Int(Date().timeIntervalSince1970 * 1000) + 3_600_000,
                ])
            default:
                XCTFail("unexpected path")
                return StubURLProtocol.json(500, ["error": "unexpected"])
            }
        }

        let service = SessionService(
            baseURL: URL(string: "https://stub.local")!,
            session: StubURLProtocol.session()
        )
        let session = try await service.connect(deviceId: "dev-001", identity: device)
        XCTAssertEqual(session.sessionToken, "sess_xyz")
        XCTAssertEqual(session.deviceId,     "dev-001")
        XCTAssertGreaterThan(session.expiresAt, Date())
    }

    // MARK: - Helpers

    private var testTag: String { "com.nesttalk.test.session-\(name)" }
}

// ─── URLProtocol stub ─────────────────────────────────────────

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) private static var bodyByTask: [ObjectIdentifier: Data] = [:]

    static func reset() {
        handler = nil
        bodyByTask.removeAll()
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    static func json(_ status: Int, _ body: [String: Any]) -> (Int, [String: String], Data) {
        let data = try! JSONSerialization.data(withJSONObject: body)
        return (status, ["Content-Type": "application/json"], data)
    }

    /// Extract the POST body — `httpBody` is often nil on URLRequest passed
    /// into URLProtocol; fallback to `httpBodyStream`.
    static func bodyOf(_ req: URLRequest) -> Data? {
        if let b = req.httpBody { return b }
        guard let stream = req.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
