import Foundation
import CryptoKit
import SwiftUI

/// Top-level app phase. Drives `AppRouter`'s view selection.
public enum AppPhase: Equatable {
    case bootstrapping
    case onboarding
    /// Persisted identity exists; running `SessionService.connect` to
    /// obtain a fresh bearer token + bringing up the REALITY tunnel.
    /// AppRouter shows a "Connecting…" splash so the UI doesn't feel
    /// frozen while the multi-second handshake completes.
    case connecting
    case connected(EnrolledIdentity)
    case error(String)
}

/// Single source of truth for the running session.
///
/// Owned by `NestTalkApp` and injected as `@EnvironmentObject` so any view
/// can transition between phases (e.g., onboarding completion, sign-out,
/// session-token expiry surfaced from the API client).
@MainActor
public final class AppState: ObservableObject {
    @Published public var phase: AppPhase = .bootstrapping
    @Published public var messageStore: MessageStore?
    @Published public var messageSendService: MessageSendService?
    @Published public var messageReceiveService: MessageReceiveService?
    @Published public var callCoordinator: CallCoordinator?
    @Published public var reactionService: ReactionService?
    public var readReceiptService: ReadReceiptService?
    public var typingService: TypingService?
    /// Inbound typing state for the UI — lives for the whole app
    /// session (views capture it once); only fed while the WS pump runs.
    public let typingObserver = TypingObserver()
    public var controlWebSocket: ControlWebSocket?
    private var callSignaling: RestCallSignaling?
    private var outboxService: OutboxService?
    private var wsPumpTask: Task<Void, Never>?

    /// Bumped on every transition into `.bootstrapping` so AppRouter's
    /// `.task(id:)` re-runs bootstrap. Wraps to UInt32 (any change is
    /// what `.task(id:)` cares about, not magnitude).
    @Published public var bootstrapNonce: UInt32 = 0

    public init() {}

    public func transition(to phase: AppPhase) {
        if case .bootstrapping = phase {
            bootstrapNonce &+= 1
        }
        self.phase = phase
    }

    public enum CryptoBringUpError: Error, CustomStringConvertible {
        case messageKeysUnavailable(String)
        public var description: String {
            switch self {
            case .messageKeysUnavailable(let detail):
                return "device message keys unavailable — re-enroll required (\(detail))"
            }
        }
    }

    /// Production crypto: `HybridCryptoService` over the device's
    /// X25519 + ML-KEM-768 private keys, recipient pubkeys resolved
    /// through `/api/v1/keys/message/{userId}` via `RecipientKeysCache`.
    /// DEBUG builds fall back to the zero-key stub when the device
    /// bundle is missing (the `dev.spike_force_connected` fake-session
    /// path); Release refuses to come up instead — failing loudly beats
    /// shipping stub-grade envelopes.
    static func makeCryptoService(
        selfUserId: String,
        device: DeviceIdentity?,
        keys: RecipientKeysCache
    ) throws -> CryptoService {
        if #available(iOS 26.0, macOS 26.0, *),
           let device,
           let bundle = try? device.messageKeyBundle() {
            return KeyResolvingCryptoService(
                inner: HybridCryptoService(bundle: bundle, selfUserId: selfUserId),
                keys: keys
            )
        }
        #if DEBUG
        NTLogger.crypto.error("messaging crypto: DebugCryptoService fallback (no device message keys)")
        return DebugCryptoService(selfUserId: selfUserId)
        #else
        throw CryptoBringUpError.messageKeysUnavailable("missing X25519/ML-KEM keys or OS < 26")
        #endif
    }

    /// Initialize the message-history store + send pipeline for a
    /// connected session. Called from AppRouter once identity is loaded
    /// and `SessionService.connect` has issued a session token.
    ///
    /// `sessionTokenProvider` is invoked on every outbound HTTP request
    /// — a single source of truth lets `SessionRefresher` slip in a
    /// freshly-rotated token without touching individual services.
    /// `device` carries the long-term message keys; nil only on the
    /// DEBUG fake-session path.
    public func bringUpMessagingStack(
        identity: EnrolledIdentity,
        device: DeviceIdentity?,
        wrapKey: SymmetricKey,
        api: APIClient,
        sessionTokenProvider: @escaping @Sendable () -> String?,
        onSessionInvalidated: (@Sendable () async -> Void)? = nil,
        turnLocalURL: String? = nil
    ) throws {
        let storePath = try Self.messageStorePath(userId: identity.userId)
        let store = try MessageStore(path: storePath, wrapKey: wrapKey)
        let keysCache = RecipientKeysCache(api: api, sessionToken: sessionTokenProvider)
        // Envelope authenticity (v0.2.3 contract): outbound envelopes
        // are signed with the device Ed25519 key; inbound signatures
        // verify against the sender's enrolled key from the keys cache.
        let signer: ((Data) throws -> Data)? = device.map { d in { data in try d.sign(data) } }
        let senderSigningKey: (@Sendable (String, String) async -> RecipientKeysCache.SigningKeyResult) = { [weak keysCache] uid, deviceId in
            guard let keysCache else { return .lookupFailed }
            return await keysCache.signingKey(for: uid, deviceId: deviceId)
        }
        // Atomic {keys, deviceId} snapshot so sealing and wire routing
        // use the exact same rotation — no straddle between the two.
        let resolveSnapshot: ((String) async throws -> (recipient: CryptoRecipient, deviceId: String)) = { [keysCache] uid in
            try await keysCache.snapshot(for: uid)
        }
        let crypto = try Self.makeCryptoService(
            selfUserId: identity.userId,
            device: device,
            keys: keysCache
        )
        self.messageStore = store
        self.messageSendService = MessageSendService(
            store: store, api: api, crypto: crypto, dbWrapKey: wrapKey,
            sessionToken: sessionTokenProvider,
            selfUserId: { identity.userId },
            selfDeviceId: { identity.deviceId },
            signEnvelope: signer,
            resolveSnapshot: resolveSnapshot,
            onAuthFailure: onSessionInvalidated
        )
        let receive = MessageReceiveService(
            store: store, api: api, crypto: crypto,
            sessionToken: sessionTokenProvider,
            selfUserId: { identity.userId },
            senderSigningKey: senderSigningKey,
            // A 401 during catch-up (cold launch after a missed server
            // restore) re-handshakes immediately instead of waiting out the
            // token TTL.
            onAuthFailure: onSessionInvalidated
        )
        self.messageReceiveService = receive

        // Offline-retry pump. On device rotation the resolver drops the
        // cached keys and re-fetches so the re-seal targets the new
        // device.
        let outbox = OutboxService(
            store: store, api: api, crypto: crypto, dbWrapKey: wrapKey,
            sessionToken: sessionTokenProvider,
            resolveActiveDeviceForRetry: { [weak keysCache] userId in
                guard let keysCache else { return nil }
                await keysCache.invalidate(userId: userId)
                // Propagate throws (incl. a 401 stale-token from the keys
                // endpoint). OutboxService.resolveForRetry distinguishes a 401
                // (refresh + reschedule WITHOUT counting toward maxAttempts)
                // from a no-active-device throw (bounded retry).
                return try await keysCache.snapshot(for: userId)
            },
            selfUserId: { identity.userId },
            selfDeviceId: { identity.deviceId },
            signEnvelope: signer,
            onAuthFailure: onSessionInvalidated
        )
        self.outboxService = outbox
        Task { await outbox.start() }

        // Read receipts + reactions.
        let receipts = ReadReceiptService(store: store, api: api, sessionToken: sessionTokenProvider,
                                          onAuthFailure: onSessionInvalidated)
        self.readReceiptService = receipts
        let reactions = ReactionService(
            store: store, api: api, crypto: crypto,
            sessionToken: sessionTokenProvider,
            selfUserId: { identity.userId },
            selfDeviceId: { identity.deviceId },
            invalidateKeys: { [weak keysCache] uid in
                await keysCache?.invalidate(userId: uid)
            },
            signEnvelope: signer,
            senderSigningKey: senderSigningKey,
            resolveSnapshot: resolveSnapshot
        )
        self.reactionService = reactions

        // ControlWebSocket — inbound `.messageIncoming` events fan out
        // to MessageReceiveService.handleEvent, which decrypts +
        // inserts + acks. Plus a status-stream watcher: every time
        // the socket transitions to `.connected` we run catchUp to
        // drain anything the server spooled while we were offline.
        //
        // The WS reads the bearer fresh on every reconnect via the
        // shared `sessionTokenProvider`, so SessionRefresher rotations
        // land in the next handshake without a tear-down here.
        let ws = ControlWebSocket(baseURL: api.baseURL, tokenProvider: sessionTokenProvider)
        self.controlWebSocket = ws

        // Outbound typing — debounced frames over the same socket.
        // Typing is best-effort: the delivery result is ignored.
        self.typingService = TypingService(send: { [weak ws] frame in _ = await ws?.send(frame) })

        // Call stack — signaling funnels WS call events to the
        // coordinator; outbound offer/answer/ICE payloads ship back
        // through the same socket.
        let signaling = RestCallSignaling(
            api: api,
            sessionToken: sessionTokenProvider,
            sendFrame: { [weak ws] frame in await ws?.send(frame) ?? false }
        )
        self.callSignaling = signaling
        let coordinator = CallCoordinator(
            signaling: signaling,
            displayNameResolver: { [weak store] uid in
                guard let store, let users = try? store.allUsers() else { return uid }
                return users.first(where: { $0.user_id == uid })?.display_name ?? uid
            },
            localTurnURL: turnLocalURL
        )
        // Refresh the session on a 401 from a terminal call action so its
        // durable retry can complete with a fresh token instead of abandoning
        // the server row (same hook the messaging stack uses).
        coordinator.onAuthFailure = onSessionInvalidated
        self.callCoordinator = coordinator
        coordinator.start()

        wsPumpTask?.cancel()
        let typingObserver = self.typingObserver
        wsPumpTask = Task { [weak self] in
            // Subscribe BEFORE the socket starts: the server replays
            // queued call signals during WS registration, and the
            // socket buffers only what arrives before a subscriber
            // exists — installing the streams first removes the race
            // entirely instead of leaning on the buffer.
            let eventStream = await ws.events()
            let statusStream = await ws.status()
            await ws.start()
            async let eventsTask: () = {
                for await event in eventStream {
                    await receive.handleEvent(event)
                    await signaling.ingest(event)
                    await typingObserver.ingest(event)
                    switch event {
                    case .messageDelivered(let serverId):
                        await receipts.ingestPeerDelivered(serverId: serverId)
                    case .messageRead(let serverId):
                        await receipts.ingestPeerRead(serverId: serverId)
                    case .reactionUpdate(let messageId, _, let senderUserId, let envelopeBase64, _, let receivedAt):
                        await reactions.ingestUpdate(
                            serverMessageId: messageId,
                            senderUserId: senderUserId,
                            envelopeBase64: envelopeBase64,
                            receivedAtMillis: receivedAt
                        )
                    case .serverRestored:
                        // A backup restore rotated the server's JWT signing
                        // key and closed our socket — our token is now
                        // rejected. Re-handshake IMMEDIATELY (don't wait for
                        // the expiry-based refresher ~an hour out); the
                        // persisted fresh bearer is then picked up by the
                        // socket's auto-reconnect.
                        await onSessionInvalidated?()
                    default:
                        break
                    }
                    if Task.isCancelled { break }
                }
            }()
            async let statusTask: () = {
                for await status in statusStream {
                    if Task.isCancelled { break }
                    if case .connected = status {
                        _ = await receive.catchUp()
                        _ = await reactions.catchUp()
                        // Reconcile outgoing receipts: the server broadcasts
                        // delivered/read best-effort, so any ack that landed
                        // while we were offline was dropped. Re-query status
                        // for every still-open outgoing row.
                        await receipts.reconcileOutgoingStatuses()
                        // Retry inbound read-acks the server never confirmed
                        // (POST failed, or made while backgrounded) so the
                        // peer eventually sees "read".
                        await receipts.flushPendingReadAcks()
                        // Replay any SDP/ICE that failed to ship while
                        // the socket was down.
                        await signaling.flushPendingSignals()
                    }
                }
            }()
            _ = await (eventsTask, statusTask)
            _ = self
        }

        // Initial catch-up — drain anything the server has spooled for
        // us before WS settles. The WS .connected handler above will
        // run catchUp again on every reconnect, so messages that
        // arrive while we're momentarily offline never strand. Reconcile
        // outgoing receipts here too, so a cold launch lifts bubbles whose
        // delivered/read acks landed while the app was closed.
        Task {
            _ = await receive.catchUp()
            await receipts.reconcileOutgoingStatuses()
        }
    }

    /// Public trigger so AppRouter can invoke a catch-up pull on
    /// ScenePhase.active transitions — covers iOS background-resume
    /// and macOS app-switcher returns where the WS may stay alive
    /// but we still want a guaranteed-fresh server-side cursor pull.
    public func runCatchUp() async {
        if let receive = messageReceiveService { _ = await receive.catchUp() }
        if let reactions = reactionService { _ = await reactions.catchUp() }
    }

    /// Mark every unread incoming message in the thread as read —
    /// locally (clears the badge) AND server-side (peer's double-check
    /// lights up). Falls back to the local-only stamp when the receipt
    /// service isn't up.
    public func markThreadRead(threadUserId: String) async {
        guard let store = messageStore else { return }
        guard let receipts = readReceiptService else {
            try? store.markThreadRead(threadUserId: threadUserId)
            return
        }
        let unread = (try? store.unreadIncoming(threadUserId: threadUserId)) ?? []
        for m in unread {
            await receipts.markRead(rowId: m.id, serverId: m.server_id)
        }
    }

    /// Scene-phase plumbing: pause read-receipt acks while backgrounded
    /// and flush any in-flight typing state.
    public func sceneDidChange(isActive: Bool) async {
        await readReceiptService?.setPaused(!isActive)
        if !isActive {
            await typingService?.flush()
        }
    }

    /// Tear the WS pump down on sign-out / phase change. Idempotent.
    public func teardownMessagingStack() async {
        wsPumpTask?.cancel()
        wsPumpTask = nil
        if let ws = controlWebSocket {
            await ws.stop()
        }
        // End any in-progress call on the SERVER before tearing down —
        // the WS is still up and (for re-enroll) the token still valid,
        // so the peer gets a proper decline/cancel/end instead of being
        // stranded on a row that glare-blocks until the sweep.
        if let coordinator = callCoordinator {
            await coordinator.shutdown()
        }
        controlWebSocket = nil
        callCoordinator = nil
        callSignaling = nil
        if let outbox = outboxService {
            await outbox.stop()
        }
        outboxService = nil
        reactionService = nil
        readReceiptService = nil
        typingService = nil
        messageReceiveService = nil
        messageSendService = nil
        messageStore = nil
    }

    /// Path for the encrypted message-history database.
    ///
    /// Falling back to NSTemporaryDirectory on Application Support
    /// failure would silently put the encrypted message DB on a path
    /// the OS may purge mid-session. We throw instead — the caller in
    /// `bringUpMessagingStack` catches and degrades the connected
    /// shell rather than corrupting at-rest state.
    static func messageStorePath(userId: String) throws -> String {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )
        // Namespace under the bundle id AND the enrolled user id: a
        // re-enroll under a DIFFERENT identity (new family, new user)
        // must not open the previous account's history — each identity
        // gets its own database file. Same-user re-enrolls keep theirs.
        let bundle = Bundle.main.bundleIdentifier ?? "NestTalk"
        let bundleDir = support.appendingPathComponent(bundle, isDirectory: true)
        let dir = bundleDir.appendingPathComponent(userId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let newPath = dir.appendingPathComponent("messages.sqlite")
        try migrateLegacyDBIfNeeded(
            legacy: bundleDir.appendingPathComponent("messages.sqlite"),
            newPath: newPath,
            markerDir: dir,
            currentUserId: userId,
            ownerSentinel: bundleDir.appendingPathComponent(".legacy-owner")
        )
        return newPath.path
    }

    enum MigrationError: Error, CustomStringConvertible {
        case sizeMismatch(String)
        case copyFailed(String)
        public var description: String {
            switch self {
            case .sizeMismatch(let f): return "migration size mismatch for \(f)"
            case .copyFailed(let f):   return "migration copy failed for \(f)"
            }
        }
    }

    /// Record the legacy DB's owner from the identity that is ALREADY
    /// enrolled at app launch — i.e. before any re-enrollment can swap it.
    /// The un-namespaced legacy DB belongs to whoever the legacy build
    /// enrolled, and on a normal upgrade that identity is still the one in
    /// the Keychain when this build first runs. Capturing it here is what
    /// lets `migrateLegacyDBIfNeeded` FAIL CLOSED: a legacy DB with no
    /// recorded owner is never migrated into an arbitrary account.
    /// Idempotent + best-effort: a pre-existing sentinel is left untouched,
    /// and no legacy DB means nothing to claim.
    static func claimLegacyOwnerIfUnclaimed(userId: String) {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return }
        let bundle = Bundle.main.bundleIdentifier ?? "NestTalk"
        let bundleDir = support.appendingPathComponent(bundle, isDirectory: true)
        let legacy = bundleDir.appendingPathComponent("messages.sqlite")
        let sentinel = bundleDir.appendingPathComponent(".legacy-owner")
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: sentinel.path) else { return }
        try? Data(userId.utf8).write(to: sentinel)
    }

    /// One-time, ALL-OR-NOTHING migration: an earlier v0.4.0 build
    /// stored the DB un-namespaced at `<bundle>/messages.sqlite`. Move
    /// it (with its WAL/SHM sidecars) into the current user's dir so
    /// history, reactions, receipts, and queued outbox rows survive the
    /// upgrade. The legacy single-identity DB belonged to whoever is
    /// enrolled now (one active identity at a time).
    ///
    /// Staging discipline: copy the COMPLETE file set to `.migrating`
    /// temp names and verify each byte count BEFORE renaming any into
    /// place. On any failure, clean up staging, leave the legacy DB
    /// untouched, and THROW — bringUpMessagingStack degrades the
    /// connected shell rather than silently opening a blank or partial
    /// destination (which would read as "history lost").
    static func migrateLegacyDBIfNeeded(
        legacy: URL, newPath: URL, markerDir: URL,
        currentUserId: String, ownerSentinel: URL
    ) throws {
        let fm = FileManager.default
        let marker = markerDir.appendingPathComponent(".migrated")
        let suffixes = ["", "-wal", "-shm"]

        // Account-ownership gate — FAIL CLOSED. The legacy DB is
        // un-namespaced, so it belongs to whichever identity the legacy
        // build enrolled. `claimLegacyOwnerIfUnclaimed` records that owner
        // at app launch (from the identity present BEFORE any re-enroll).
        // Migrate ONLY when the recorded owner matches the current user; a
        // legacy DB with NO recorded owner, or one owned by a different
        // account, is quarantined (the current user gets a fresh DB) rather
        // than risk copying a prior account's messages + queued outbox.
        let stampedOwner = (try? String(contentsOf: ownerSentinel, encoding: .utf8)) ?? ""
        if stampedOwner != currentUserId, fm.fileExists(atPath: legacy.path) {
            // Not the recorded owner (or owner unknown) → quarantine. Stamp
            // THIS user's dir so the interrupted-migration scrub above
            // doesn't fire on every launch.
            if !fm.fileExists(atPath: marker.path) { try? Data().write(to: marker) }
            return
        }

        // The marker is the ONLY completion signal — main-file existence
        // alone is not. If newPath files exist WITHOUT the marker, a
        // prior migration was interrupted mid-rename: scrub the partial
        // destination and redo from the (still-present) legacy set so we
        // never open a main DB without its matching WAL.
        if !fm.fileExists(atPath: marker.path), fm.fileExists(atPath: newPath.path), fm.fileExists(atPath: legacy.path) {
            for suffix in suffixes { try? fm.removeItem(at: URL(fileURLWithPath: newPath.path + suffix)) }
        }

        guard !fm.fileExists(atPath: marker.path) else { return }   // already migrated
        guard fm.fileExists(atPath: legacy.path) else {
            // No legacy DB → fresh install; stamp the marker so future
            // launches skip the interrupted-migration scrub above.
            try? Data().write(to: marker)
            return
        }

        var staged: [(stage: URL, final: URL)] = []
        func cleanupStaging() { for s in staged { try? fm.removeItem(at: s.stage) } }

        do {
            for suffix in suffixes {
                let from = URL(fileURLWithPath: legacy.path + suffix)
                guard fm.fileExists(atPath: from.path) else { continue }
                let final = URL(fileURLWithPath: newPath.path + suffix)
                let stage = URL(fileURLWithPath: newPath.path + suffix + ".migrating")
                try? fm.removeItem(at: stage)
                do {
                    try fm.copyItem(at: from, to: stage)
                } catch {
                    throw MigrationError.copyFailed(from.lastPathComponent)
                }
                let srcSize = (try? fm.attributesOfItem(atPath: from.path)[.size] as? Int) ?? nil
                let dstSize = (try? fm.attributesOfItem(atPath: stage.path)[.size] as? Int) ?? nil
                guard let s = srcSize, let d = dstSize, s == d else {
                    throw MigrationError.sizeMismatch(from.lastPathComponent)
                }
                staged.append((stage, final))
            }
            // Whole set copied + verified — rename into place (local
            // moves within one dir are atomic per file).
            for s in staged {
                try? fm.removeItem(at: s.final)
                try fm.moveItem(at: s.stage, to: s.final)
            }
            // Stamp the completion marker BEFORE deleting the legacy set
            // — a crash between the renames and the marker is recoverable
            // (the legacy DB is still there to redo from); a crash after
            // the marker means the destination is whole.
            try Data().write(to: marker)
            for suffix in suffixes {
                try? fm.removeItem(at: URL(fileURLWithPath: legacy.path + suffix))
            }
            NTLogger.messaging.info("migrated legacy message DB (\(staged.count) files) into per-user dir")
        } catch {
            cleanupStaging()
            // Scrub any partially-renamed destination so the next attempt
            // (marker still absent) starts clean from the legacy set.
            for suffix in suffixes { try? fm.removeItem(at: URL(fileURLWithPath: newPath.path + suffix)) }
            throw error
        }
    }
}
