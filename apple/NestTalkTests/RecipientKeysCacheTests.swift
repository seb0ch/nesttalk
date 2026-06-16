import XCTest
import CryptoKit
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class RecipientKeysCacheTests: XCTestCase {

    private var api: APIClient!

    override func setUp() async throws {
        try await super.setUp()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SimpleStubURLProtocol.self]
        api = APIClient(baseURL: URL(string: "http://stub.test")!, session: URLSession(configuration: cfg))
    }

    override func tearDown() async throws {
        SimpleStubURLProtocol.responder = nil
        try await super.tearDown()
    }

    private static func keysResponse(pubkey: Data) -> Data {
        let body: [String: Any] = ["devices": [[
            "device_id": "dev-1",
            "public_key": Data(repeating: 1, count: 32).base64EncodedString(),
            "message_pubkey": pubkey.base64EncodedString(),
            "enrolled_at": 1,
        ]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func test_resolves_splits_and_caches_recipient_keys() async throws {
        let blob = Data(repeating: 7, count: 32) + Data(repeating: 9, count: 1184)
        nonisolated(unsafe) var hits = 0
        SimpleStubURLProtocol.responder = { req in
            XCTAssertEqual(req.url?.path, "/api/v1/keys/message/mom-id")
            hits += 1
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Self.keysResponse(pubkey: blob), resp)
        }
        let cache = RecipientKeysCache(api: api, sessionToken: { "t" })

        let first = try await cache.recipient(for: "mom-id")
        XCTAssertEqual(first.x25519Pub, Data(repeating: 7, count: 32))
        XCTAssertEqual(first.mlkemPub, Data(repeating: 9, count: 1184))

        _ = try await cache.recipient(for: "mom-id")
        XCTAssertEqual(hits, 1, "second resolve must come from cache")

        await cache.invalidate(userId: "mom-id")
        _ = try await cache.recipient(for: "mom-id")
        XCTAssertEqual(hits, 2, "invalidate must force a re-fetch")
    }

    func test_malformed_pubkey_throws() async {
        SimpleStubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Self.keysResponse(pubkey: Data(repeating: 7, count: 64)), resp)
        }
        let cache = RecipientKeysCache(api: api, sessionToken: { nil })
        do {
            _ = try await cache.recipient(for: "mom-id")
            XCTFail("expected malformedPubkey")
        } catch let error as RecipientKeysCache.KeysError {
            XCTAssertEqual(error, .malformedPubkey(userId: "mom-id"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Full production-path roundtrip: the decorator resolves Bob's
    /// real pubkeys through the keys endpoint, seals with
    /// HybridCryptoService, and Bob opens with his private bundle —
    /// exactly what AppState.makeCryptoService wires.
    @available(iOS 26.0, macOS 26.0, *)
    func test_keyResolving_hybrid_seal_open_roundtrip() async throws {
        let bobBundle = HybridCryptoService.LocalKeyBundle(
            x25519Private: Curve25519.KeyAgreement.PrivateKey(),
            mlkemPrivate: try MLKEM768.PrivateKey()
        )
        let bobBlob = MessagePubKey.compose(
            x25519: bobBundle.x25519Private.publicKey,
            mlkem: bobBundle.mlkemPrivate.publicKey
        )
        SimpleStubURLProtocol.responder = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Self.keysResponse(pubkey: bobBlob), resp)
        }

        let aliceBundle = HybridCryptoService.LocalKeyBundle(
            x25519Private: Curve25519.KeyAgreement.PrivateKey(),
            mlkemPrivate: try MLKEM768.PrivateKey()
        )
        let alice = KeyResolvingCryptoService(
            inner: HybridCryptoService(bundle: aliceBundle, selfUserId: "alice"),
            keys: RecipientKeysCache(api: api, sessionToken: { "t" })
        )
        let bob = HybridCryptoService(bundle: bobBundle, selfUserId: "bob")

        // Seal with the bare userId recipient the message pipeline uses.
        let sealed = try await alice.seal(
            plaintext: Data("hi bob".utf8),
            forRecipient: CryptoRecipient(userId: "bob")
        )
        // Receiver reconstructs AAD from wire metadata, as
        // MessageReceiveService does.
        let envelopeWithAad = Envelope(
            version: sealed.version,
            senderEphemeralX25519Pub: sealed.senderEphemeralX25519Pub,
            kemCiphertext: sealed.kemCiphertext,
            nonce: sealed.nonce,
            aad: DebugCryptoService.aadFor(senderUserID: "alice", recipientUserID: "bob", version: sealed.version),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
        let opened = try await bob.open(envelopeWithAad, fromRecipient: CryptoRecipient(userId: "alice"))
        XCTAssertEqual(opened, Data("hi bob".utf8))
    }
}

extension RecipientKeysCacheTests {
    /// Sender re-enrollment: a device id we've never seen (the sender
    /// re-enrolled after our first fetch) must trigger a refresh, not a
    /// stale-cache rejection.
    func test_signing_key_refetches_for_unseen_device_after_prior_fetch() async throws {
        nonisolated(unsafe) var fetchCount = 0
        nonisolated(unsafe) var currentDeviceId = "dev-OLD"
        SimpleStubURLProtocol.responder = { req in
            fetchCount += 1
            let body: [String: Any] = ["devices": [[
                "device_id": currentDeviceId,
                "public_key": Data(repeating: 9, count: 32).base64EncodedString(),
                "message_pubkey": Data(repeating: 2, count: 1216).base64EncodedString(),
                "enrolled_at": 1,
            ]]]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let cache = RecipientKeysCache(api: api, sessionToken: { "t" })

        _ = await cache.signingKey(for: "mom-id", deviceId: "dev-OLD")
        XCTAssertEqual(fetchCount, 1)
        // Cache hit — no refetch.
        _ = await cache.signingKey(for: "mom-id", deviceId: "dev-OLD")
        XCTAssertEqual(fetchCount, 1)

        // Sender re-enrolled: new device id. A miss must refetch even
        // though this user was fetched before.
        currentDeviceId = "dev-NEW"
        let result = await cache.signingKey(for: "mom-id", deviceId: "dev-NEW")
        XCTAssertEqual(result, .found(Data(repeating: 9, count: 32)))
        XCTAssertEqual(fetchCount, 2, "unseen device id must trigger a refetch")
    }

    /// A revoked device must never be sealed to. When the server lists a
    /// revoked device ahead of (or instead of) an active one, selection
    /// must skip revoked entries and pick the active device's keys + id.
    func test_skips_revoked_device_and_selects_active() async throws {
        let activeBlob = Data(repeating: 5, count: 32) + Data(repeating: 6, count: 1184)
        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = ["devices": [
                [
                    "device_id": "dev-REVOKED",
                    "public_key": Data(repeating: 1, count: 32).base64EncodedString(),
                    "message_pubkey": Data(repeating: 9, count: 1216).base64EncodedString(),
                    "enrolled_at": 1,
                    "revoked_at": 1_700_000_000,
                ],
                [
                    "device_id": "dev-ACTIVE",
                    "public_key": Data(repeating: 2, count: 32).base64EncodedString(),
                    "message_pubkey": activeBlob.base64EncodedString(),
                    "enrolled_at": 2,
                ],
            ]]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let cache = RecipientKeysCache(api: api, sessionToken: { "t" })

        let recipient = try await cache.recipient(for: "mom-id")
        XCTAssertEqual(recipient.x25519Pub, Data(repeating: 5, count: 32))
        XCTAssertEqual(recipient.mlkemPub, Data(repeating: 6, count: 1184))

        let deviceId = try await cache.activeDeviceId(for: "mom-id")
        XCTAssertEqual(deviceId, "dev-ACTIVE", "must route to the active device, not the revoked one")

        // The revoked device's signing key stays available so messages it
        // signed before revocation still verify.
        let revokedSig = await cache.signingKey(for: "mom-id", deviceId: "dev-REVOKED")
        XCTAssertEqual(revokedSig, .found(Data(repeating: 1, count: 32)))
    }

    /// Single-device user mid-re-enroll: their only device is revoked, so
    /// there is no active target. Selection must throw `noActiveDevice`
    /// (retryable) rather than blindly sealing to the revoked device — a
    /// revoked recipient 403s server-side and the message would be lost.
    /// The revoked device's signing key must still register for verify.
    func test_single_revoked_device_throws_noActiveDevice_but_keeps_signing_key() async throws {
        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = ["devices": [[
                "device_id": "dev-GONE",
                "public_key": Data(repeating: 8, count: 32).base64EncodedString(),
                "message_pubkey": Data(repeating: 9, count: 1216).base64EncodedString(),
                "enrolled_at": 1,
                "revoked_at": 1_700_000_500,
            ]]]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let cache = RecipientKeysCache(api: api, sessionToken: { "t" })

        do {
            _ = try await cache.recipient(for: "mom-id")
            XCTFail("expected noActiveDevice")
        } catch let error as RecipientKeysCache.KeysError {
            XCTAssertEqual(error, .noActiveDevice(userId: "mom-id"))
        } catch {
            XCTFail("unexpected error \(error)")
        }

        // Verify path is preserved even with no active device.
        let sig = await cache.signingKey(for: "mom-id", deviceId: "dev-GONE")
        XCTAssertEqual(sig, .found(Data(repeating: 8, count: 32)))
    }

    /// Cold-cache verify path: the FIRST call for this user is
    /// `signingKey` (not a prior `recipient`/`snapshot`), and the sender's
    /// only device is revoked. `refresh` registers the device's signing key
    /// before it throws `noActiveDevice`, so the key must still be returned
    /// — verification of a message the device signed before revocation must
    /// not degrade to `.lookupFailed` (which would defer/pin it forever).
    func test_signing_key_found_for_revoked_only_device_cold_cache() async {
        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = ["devices": [[
                "device_id": "dev-GONE",
                "public_key": Data(repeating: 4, count: 32).base64EncodedString(),
                "message_pubkey": Data(repeating: 9, count: 1216).base64EncodedString(),
                "enrolled_at": 1,
                "revoked_at": 1_700_000_500,
            ]]]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let cache = RecipientKeysCache(api: api, sessionToken: { "t" })
        let sig = await cache.signingKey(for: "mom-id", deviceId: "dev-GONE")
        XCTAssertEqual(sig, .found(Data(repeating: 4, count: 32)))
    }

    func test_signing_key_deviceUnknown_vs_lookupFailed() async {
        // Fetch succeeds, device absent → deviceUnknown (permanent).
        SimpleStubURLProtocol.responder = { req in
            let body: [String: Any] = ["devices": [[
                "device_id": "dev-A",
                "public_key": Data(repeating: 1, count: 32).base64EncodedString(),
                "message_pubkey": Data(repeating: 2, count: 1216).base64EncodedString(),
                "enrolled_at": 1,
            ]]]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let cache = RecipientKeysCache(api: api, sessionToken: { "t" })
        let unknown = await cache.signingKey(for: "mom-id", deviceId: "dev-GONE")
        XCTAssertEqual(unknown, .deviceUnknown)

        // Fetch fails (5xx) → lookupFailed (transient).
        SimpleStubURLProtocol.responder = { req in
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let cache2 = RecipientKeysCache(api: api, sessionToken: { "t" })
        let failed = await cache2.signingKey(for: "other-id", deviceId: "dev-X")
        XCTAssertEqual(failed, .lookupFailed)
    }
}
