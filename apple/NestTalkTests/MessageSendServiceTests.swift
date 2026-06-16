import XCTest
import CryptoKit
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

/// Stub URLProtocol for inline-controlled HTTP responses without
/// touching the network. Each test sets `responder` before kicking off
/// the send call, so behavior is fully deterministic.
final class SimpleStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = SimpleStubURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        let (data, response) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MessageSendServiceTests: XCTestCase {

    private var store: MessageStore!
    private var api: APIClient!
    private var session: URLSession!
    private var dbWrapKey: SymmetricKey!

    override func setUp() async throws {
        try await super.setUp()
        store = try MessageStore.inMemory()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SimpleStubURLProtocol.self]
        session = URLSession(configuration: config)
        api = APIClient(baseURL: URL(string: "http://stub.test")!, session: session)
        dbWrapKey = SymmetricKey(size: .bits256)
    }

    override func tearDown() async throws {
        SimpleStubURLProtocol.responder = nil
        try await super.tearDown()
    }

    func test_happy_path_inserts_local_echo_then_marks_sent_to_server() async throws {
        let serverId = "server-id-7"
        SimpleStubURLProtocol.responder = { req in
            // SendService now resolves the recipient's active device
            // via GET /api/v1/keys/message/<userId> before building
            // the wire envelope.
            if req.httpMethod == "GET", req.url?.path.contains("/keys/message/") == true {
                let body: [String: Any] = [
                    "devices": [[
                        "device_id": "device-mom-1",
                        "public_key": "AAAA",
                        "message_pubkey": "BBBB",
                        "enrolled_at": 1,
                    ]]
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, resp)
            }
            XCTAssertEqual(req.url?.path, "/api/v1/messages")
            XCTAssertEqual(req.httpMethod, "POST")
            let body: [String: Any] = [
                "id": serverId,
                "received_at": 1_700_000_000_000,
                "sent_at": 1_700_000_000_000,
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }

        let svc = MessageSendService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey,
            sessionToken: { "token" },
            selfUserId: { "self" }
        )
        let outcome = await svc.send(text: "hi mom", toUserId: "mom")
        switch outcome {
        case .sentToServer(let id, _): XCTAssertEqual(id, serverId)
        default: XCTFail("expected sentToServer; got \(outcome)")
        }

        // Local row keeps its stable client id but now carries the
        // server-assigned id in `server_id`. The state machine
        // transitions to "sent_to_server".
        let row = try XCTUnwrap(store.message(serverId: serverId))
        XCTAssertEqual(row.state, "sent_to_server")
        XCTAssertEqual(row.plaintext, "hi mom")
        XCTAssertEqual(row.server_id, serverId)
        XCTAssertNotNil(row.local_id)
        XCTAssertEqual(row.id, row.local_id, "id stays equal to local_id post-success")
        // Round-29: the durable pending row is created BEFORE the network
        // attempt and removed atomically on success — none must linger, or
        // OutboxService would re-send a delivered message.
        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 9999)).count, 0,
                       "successful send must leave no pending retry row")
    }

    func test_rotated_device_response_enqueues_pending_with_active_device_id() async throws {
        SimpleStubURLProtocol.responder = { req in
            if req.httpMethod == "GET", req.url?.path.contains("/keys/message/") == true {
                let body: [String: Any] = [
                    "devices": [[
                        "device_id": "device-OLD", "public_key": "A",
                        "message_pubkey": "B", "enrolled_at": 1,
                    ]]
                ]
                return (try! JSONSerialization.data(withJSONObject: body),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let body: [String: Any] = [
                "error": "device_rotated",
                "active_recipient_device_id": "device-NEW",
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let svc = MessageSendService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey,
            sessionToken: { "token" }, selfUserId: { "self" }
        )
        let outcome = await svc.send(text: "rotate", toUserId: "mom")
        switch outcome {
        case .enqueuedRetry: break
        default: XCTFail("expected enqueuedRetry; got \(outcome)")
        }
        let pending = try store.pendingDue(now: Date(timeIntervalSinceNow: 600))
        XCTAssertEqual(pending.count, 1)
        // The durable row is the pre-created UNSEALED entry (pin=""): on
        // retry OutboxService re-resolves the CURRENT active device rather
        // than trusting the 403's hint (round-15), so the rotation recovers
        // even if the device rotated again in the meantime.
        XCTAssertEqual(pending.first?.pinned_recipient_device_id, "")
        XCTAssertTrue(pending.first?.payload.isEmpty ?? false, "row is unsealed → seal-on-retry")
        XCTAssertNotNil(pending.first?.plaintext_wrapped)
    }

    /// Round-7 regression: the recipient's only device is revoked, so the
    /// snapshot resolve throws `noActiveDevice`. This must NOT fail
    /// permanently (that silently loses the message) — it must enqueue for
    /// retry, because an admin re-enroll publishes a new active device and
    /// the durable row re-resolves it on a later outbox tick.
    func test_noActiveDevice_enqueues_retry_not_permanent() async throws {
        let svc = MessageSendService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey,
            sessionToken: { "token" }, selfUserId: { "self" },
            resolveSnapshot: { userId in
                throw RecipientKeysCache.KeysError.noActiveDevice(userId: userId)
            }
        )
        let outcome = await svc.send(text: "to revoked", toUserId: "mom")
        switch outcome {
        case .enqueuedRetry: break
        default: XCTFail("expected enqueuedRetry; got \(outcome)")
        }
        // The unsealed durable row survives for OutboxService to re-resolve.
        let pending = try store.pendingDue(now: Date(timeIntervalSinceNow: 600))
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending.first?.payload.isEmpty ?? false, "row stays unsealed → seal-on-retry")
    }

    /// Malformed published key material, by contrast, is permanent — no
    /// retry repairs corrupt bytes — and the durable row is dropped.
    func test_malformedPubkey_fails_permanently() async throws {
        let svc = MessageSendService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey,
            sessionToken: { "token" }, selfUserId: { "self" },
            resolveSnapshot: { userId in
                throw RecipientKeysCache.KeysError.malformedPubkey(userId: userId)
            }
        )
        let outcome = await svc.send(text: "to corrupt", toUserId: "mom")
        switch outcome {
        case .failedPermanently: break
        default: XCTFail("expected failedPermanently; got \(outcome)")
        }
        let pending = try store.pendingDue(now: Date(timeIntervalSinceNow: 600))
        XCTAssertEqual(pending.count, 0, "permanent failure drops the durable row")
    }

    /// Round-7 High #1 (cached-stale path): the recipient had an active
    /// device when keys were resolved, but it was revoked before the POST
    /// landed, so the server answers a plain 403 `not_authorized` (no
    /// `active_recipient_device_id`). This must NOT fail permanently — the
    /// recipient may re-enroll; enqueue for retry so the outbox re-resolves.
    func test_403_not_authorized_enqueues_retry_not_permanent() async throws {
        SimpleStubURLProtocol.responder = { req in
            if req.httpMethod == "GET", req.url?.path.contains("/keys/message/") == true {
                let body: [String: Any] = [
                    "devices": [["device_id": "d", "public_key": "A", "message_pubkey": "B", "enrolled_at": 1]]
                ]
                return (try! JSONSerialization.data(withJSONObject: body),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            // Production wire shape: writeErr puts the human message in
            // `error` and the machine code in `reason`.
            let body: [String: Any] = [
                "error": "not authorized: recipient has no active device",
                "reason": "not_authorized",
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        let svc = MessageSendService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey,
            sessionToken: { "token" }, selfUserId: { "self" }
        )
        let outcome = await svc.send(text: "to gone device", toUserId: "mom")
        switch outcome {
        case .enqueuedRetry: break
        default: XCTFail("expected enqueuedRetry; got \(outcome)")
        }
        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 600)).count, 1)
    }

    /// A fully revoked recipient user (server 403 `recipient_revoked`) is a
    /// deliberate, terminal state — fail permanently and drop the row.
    func test_403_recipient_revoked_fails_permanently() async throws {
        SimpleStubURLProtocol.responder = { req in
            if req.httpMethod == "GET", req.url?.path.contains("/keys/message/") == true {
                let body: [String: Any] = [
                    "devices": [["device_id": "d", "public_key": "A", "message_pubkey": "B", "enrolled_at": 1]]
                ]
                return (try! JSONSerialization.data(withJSONObject: body),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let body: [String: Any] = [
                "error": "recipient revoked",
                "reason": "recipient_revoked",
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        let svc = MessageSendService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey,
            sessionToken: { "token" }, selfUserId: { "self" }
        )
        let outcome = await svc.send(text: "to revoked user", toUserId: "mom")
        switch outcome {
        case .failedPermanently: break
        default: XCTFail("expected failedPermanently; got \(outcome)")
        }
        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 600)).count, 0)
    }

    /// Round-7 High #2: a 401 on the KEY-LOOKUP request (not just the POST)
    /// must force a session refresh, mirroring the POST-401 path. Otherwise
    /// a stale token blocks key resolution and the message retries against
    /// the same dead token until maxAttempts drops it.
    func test_401_on_key_lookup_triggers_refresh_and_retry() async throws {
        nonisolated(unsafe) var refreshed = false
        SimpleStubURLProtocol.responder = { req in
            // The keys endpoint 401s (stale token).
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let svc = MessageSendService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey,
            sessionToken: { "token" }, selfUserId: { "self" },
            onAuthFailure: { refreshed = true }
        )
        let outcome = await svc.send(text: "stale token", toUserId: "mom")
        switch outcome {
        case .enqueuedRetry: break
        default: XCTFail("expected enqueuedRetry; got \(outcome)")
        }
        XCTAssertTrue(refreshed, "401 during key lookup must force a session refresh")
        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 600)).count, 1)
    }

    func test_500_enqueues_pending_with_first_attempt() async throws {
        SimpleStubURLProtocol.responder = { req in
            if req.httpMethod == "GET", req.url?.path.contains("/keys/message/") == true {
                let body: [String: Any] = [
                    "devices": [["device_id": "d", "public_key": "A", "message_pubkey": "B", "enrolled_at": 1]]
                ]
                return (try! JSONSerialization.data(withJSONObject: body),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let svc = MessageSendService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey,
            sessionToken: { "token" }, selfUserId: { "self" }
        )
        let outcome = await svc.send(text: "oops", toUserId: "mom")
        if case .enqueuedRetry(_, let attempts) = outcome {
            XCTAssertEqual(attempts, 1)
        } else {
            XCTFail("expected enqueuedRetry; got \(outcome)")
        }
        let pending = try store.pendingDue(now: Date(timeIntervalSinceNow: 600))
        XCTAssertEqual(pending.count, 1)
    }

    func test_400_marks_failed_permanently() async throws {
        SimpleStubURLProtocol.responder = { req in
            if req.httpMethod == "GET", req.url?.path.contains("/keys/message/") == true {
                let body: [String: Any] = [
                    "devices": [["device_id": "d", "public_key": "A", "message_pubkey": "B", "enrolled_at": 1]]
                ]
                return (try! JSONSerialization.data(withJSONObject: body),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let body: [String: Any] = ["error": "malformed"]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let svc = MessageSendService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey,
            sessionToken: { "token" }, selfUserId: { "self" }
        )
        let outcome = await svc.send(text: "bad", toUserId: "mom")
        switch outcome {
        case .failedPermanently(_, let code): XCTAssertEqual(code, 400)
        default: XCTFail("expected failedPermanently; got \(outcome)")
        }
        let pending = try store.pendingDue(now: Date(timeIntervalSinceNow: 600))
        XCTAssertEqual(pending.count, 0)
    }

    /// Round-40 regression: if crypto.seal fails permanently AFTER the durable
    /// unsealed pending row is inserted, that row must be DELETED — otherwise
    /// OutboxService (which seals empty-payload rows on retry) would later send
    /// a message the caller was told permanently failed.
    func test_seal_permanent_failure_clears_pending_row() async throws {
        SimpleStubURLProtocol.responder = { req in
            if req.httpMethod == "GET", req.url?.path.contains("/keys/message/") == true {
                let body: [String: Any] = [
                    "devices": [["device_id": "d", "public_key": "A", "message_pubkey": "B", "enrolled_at": 1]]
                ]
                return (try! JSONSerialization.data(withJSONObject: body),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            // POST should never be reached — seal fails first.
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let svc = MessageSendService(
            store: store, api: api, crypto: SealFailingCryptoService(),
            dbWrapKey: dbWrapKey,
            sessionToken: { "token" }, selfUserId: { "self" }
        )
        let outcome = await svc.send(text: "nope", toUserId: "mom")
        switch outcome {
        case .failedPermanently(_, let code): XCTAssertEqual(code, -2)
        default: XCTFail("expected failedPermanently; got \(outcome)")
        }
        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 9999)).count, 0,
                       "a permanently failed seal must leave no durable retry row to re-send later")
    }

    func test_envelope_round_trip_through_stub_serialization() throws {
        let svc = DebugCryptoService()
        let env = try XCTRunBlocking { try await svc.seal(plaintext: Data("x".utf8), forRecipient: CryptoRecipient(userId: "y")) }
        let bytes = MessageSendService.encodeStubEnvelope(env)
        let decoded = try MessageSendService.decodeStubEnvelope(bytes)
        XCTAssertEqual(decoded.version, env.version)
        XCTAssertEqual(decoded.nonce, env.nonce)
        XCTAssertEqual(decoded.ciphertext, env.ciphertext)
        XCTAssertEqual(decoded.tag, env.tag)
    }

    func test_next_delay_grows_with_attempts() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let d1 = MessageSendService.nextDelay(for: 1, base: base).timeIntervalSince(base)
        let d2 = MessageSendService.nextDelay(for: 2, base: base).timeIntervalSince(base)
        let d3 = MessageSendService.nextDelay(for: 3, base: base).timeIntervalSince(base)
        let d4 = MessageSendService.nextDelay(for: 4, base: base).timeIntervalSince(base)
        // Each tier is materially larger than the previous (jitter is ±10%).
        XCTAssertLessThan(d1, d2)
        XCTAssertLessThan(d2, d3)
        XCTAssertLessThan(d3, d4)
    }
}

/// Crypto stub whose `seal` always fails — exercises the permanent seal-failure
/// path in MessageSendService.send after the durable pending row is inserted.
private final class SealFailingCryptoService: CryptoService, @unchecked Sendable {
    struct SealError: Error {}
    func seal(plaintext: Data, forRecipient: CryptoRecipient, routing: EnvelopeRouting) async throws -> Envelope {
        throw SealError()
    }
    func open(_ envelope: Envelope, fromRecipient: CryptoRecipient, routing: EnvelopeRouting) async throws -> Data {
        throw SealError()
    }
}

/// Tiny helper — XCTestCase doesn't ship a sync-from-async wrapper.
private func XCTRunBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task.detached {
        do {
            let v = try await body()
            result = .success(v)
        } catch {
            result = .failure(error)
        }
        sem.signal()
    }
    sem.wait()
    return try result.get()
}
