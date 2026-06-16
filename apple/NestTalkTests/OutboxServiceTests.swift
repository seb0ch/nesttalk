import XCTest
import CryptoKit
import GRDB
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class OutboxServiceTests: XCTestCase {

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

    func test_v2_migration_adds_pending_columns_and_local_id() throws {
        let cols: Set<String> = try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(pending_queue)")
            return Set(rows.compactMap { $0["name"] as String? })
        }
        XCTAssertTrue(cols.contains("recipient_user_id"))
        XCTAssertTrue(cols.contains("pinned_recipient_device_id"))
        XCTAssertTrue(cols.contains("message_id"))
        XCTAssertTrue(cols.contains("plaintext_wrapped"))

        let messageCols: Set<String> = try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(messages)")
            return Set(rows.compactMap { $0["name"] as String? })
        }
        XCTAssertTrue(messageCols.contains("local_id"))
    }

    func test_plaintext_wrap_round_trip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("retry me".utf8)
        let wrapped = try PlaintextWrap.seal(plaintext, using: key)
        XCTAssertNotEqual(wrapped, plaintext)
        let opened = try PlaintextWrap.open(wrapped, using: key)
        XCTAssertEqual(opened, plaintext)

        let wrong = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try PlaintextWrap.open(wrapped, using: wrong))
    }

    func test_successful_retry_clears_pending_and_marks_message_sent() async throws {
        // Seed a pending row by hand.
        let localId = "local-1"
        let plaintext = Data("queued".utf8)
        let wrapped = try PlaintextWrap.seal(plaintext, using: dbWrapKey)
        try store.insert(MessageStore.Message(
            id: localId, threadUserId: "mom", outgoing: true,
            plaintext: "queued", state: "failed", sentAt: Date(),
            localId: localId
        ))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: localId, payload: Data([0xCA, 0xFE]),
            attempts: 1, nextRetryAt: Date(timeIntervalSinceNow: -10),
            recipientUserId: "mom",
            pinnedRecipientDeviceId: "device-A",
            messageId: localId,
            plaintextWrapped: wrapped
        ))

        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = [
                "id": "server-OK",
                "received_at": 1_700_000_000_000, "sent_at": 1_700_000_000_000,
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }

        let outbox = OutboxService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey, sessionToken: { "tok" }
        )
        let results = await outbox.tick()
        XCTAssertEqual(results.count, 1)

        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 9999)).count, 0)
        let row = try XCTUnwrap(store.message(serverId: "server-OK"))
        XCTAssertEqual(row.state, "sent_to_server")
    }

    func test_device_rotation_reseals_with_new_recipient() async throws {
        let localId = "local-rot"
        let plaintext = Data("rotate".utf8)
        let wrapped = try PlaintextWrap.seal(plaintext, using: dbWrapKey)
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_700_000_000)
        try store.insert(MessageStore.Message(
            id: localId, threadUserId: "mom", outgoing: true,
            plaintext: "rotate", state: "failed", sentAt: clock,
            localId: localId
        ))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: localId, payload: Data([0xAA]),
            attempts: 1, nextRetryAt: clock.addingTimeInterval(-10),
            recipientUserId: "mom",
            pinnedRecipientDeviceId: "device-OLD",
            messageId: localId,
            plaintextWrapped: wrapped
        ))

        // First call returns 403 with new device, second call returns 200.
        nonisolated(unsafe) var calls = 0
        SimpleStubURLProtocol.responder = { req in
            calls += 1
            if calls == 1 {
                let body: [String: Any] = [
                    "error": "device_rotated",
                    "active_recipient_device_id": "device-NEW",
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
                return (data, resp)
            } else {
                let body: [String: Any] = [
                    "id": "server-RESEALED",
                    "received_at": 1_700_000_000_000, "sent_at": 1_700_000_000_000,
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, resp)
            }
        }

        // Outbox uses an injectable clock so the second tick can advance
        // past the first tick's backoff schedule.
        let outbox = OutboxService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey, sessionToken: { "tok" },
            resolveActiveDeviceForRetry: { uid in
                XCTAssertEqual(uid, "mom")
                return (recipient: CryptoRecipient(userId: uid), deviceId: "device-NEW")
            },
            now: { clock }
        )
        // First tick: rotates + reseals + persists with bumped attempts.
        _ = await outbox.tick()
        let pending = try store.pendingDue(now: clock.addingTimeInterval(9999))
        XCTAssertEqual(pending.first?.pinned_recipient_device_id, "device-NEW")

        // Advance clock past the backoff schedule so the row is due,
        // then tick again. Second responder branch returns 200.
        clock = clock.addingTimeInterval(9999)
        _ = await outbox.tick()
        XCTAssertEqual(try store.pendingDue(now: clock.addingTimeInterval(9999)).count, 0)
    }

    /// Round-12 regression: a send that couldn't resolve recipient keys
    /// enqueues UNSEALED (empty payload + wrapped plaintext). On retry the
    /// outbox must resolve keys, seal from the wrapped plaintext, POST a
    /// real wire envelope, and lift the message — never POST the empty
    /// payload.
    func test_unsealed_row_seals_from_wrapped_plaintext_on_retry() async throws {
        let localId = "local-unsealed"
        let plaintext = Data("seal me late".utf8)
        let wrapped = try PlaintextWrap.seal(plaintext, using: dbWrapKey)
        try store.insert(MessageStore.Message(
            id: localId, threadUserId: "mom", outgoing: true,
            plaintext: "seal me late", state: "failed", sentAt: Date(),
            localId: localId
        ))
        // Empty payload signals "never sealed".
        try store.enqueuePending(MessageStore.PendingMessage(
            id: localId, payload: Data(),
            attempts: 0, nextRetryAt: Date(timeIntervalSinceNow: -10),
            recipientUserId: "mom",
            pinnedRecipientDeviceId: "",
            messageId: localId,
            plaintextWrapped: wrapped
        ))

        nonisolated(unsafe) var postCount = 0
        SimpleStubURLProtocol.responder = { req in
            postCount += 1
            let respBody: [String: Any] = [
                "id": "server-SEALED",
                "received_at": 1_700_000_000_000, "sent_at": 1_700_000_000_000,
            ]
            let data = try! JSONSerialization.data(withJSONObject: respBody)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }

        let outbox = OutboxService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey, sessionToken: { "tok" },
            resolveActiveDeviceForRetry: { uid in
                XCTAssertEqual(uid, "mom")
                return (recipient: CryptoRecipient(userId: uid), deviceId: "device-A")
            },
            selfUserId: { "11111111-1111-1111-1111-111111111111" },
            selfDeviceId: { "22222222-2222-2222-2222-222222222222" }
        )
        _ = await outbox.tick()

        // Pending cleared, message lifted.
        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 9999)).count, 0)
        let row = try XCTUnwrap(store.message(serverId: "server-SEALED"))
        XCTAssertEqual(row.state, "sent_to_server")
        XCTAssertEqual(postCount, 1, "unsealed row should seal then POST exactly once")
    }

    /// Round-15 regression: when a SECOND rotation happens between the 403
    /// response and the snapshot fetch, the 403's active_recipient_device_id
    /// is already stale. Re-seal must bind to the device the snapshot
    /// resolved (snap.deviceId), NOT the 403 hint — otherwise ciphertext is
    /// sealed for one device while the signed header names another and the
    /// server rejects it again.
    func test_rotation_binds_to_snapshot_device_not_403_hint() async throws {
        let localId = "local-rot2"
        let wrapped = try PlaintextWrap.seal(Data("rotate".utf8), using: dbWrapKey)
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_700_000_000)
        try store.insert(MessageStore.Message(
            id: localId, threadUserId: "mom", outgoing: true,
            plaintext: "rotate", state: "failed", sentAt: clock, localId: localId))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: localId, payload: Data([0xAA]),
            attempts: 1, nextRetryAt: clock.addingTimeInterval(-10),
            recipientUserId: "mom", pinnedRecipientDeviceId: "device-OLD",
            messageId: localId, plaintextWrapped: wrapped))

        SimpleStubURLProtocol.responder = { req in
            // The 403 reports a device that is ALREADY stale by the time the
            // resolver runs.
            let body: [String: Any] = [
                "error": "device_rotated",
                "active_recipient_device_id": "device-FROM-403-STALE",
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }

        let outbox = OutboxService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey, sessionToken: { "tok" },
            resolveActiveDeviceForRetry: { uid in
                // The authoritative, current device differs from the 403 hint.
                return (recipient: CryptoRecipient(userId: uid), deviceId: "device-FROM-SNAPSHOT")
            },
            selfUserId: { "11111111-1111-1111-1111-111111111111" },
            selfDeviceId: { "22222222-2222-2222-2222-222222222222" },
            now: { clock }
        )
        _ = await outbox.tick()

        let pending = try store.pendingDue(now: clock.addingTimeInterval(9999))
        XCTAssertEqual(pending.first?.pinned_recipient_device_id, "device-FROM-SNAPSHOT",
                       "re-seal must pin the snapshot device, not the stale 403 hint")
    }

    /// Round-18 regression: a 401 (token invalidated by a server restore,
    /// refresh async) must NOT delete the durable outbox row — it retains
    /// and retries. And the retry must reuse the ORIGINAL sent_at /
    /// reply_to_id, never re-stamp with now()/nil.
    func test_401_retains_row_and_reuses_original_metadata() async throws {
        let localId = "local-401"
        let wrapped = try PlaintextWrap.seal(Data("hi".utf8), using: dbWrapKey)
        let originalSent = Date(timeIntervalSince1970: 1_700_000_000)
        try store.insert(MessageStore.Message(
            id: localId, threadUserId: "mom", outgoing: true,
            plaintext: "hi", state: "failed", sentAt: originalSent, localId: localId))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: localId, payload: Data([0xCA, 0xFE]),
            attempts: 1, nextRetryAt: Date(timeIntervalSince1970: 1_700_000_000),
            recipientUserId: "mom", pinnedRecipientDeviceId: "device-A",
            messageId: localId, plaintextWrapped: wrapped,
            originalSentAt: originalSent, replyToId: "parent-msg-7"))

        nonisolated(unsafe) var failAuth = true
        nonisolated(unsafe) var capturedSentAt: Int64?
        nonisolated(unsafe) var capturedReplyTo: String?
        SimpleStubURLProtocol.responder = { req in
            if failAuth {
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            if let body = req.httpBody ?? req.httpBodyStream.map(Self.drain),
               let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedSentAt = (obj["sent_at"] as? NSNumber)?.int64Value
                capturedReplyTo = obj["reply_to_id"] as? String
            }
            let data = try! JSONSerialization.data(withJSONObject: [
                "id": "server-OK", "received_at": 1, "sent_at": 1])
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_700_000_100)
        let outbox = OutboxService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey, sessionToken: { "tok" }, now: { clock })

        // Phase 1: 401 → row retained (NOT deleted).
        _ = await outbox.tick()
        XCTAssertEqual(try store.pendingDue(now: clock.addingTimeInterval(9999)).count, 1,
                       "401 must retain the outbox row")
        XCTAssertNotEqual(try store.message(id: localId)?.state, "failed_permanently")

        // Phase 2: advance past the auth backoff, auth recovers → row clears.
        clock = clock.addingTimeInterval(9999)
        failAuth = false
        _ = await outbox.tick()
        XCTAssertEqual(try store.pendingDue(now: clock.addingTimeInterval(9999)).count, 0)
        XCTAssertEqual(capturedReplyTo, "parent-msg-7", "retry must preserve the reply target")
        XCTAssertEqual(capturedSentAt, Int64(originalSent.timeIntervalSince1970 * 1000),
                       "retry must reuse the original sent_at")
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }

    func test_max_attempts_marks_message_permanent() async throws {
        let localId = "local-X"
        try store.insert(MessageStore.Message(
            id: localId, threadUserId: "mom", outgoing: true,
            plaintext: "x", state: "failed", sentAt: Date(),
            localId: localId
        ))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: localId, payload: Data(),
            attempts: OutboxService.maxAttempts - 1,
            nextRetryAt: Date(timeIntervalSinceNow: -10),
            recipientUserId: "mom", messageId: localId
        ))

        SimpleStubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let outbox = OutboxService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey, sessionToken: { nil }
        )
        _ = await outbox.tick()

        let row = try XCTUnwrap(store.message(id: localId))
        XCTAssertEqual(row.state, "failed_permanently")
        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 9999)).count, 0)
    }

    /// Round-58 regression: same-user re-enrollment rotates OUR sender device
    /// id, but a pending row sealed under the OLD device survives in the local
    /// DB. The server rejects it with a generic 403 not_authorized (no
    /// recipient-device hint, so NOT a recipient-rotation 403). The body is
    /// recoverable via plaintext_wrapped, so the outbox must re-seal + re-sign
    /// under the CURRENT device instead of discarding the message.
    func test_reenroll_stale_sender_device_reseals_not_dropped() async throws {
        let localId = "local-reenroll"
        let oldDeviceId = "11111111-1111-1111-1111-111111111111"
        let newDeviceId = "22222222-2222-2222-2222-222222222222"
        let selfUser = "33333333-3333-3333-3333-333333333333"
        let recipientDev = "44444444-4444-4444-4444-444444444444"

        let wrapped = try PlaintextWrap.seal(Data("see you at 9".utf8), using: dbWrapKey)
        // A REAL wire envelope signed under the OLD (pre-re-enroll) device id.
        let stalePayload = try WireEnvelope.encode(
            senderUserId: selfUser,
            senderDeviceId: oldDeviceId,
            recipientUserId: "mom",
            recipientDeviceId: recipientDev,
            messageId: localId,
            senderEphemeralX25519Pub: Data(count: 32),
            kemCiphertext: Data(count: 1088),
            nonce: Data(count: 12),
            ciphertextWithTag: Data(count: 64)
        )

        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_700_000_000)
        try store.insert(MessageStore.Message(
            id: localId, threadUserId: "mom", outgoing: true,
            plaintext: "see you at 9", state: "failed", sentAt: clock, localId: localId))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: localId, payload: stalePayload,
            attempts: 1, nextRetryAt: clock.addingTimeInterval(-10),
            recipientUserId: "mom", pinnedRecipientDeviceId: oldDeviceId,
            messageId: localId, plaintextWrapped: wrapped))

        // First POST: generic 403 not_authorized (no active_recipient_device_id,
        // so it maps to http(403), not recipientDeviceRotated). Second POST: 200.
        nonisolated(unsafe) var calls = 0
        SimpleStubURLProtocol.responder = { req in
            calls += 1
            if calls == 1 {
                // Production wire shape: code in `reason`, human msg in `error`.
                let data = try! JSONSerialization.data(withJSONObject: [
                    "error": "not authorized: sender device revoked", "reason": "not_authorized"])
                return (data, HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
            let data = try! JSONSerialization.data(withJSONObject: [
                "id": "server-RESEALED", "received_at": 1_700_000_000_000, "sent_at": 1_700_000_000_000])
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let outbox = OutboxService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey, sessionToken: { "tok" },
            resolveActiveDeviceForRetry: { uid in
                (recipient: CryptoRecipient(userId: uid), deviceId: recipientDev)
            },
            selfUserId: { selfUser },
            selfDeviceId: { newDeviceId },
            now: { clock })

        // First tick: the stale-sender 403 must NOT delete the row — it
        // re-seals under the current device and reschedules.
        _ = await outbox.tick()
        let afterFirst = try store.pendingDue(now: clock.addingTimeInterval(9999))
        XCTAssertEqual(afterFirst.count, 1, "stale-sender 403 must retain the recoverable row, not drop it")
        let resealed = try XCTUnwrap(afterFirst.first)
        let parsed = try WireEnvelope.parse(resealed.payload)
        XCTAssertEqual(parsed.senderDeviceId, newDeviceId, "row must be re-sealed under the current device id")
        let state = try store.message(id: localId)?.state
        XCTAssertNotEqual(state, "failed_permanently", "recoverable row must not be marked permanently failed")

        // Second tick (after backoff): the re-sealed envelope is accepted.
        clock = clock.addingTimeInterval(9999)
        _ = await outbox.tick()
        XCTAssertEqual(try store.pendingDue(now: clock.addingTimeInterval(9999)).count, 0,
                       "re-sealed message must send and clear on the next attempt")
    }

    /// Round-7 High #1 (outbox, recipient-side): a sealed row signed by the
    /// CURRENT sender device (so NOT a stale-sender case) gets a generic 403
    /// not_authorized because the RECIPIENT lost its active device mid-flight.
    /// This must re-seal/recover rather than drop — the recipient may re-enroll.
    func test_recipient_not_authorized_reseals_not_dropped() async throws {
        let localId = "local-recipient-gone"
        let selfUser = "33333333-3333-3333-3333-333333333333"
        let curDevice = "22222222-2222-2222-2222-222222222222"
        let oldRecipientDev = "44444444-4444-4444-4444-444444444444"
        let newRecipientDev = "55555555-5555-5555-5555-555555555555"

        let wrapped = try PlaintextWrap.seal(Data("you up?".utf8), using: dbWrapKey)
        // Payload signed under the CURRENT sender device → sealedUnderStaleSenderDevice is false.
        let payload = try WireEnvelope.encode(
            senderUserId: selfUser,
            senderDeviceId: curDevice,
            recipientUserId: "mom",
            recipientDeviceId: oldRecipientDev,
            messageId: localId,
            senderEphemeralX25519Pub: Data(count: 32),
            kemCiphertext: Data(count: 1088),
            nonce: Data(count: 12),
            ciphertextWithTag: Data(count: 64)
        )

        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_700_000_000)
        try store.insert(MessageStore.Message(
            id: localId, threadUserId: "mom", outgoing: true,
            plaintext: "you up?", state: "failed", sentAt: clock, localId: localId))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: localId, payload: payload,
            attempts: 1, nextRetryAt: clock.addingTimeInterval(-10),
            recipientUserId: "mom", pinnedRecipientDeviceId: oldRecipientDev,
            messageId: localId, plaintextWrapped: wrapped))

        nonisolated(unsafe) var calls = 0
        SimpleStubURLProtocol.responder = { req in
            calls += 1
            if calls == 1 {
                // Production wire shape: code in `reason`, human msg in `error`.
                let data = try! JSONSerialization.data(withJSONObject: [
                    "error": "not authorized: recipient has no active device", "reason": "not_authorized"])
                return (data, HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
            let data = try! JSONSerialization.data(withJSONObject: [
                "id": "server-RECOVERED", "received_at": 1_700_000_000_000, "sent_at": 1_700_000_000_000])
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let outbox = OutboxService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey, sessionToken: { "tok" },
            resolveActiveDeviceForRetry: { uid in
                // Recipient re-enrolled to a new device.
                (recipient: CryptoRecipient(userId: uid), deviceId: newRecipientDev)
            },
            selfUserId: { selfUser },
            selfDeviceId: { curDevice },
            now: { clock })

        _ = await outbox.tick()
        let afterFirst = try store.pendingDue(now: clock.addingTimeInterval(9999))
        XCTAssertEqual(afterFirst.count, 1, "recipient not_authorized must retain the recoverable row, not drop it")
        XCTAssertNotEqual(try store.message(id: localId)?.state, "failed_permanently")

        clock = clock.addingTimeInterval(9999)
        _ = await outbox.tick()
        XCTAssertEqual(try store.pendingDue(now: clock.addingTimeInterval(9999)).count, 0,
                       "re-sealed message must send and clear once the recipient re-enrolls")
    }

    /// Round-59 design-review fix: a 401 from the outbox must trigger a session
    /// refresh (mirroring receive/read/call), not just reschedule — otherwise
    /// outgoing sends keep retrying the stale token until an unrelated path
    /// refreshes. The row is retained for retry after the refresh.
    func test_401_triggers_session_refresh() async throws {
        let localId = "local-401-refresh"
        let wrapped = try PlaintextWrap.seal(Data("hi".utf8), using: dbWrapKey)
        try store.insert(MessageStore.Message(
            id: localId, threadUserId: "mom", outgoing: true,
            plaintext: "hi", state: "failed", sentAt: Date(), localId: localId))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: localId, payload: Data([0xCA, 0xFE]),
            attempts: 1, nextRetryAt: Date(timeIntervalSince1970: 1_700_000_000),
            recipientUserId: "mom", pinnedRecipientDeviceId: "device-A",
            messageId: localId, plaintextWrapped: wrapped))

        SimpleStubURLProtocol.responder = { req in
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let refreshes = AuthRefreshCounter()
        let outbox = OutboxService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey, sessionToken: { "tok" },
            onAuthFailure: { await refreshes.bump() })

        _ = await outbox.tick()

        let count = await refreshes.value()
        XCTAssertEqual(count, 1, "a 401 from the outbox must trigger a session refresh")
        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 9999)).count, 1,
                       "the row must be retained for retry after the refresh")
    }

    /// Round-8 Medium: a 403 not_authorized that NEVER clears (recipient
    /// never re-enrolls) routes through handleRotation, which must still
    /// honor maxAttempts and converge to permanent failure rather than
    /// re-sealing forever.
    func test_persistent_not_authorized_converges_to_permanent() async throws {
        let localId = "local-persistent-403"
        let selfUser = "33333333-3333-3333-3333-333333333333"
        let curDevice = "22222222-2222-2222-2222-222222222222"
        let recipientDev = "44444444-4444-4444-4444-444444444444"
        let wrapped = try PlaintextWrap.seal(Data("hello?".utf8), using: dbWrapKey)
        let payload = try WireEnvelope.encode(
            senderUserId: selfUser, senderDeviceId: curDevice,
            recipientUserId: "mom", recipientDeviceId: recipientDev, messageId: localId,
            senderEphemeralX25519Pub: Data(count: 32), kemCiphertext: Data(count: 1088),
            nonce: Data(count: 12), ciphertextWithTag: Data(count: 64))

        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_700_000_000)
        try store.insert(MessageStore.Message(
            id: localId, threadUserId: "mom", outgoing: true,
            plaintext: "hello?", state: "failed", sentAt: clock, localId: localId))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: localId, payload: payload, attempts: 1, nextRetryAt: clock.addingTimeInterval(-10),
            recipientUserId: "mom", pinnedRecipientDeviceId: recipientDev,
            messageId: localId, plaintextWrapped: wrapped))

        SimpleStubURLProtocol.responder = { req in
            let data = try! JSONSerialization.data(withJSONObject: [
                "error": "not authorized: recipient has no active device", "reason": "not_authorized"])
            return (data, HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        let outbox = OutboxService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey, sessionToken: { "tok" },
            resolveActiveDeviceForRetry: { uid in (recipient: CryptoRecipient(userId: uid), deviceId: recipientDev) },
            selfUserId: { selfUser }, selfDeviceId: { curDevice }, now: { clock })

        var remaining = 1
        for _ in 0..<12 {
            _ = await outbox.tick()
            clock = clock.addingTimeInterval(9999)
            remaining = try store.pendingDue(now: clock.addingTimeInterval(9999)).count
            if remaining == 0 { break }
        }
        XCTAssertEqual(remaining, 0, "persistent not_authorized must converge to permanent, not loop forever")
        XCTAssertEqual(try store.message(id: localId)?.state, "failed_permanently")
    }

    /// Round-8 Medium: a 401 raised while RESOLVING recipient keys (not on
    /// the POST) must trigger a refresh AND reschedule without counting
    /// toward maxAttempts — auth failures are transient and must not consume
    /// the permanent-failure budget.
    func test_resolver_401_reschedules_without_counting_attempts() async throws {
        let localId = "local-resolver-401"
        let wrapped = try PlaintextWrap.seal(Data("hi".utf8), using: dbWrapKey)
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_700_000_000)
        try store.insert(MessageStore.Message(
            id: localId, threadUserId: "mom", outgoing: true,
            plaintext: "hi", state: "failed", sentAt: clock, localId: localId))
        // UNSEALED row → sealUnsealedRow → resolver is invoked.
        try store.enqueuePending(MessageStore.PendingMessage(
            id: localId, payload: Data(), attempts: 1, nextRetryAt: clock.addingTimeInterval(-10),
            recipientUserId: "mom", pinnedRecipientDeviceId: "",
            messageId: localId, plaintextWrapped: wrapped))

        SimpleStubURLProtocol.responder = { req in
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let refreshes = AuthRefreshCounter()
        let outbox = OutboxService(
            store: store, api: api, crypto: DebugCryptoService(),
            dbWrapKey: dbWrapKey, sessionToken: { "tok" },
            resolveActiveDeviceForRetry: { _ in throw APIClient.SendError.http(code: 401, body: nil) },
            selfUserId: { "self" }, selfDeviceId: { "dev" },
            onAuthFailure: { await refreshes.bump() },
            now: { clock })

        _ = await outbox.tick()

        let refreshCount = await refreshes.value()
        XCTAssertEqual(refreshCount, 1, "resolver 401 must trigger a session refresh")
        let rows = try store.pendingDue(now: clock.addingTimeInterval(9999))
        XCTAssertEqual(rows.count, 1, "row retained after auth refresh")
        XCTAssertEqual(rows.first?.attempts, 1, "auth failure must NOT increment the permanent-failure counter")
    }
}

/// Thread-safe counter for the async onAuthFailure callback.
private actor AuthRefreshCounter {
    private var n = 0
    func bump() { n += 1 }
    func value() -> Int { n }
}
