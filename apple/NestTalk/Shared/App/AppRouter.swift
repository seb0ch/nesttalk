import SwiftUI

/// Top-level routing view. Switches subtree by `AppState.phase`:
/// - `.bootstrapping`: splash while `bootstrap()` resolves identity/transport.
/// - `.onboarding`: WelcomeView → InviteScanView path (no session yet).
/// - `.connected(EnrolledIdentity)`: ChatListView → ChatThreadView nav.
/// - `.error(String)`: failure state with a retry CTA.
public struct AppRouter: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.hearth) private var palette
    @Environment(\.scenePhase) private var scenePhase

    @State private var onboardingPath = OnboardingPath.welcome
    @State private var threadContact: ChatPreview? = nil
    @State private var showSettings = false
    @AppStorage("nt.palette") private var paletteChoice: String = "auto"

    #if DEBUG
    @AppStorage("dev.spike_shell_visible") private var spikeShellVisible: Bool = false
    #endif

    public init() {}

    public var body: some View {
        ZStack {
            // Only the bg layer ignores safe area — content sits inside
            // the safe area so it doesn't overlap status bar / Dynamic
            // Island. ignoresSafeArea on the outer ZStack would
            // propagate to every child and bleed content under the
            // status bar (Nest title under the time, etc).
            palette.bg.ignoresSafeArea()

            switch appState.phase {
            case .bootstrapping:
                splash
            case .connecting:
                connectingShell
            case .onboarding:
                onboardingShell
            case .connected(let identity):
                connectedShell(identity: identity)
            case .error(let message):
                errorShell(message: message)
            }

            // Call surfaces ride above the connected shell: CallView for
            // outgoing/active, IncomingCallSheet card on macOS. Idle
            // renders EmptyView so this is inert outside calls.
            if let coordinator = appState.callCoordinator {
                CallOverlay(coordinator: coordinator)
            }

            #if DEBUG
            if spikeShellVisible {
                SpikeDevOverlay()
                    .allowsHitTesting(true)
            }
            #endif
        }
        // Color scheme tracks the palette choice: dark palettes need
        // light status-bar text, light palettes need dark — forcing
        // `.light` unconditionally (the pre-Settings behavior) breaks
        // Nightlight. "auto" defers to the OS.
        .preferredColorScheme(preferredScheme)
        .sheet(isPresented: $showSettings) {
            SettingsView(onReEnroll: { Task { await runReEnroll() } })
                .hearthTheme(currentPalette)
        }
        // .task lives on the OUTER ZStack so it is not cancelled when
        // the inner switch picks a different branch. Bootstrap calls
        // `transition(to: .connecting)` mid-flight; if the .task were
        // attached to the splash subview, that branch flip would
        // tear down the splash and cancel the in-flight connect URL
        // request → NSURLErrorCancelled (-999) before the server
        // response landed. The nonce-keyed identity still re-fires
        // bootstrap on the .error → .bootstrapping retry path.
        .task(id: appState.bootstrapNonce) {
            await bootstrap()
        }
        // Drain any messages the server spooled for us while the app
        // was backgrounded (iOS) or fully closed (macOS app re-open).
        // Belt-and-suspenders alongside the WS-reconnect catch-up in
        // AppState.bringUpMessagingStack — both fire on resume; the
        // server is idempotent so duplicate pulls are cheap.
        .onChange(of: scenePhase) { _, phase in
            Task { await appState.sceneDidChange(isActive: phase == .active) }
            if phase == .active {
                Task { await appState.runCatchUp() }
            }
        }
    }

    /// nightlight → dark chrome; auto → follow the OS; everything else
    /// is a light palette.
    private var preferredScheme: ColorScheme? {
        switch paletteChoice {
        case "nightlight": return .dark
        case "auto":       return nil
        default:           return .light
        }
    }

    private var currentPalette: HearthPalette {
        switch paletteChoice {
        case "daylight":   return .daylight
        case "nightlight": return .nightlight
        case "paper":      return .paper
        default:           return palette
        }
    }

    /// Settings → "Re-enroll this device": tear the session down, wipe
    /// the enrollment artifacts (Device keys survive — re-using the
    /// same Ed25519 key lands the re-enroll on the same server-side
    /// user row), and route to onboarding for a fresh invite.
    @MainActor
    private func runReEnroll() async {
        await appState.teardownMessagingStack()
        // Stop the background token refresher BEFORE wiping credentials
        // and bump the epoch so any in-flight refresh (already past its
        // connect await) can't persist a stale token under the new
        // enrollment.
        await Self.activeRefresher?.stop()
        Self.activeRefresher = nil
        Self.enrollmentEpoch &+= 1
        EnrolledIdentityStore.delete()
        SessionTokenStore.delete()
        TransportConfigStore.delete()
        threadSelection = nil
        appState.transition(to: .onboarding)
    }

    // MARK: - Bootstrap

    /// Runs once at launch. The DEBUG path keeps a developer-only
    /// override that drops a fake EnrolledIdentity into `.connected` so
    /// the chat UI is reachable without a real session — it's gated
    /// behind a `@AppStorage("dev.spike_force_connected")` toggle so a
    /// shipped Release build never lands in `.connected` without a
    /// genuine SessionService.connect (which Sprint-2.x will wire).
    @MainActor
    private func bootstrap() async {
        guard appState.phase == .bootstrapping else { return }

        // 1. First-launch Keychain sweep — see KeychainWipe docs.
        //    Runs BEFORE any DeviceIdentity / DatabaseWrapKey access so
        //    a reinstall genuinely starts from zero.
        _ = KeychainWipe.wipeIfFirstLaunch()

        // 2. Process-global WebRTC SSL bootstrap (idempotent). Calling
        //    here keeps it out of CallService.deinit, which would otherwise
        //    tear down OpenSSL state for the whole process.
        CallService.bootstrapSSLOnce()

        // 2b. PushKit registration on iOS — the registry must exist
        //     and be set as a delegate BEFORE iOS can deliver a VoIP
        //     push, so the registration call lives at app launch
        //     rather than gated behind onboarding.
        #if os(iOS)
        PushKitHandler.shared.register()
        #endif

        // 3. Database wrap-key — generate-and-persist on first call. The
        //    bytes are used by MessageStore (when SQLCipher is enabled)
        //    and by Sprint-1's OutboxService for plaintext_wrapped AEAD.
        _ = (try? DatabaseWrapKey.loadOrCreate())

        do {
            let device = try DeviceIdentity.load()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "dev.spike_force_connected") {
                bringUpFakeConnectedSession()
                return
            }
            #endif

            let enrolled = EnrolledIdentityStore.load()
            let transport = TransportConfigStore.load()
            NSLog("[bootstrap] device=ok enrolled=\(enrolled != nil) transport=\(transport != nil)")

            // Record the legacy DB owner from the CURRENT identity before any
            // re-enroll can swap it — this is the only point we can attribute
            // the un-namespaced legacy DB to its real owner. Without it the
            // migration fails closed (quarantines).
            if let enrolled {
                AppState.claimLegacyOwnerIfUnclaimed(userId: enrolled.userId)
            }

            guard let enrolled, let transport else {
                // Either Enrolled or Transport persistence missed. Don't
                // wipe DeviceIdentity (re-using the same Ed25519 key
                // means the re-enroll lands on the SAME server-side
                // user row and avoids stranding orphaned keys); just
                // clear the half-state and route to onboarding so the
                // user can paste a fresh invite.
                NSLog("[bootstrap] missing enrolled/transport — back to onboarding (DeviceIdentity preserved)")
                EnrolledIdentityStore.delete()
                SessionTokenStore.delete()
                TransportConfigStore.delete()
                appState.transition(to: .onboarding)
                return
            }

            appState.transition(to: .connecting)
            await connectAndBringUp(
                device: device,
                enrolled: enrolled,
                transport: transport
            )
        } catch KeychainError.notFound {
            appState.transition(to: .onboarding)
        } catch {
            appState.transition(to: .error("Identity load failed: \(error)"))
        }
    }

    /// Stand up the REALITY tunnel, run `SessionService.connect` (or
    /// reuse an unexpired cached token), bring up the messaging stack,
    /// arm the refresh loop, transition to `.connected`. Any failure
    /// in this chain → `.error` with a retry-able message.
    @MainActor
    private func connectAndBringUp(
        device: DeviceIdentity,
        enrolled: EnrolledIdentity,
        transport: TransportConfig
    ) async {
        do {
            let snapshot = try Self.realityTransport.start(config: transport)
            try await finalizeConnection(
                device: device, enrolled: enrolled, snapshot: snapshot
            )
        } catch {
            NTLogger.identity.error("connect failed: \(error)")
            appState.transition(to: .error("Couldn't reconnect: \(error)"))
        }
    }

    /// Shared connect → bringUpMessagingStack → arm-refresher →
    /// transition path used by both bootstrap (cold launch with
    /// persisted identity) and runEnroll (just-enrolled, transport
    /// already running). The libbox runtime owns a process-global
    /// cache-file lock that doesn't release cleanly between rapid
    /// stop/restart cycles, so callers MUST reuse a single running
    /// transport — passing the same TransportInfoSnapshot through
    /// here keeps that invariant.
    @MainActor
    private func finalizeConnection(
        device: DeviceIdentity,
        enrolled: EnrolledIdentity,
        snapshot: TransportInfoSnapshot
    ) async throws {
        let api = APIClient(baseURL: snapshot.apiBaseURL)
        let svc = SessionService(baseURL: snapshot.apiBaseURL)

        let session: ActiveSession
        if let cached = SessionTokenStore.load(),
           cached.deviceId == enrolled.deviceId,
           cached.expiresAt > Date().addingTimeInterval(SessionRefresher.leadTime) {
            session = cached
        } else {
            // Identity gate: a cached token bound to a DIFFERENT device id
            // belongs to a prior account (a crash during re-enroll can save
            // the new EnrolledIdentity before deleting the old session). Never
            // authenticate as that user while opening this identity's DB —
            // drop it and re-connect.
            SessionTokenStore.delete()
            session = try await svc.connect(deviceId: enrolled.deviceId, identity: device)
            try SessionTokenStore.save(session)
        }

        // Arm the background refresher BEFORE bringUpMessagingStack starts
        // the WS pump + initial catch-up. Those can hit a 401 (or a
        // server_restored event) immediately after a JWT rotation, firing
        // onSessionInvalidated → activeRefresher?.refreshNow(); if the
        // refresher were still nil (armed later) that would no-op and the
        // client would sit on the rejected token until expiry. Arming first
        // closes that window.
        //
        // Stop any prior refresher and bump the enrollment epoch first:
        // even after stop() cancels the old task, a refresh already past
        // its connect() await could still fire onRefresh. The epoch guard
        // makes that stale callback a no-op so it can't overwrite the new
        // identity's token.
        await Self.activeRefresher?.stop()
        Self.enrollmentEpoch &+= 1
        let epoch = Self.enrollmentEpoch
        let refresher = SessionRefresher(
            session: svc,
            identity: device,
            onRefresh: { next in
                guard epoch == Self.enrollmentEpoch else { return }
                try? SessionTokenStore.save(next)
                // Re-register the VoIP token on every refresh — belt-and-
                // suspenders if an earlier upload failed.
                Self.uploadVoIPTokenIfPresent(api: api)
            }
        )
        await refresher.start(current: session)
        Self.activeRefresher = refresher

        if let wrapKey = try? DatabaseWrapKey.loadOrCreate() {
            try appState.bringUpMessagingStack(
                identity: enrolled,
                device: device,
                wrapKey: wrapKey,
                api: api,
                sessionTokenProvider: { SessionTokenStore.load()?.sessionToken },
                // server_restored / a 401 → force an immediate re-handshake
                // through the refresher (armed just above, so never nil here).
                onSessionInvalidated: { await Self.activeRefresher?.refreshNow() },
                // The libbox-local TURN tunnel — WebRTC dials this (coturn is
                // only reachable through REALITY), not the relay-session host.
                turnLocalURL: snapshot.turnLocalAddress
            )
        }

        // Roster fetch — populate the local `users` table so the chat
        // list shows every enrolled non-revoked family member, not
        // only those we've already exchanged messages with. Best-effort:
        // a transient failure leaves an empty list, OutboxService /
        // catch-up still work via direct user_id targeting.
        if let store = appState.messageStore {
            Task { [weak appState = self.appState] in
                guard let appState else { return }
                do {
                    let entries = try await api.fetchRoster(
                        sessionToken: SessionTokenStore.load()?.sessionToken
                    )
                    for e in entries {
                        try? store.upsertUser(MessageStore.User(
                            userId: e.user_id,
                            displayName: e.display_name,
                            colorHint: e.color_hint
                        ))
                    }
                    NSLog("[roster] synced \(entries.count) users")
                } catch {
                    NSLog("[roster] fetch failed: \(error)")
                }
                _ = appState
            }
        }

        #if os(iOS)
        // Register the VoIP push token now that a session exists (APNs
        // hands it at launch, before auth, so it was retained), and on every
        // future token rotation. Without this devices.voip_push_token stays
        // empty and terminated clients never get the incoming-call wake.
        Self.uploadVoIPTokenIfPresent(api: api)
        PushKitHandler.shared.onToken = { _ in
            Self.uploadVoIPTokenIfPresent(api: api)
        }
        #endif

        appState.transition(to: .connected(enrolled))
    }

    /// Upload the retained VoIP push token (if any) to the server, keyed by
    /// the current session. Best-effort: a failure leaves the token retained
    /// for the next connection/refresh to re-try.
    static func uploadVoIPTokenIfPresent(api: APIClient) {
        #if os(iOS)
        guard let token = PushKitHandler.shared.latestToken else { return }
        let env = PushKitHandler.currentApnsEnv()
        Task {
            try? await api.registerPushToken(
                token: token, env: env,
                sessionToken: SessionTokenStore.load()?.sessionToken
            )
        }
        #endif
    }

    /// Process-global REALITY transport — only one libbox runtime can
    /// exist per process, so we keep it in a static.
    private nonisolated(unsafe) static let realityTransport = RealityTransport()
    /// Held strongly so the refresher's task isn't dropped when
    /// `connectAndBringUp` returns.
    private nonisolated(unsafe) static var activeRefresher: SessionRefresher?
    /// Bumped on every (re)enrollment so a stale refresher's onRefresh
    /// callback (scoped to the epoch it was armed under) can't persist
    /// a token after the identity changed.
    private nonisolated(unsafe) static var enrollmentEpoch: UInt64 = 0

    #if DEBUG
    @MainActor
    private func bringUpFakeConnectedSession() {
        let placeholder = EnrolledIdentity(
            userId: "local-device",
            deviceId: "local-device",
            displayName: "You",
            colorHint: 0
        )
        if let wrapKey = (try? DatabaseWrapKey.loadOrCreate()),
           let url = URL(string: "http://127.0.0.1:9999") {
            do {
                let api = APIClient(baseURL: url)
                try appState.bringUpMessagingStack(
                    identity: placeholder, device: nil, wrapKey: wrapKey, api: api,
                    sessionTokenProvider: { nil }
                )
            } catch {
                NSLog("[bootstrap.debug] messaging stack: \(error)")
            }
        }
        appState.transition(to: .connected(placeholder))
    }
    #endif

    // MARK: - Phase shells

    private var splash: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "house.fill")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(palette.brand)
                ProgressView()
            }
        }
    }

    /// Shown while `SessionService.connect` runs against the REALITY
    /// tunnel. The handshake can take 1-3 seconds on a cold libbox
    /// init; without this state the user sees a frozen splash and may
    /// force-quit mid-handshake.
    private var connectingShell: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to your nest…")
                    .interFont(size: 13)
                    .foregroundStyle(palette.inkMuted)
            }
        }
    }

    private enum OnboardingPath: Equatable {
        case welcome
        case scan
    }

    private var onboardingShell: some View {
        Group {
            switch onboardingPath {
            case .welcome:
                WelcomeView(
                    onScanInvite: { onboardingPath = .scan },
                    onPasteInvite: { onboardingPath = .scan }
                )
            case .scan:
                InviteScanView(
                    onSubmit: { payload in
                        Task { await runEnroll(payload: payload) }
                    },
                    onBack: { onboardingPath = .welcome }
                )
            }
        }
    }

    /// Drive the enrollment flow end-to-end: stand up the REALITY
    /// tunnel from the invite's bootstrap, ensure all three device
    /// keys exist, run `SessionService.enroll(...)`, persist the
    /// returned `EnrolledIdentity` and the transport config, then
    /// transition to `.bootstrapping` so the standard connect path
    /// drives `.connecting → .connected`.
    @MainActor
    private func runEnroll(payload: EnrollmentPayload) async {
        NSLog("[enroll] runEnroll start, code=\(payload.code) apiUuid=\(payload.apiUuid ?? "nil") turnUuid=\(payload.turnUuid ?? "nil")")
        guard let bootstrap = payload.bootstrap, let apiUuid = payload.apiUuid else {
            NSLog("[enroll] missing bootstrap or apiUuid")
            appState.transition(to: .error("Invite missing transport bootstrap"))
            return
        }
        NSLog("[enroll] transition to .connecting")
        appState.transition(to: .connecting)

        let transport = TransportConfig(
            apiUuid: apiUuid, turnUuid: payload.turnUuid, bootstrap: bootstrap
        )
        do {
            // Fresh enroll = brand-new transport config: drop any stale
            // libbox cache-file from a prior/defunct config, which has been
            // seen to poison the REALITY handshake. Connect path never does
            // this, so steady-state launches keep their cache.
            Self.realityTransport.purgeWorkingState()
            NSLog("[enroll] starting RealityTransport")
            let snapshot = try Self.realityTransport.start(config: transport)
            NSLog("[enroll] transport up at \(snapshot.apiBaseURL)")

            let device: DeviceIdentity
            let messagePubKey: Data
            if #available(iOS 26.0, macOS 26.0, *) {
                NSLog("[enroll] ensureMessageKeys begin")
                device = try DeviceIdentity.ensureMessageKeys()
                NSLog("[enroll] ensureMessageKeys ok, building pubkey blob")
                messagePubKey = try device.messagePubKeyBlob()
                NSLog("[enroll] pubkey blob ok, \(messagePubKey.count) bytes")
            } else {
                NSLog("[enroll] OS too old, no MLKEM")
                appState.transition(to: .error("This OS lacks ML-KEM support; v0.4.0 requires iOS 26 / macOS 26."))
                return
            }

            NSLog("[enroll] POST /auth/enroll/start + complete")
            let enrolled = try await SessionService(baseURL: snapshot.apiBaseURL)
                .enroll(code: payload.code, identity: device, messagePubKey: messagePubKey)
            NSLog("[enroll] enrolled userId=\(enrolled.userId) deviceId=\(enrolled.deviceId)")

            do {
                try EnrolledIdentityStore.save(enrolled)
                NSLog("[enroll] EnrolledIdentityStore.save OK userId=\(enrolled.userId)")
            } catch {
                NSLog("[enroll] EnrolledIdentityStore.save FAILED: \(error)")
                throw error
            }
            do {
                try TransportConfigStore.save(transport)
                NSLog("[enroll] TransportConfigStore.save OK")
            } catch {
                NSLog("[enroll] TransportConfigStore.save FAILED: \(error)")
                throw error
            }
            SessionTokenStore.delete()
            NSLog("[enroll] persisted, finalizeConnection start")

            try await finalizeConnection(
                device: device, enrolled: enrolled, snapshot: snapshot
            )
            NSLog("[enroll] finalizeConnection done — should be .connected now")
        } catch {
            NSLog("[enroll] FAILED: \(error)")
            NTLogger.identity.error("enroll failed: \(error)")
            appState.transition(to: .error("Couldn't join family: \(error)"))
        }
    }

    @State private var threadSelection: (uid: String, name: String)? = nil
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// Bottom-tab selection for the iPhone (compact) shell.
    @State private var selectedTab: MainTab = .chats
    /// Navigation stack for the Chats tab (thread → contact info).
    @State private var chatsPath: [ChatsRoute] = []

    enum MainTab: Hashable { case chats, calls, you }
    enum ChatsRoute: Hashable {
        case thread(uid: String, name: String)
        case contact(uid: String, name: String)
    }

    /// iPad leading nav-rail selection.
    @State private var iPadRail: RailDestination = .chats
    enum RailDestination: Hashable { case chats, calls, people, safety }
    #endif

    /// Contact-info presentation for the iPad/macOS split shells (the
    /// permanent-sidebar layouts present it as a sheet rather than a push).
    struct ContactRef: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }
    @State private var contactSheet: ContactRef? = nil
    /// Safety Center presentation for the macOS sidebar footer.
    @State private var showSafety = false

    /// One configured thread view — shared by the iPhone, iPad-detail,
    /// and macOS-detail shells so the service wiring can't drift apart.
    private func liveThread(
        sel: (uid: String, name: String),
        store: MessageStore,
        onBack: @escaping () -> Void,
        onOpenContact: (() -> Void)? = nil
    ) -> some View {
        LiveChatThreadView(
            threadUserId: sel.uid,
            displayName: sel.name,
            onBack: onBack,
            onStartCall: { kind in
                appState.callCoordinator?.startOutgoingCall(
                    to: sel.uid, displayName: sel.name, kind: kind
                )
            },
            onTyping: {
                Task { await appState.typingService?.keystroke(toUserId: sel.uid) }
            },
            onMarkRead: {
                Task { await appState.markThreadRead(threadUserId: sel.uid) }
            },
            onReact: { message, emoji in
                Task {
                    await appState.reactionService?.setReaction(
                        messageRowId: message.id,
                        serverMessageId: message.server_id,
                        toUserId: sel.uid,
                        emoji: emoji
                    )
                }
            },
            onOpenContact: onOpenContact,
            typingObserver: appState.typingObserver
        )
        .environment(\.messageStore, store)
        .environment(\.messageSendService, appState.messageSendService)
    }

    /// Start a call to a peer, used by the Contact Info quick actions.
    private func startCall(to uid: String, name: String, kind: String) {
        appState.callCoordinator?.startOutgoingCall(to: uid, displayName: name, kind: kind)
    }

    /// Deterministic avatar color for a roster id — must match
    /// `LiveChatListView.avatarColor` exactly (same stable hash) so a
    /// contact's color is identical in the list and on the contact screen.
    /// `String.hashValue` is per-process randomized, so it is NOT used.
    private func avatarColor(for uid: String) -> Color {
        let hash = uid.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        switch abs(hash) % 4 {
        case 0:  return palette.avatar1
        case 1:  return palette.avatar2
        case 2:  return palette.avatar3
        default: return palette.avatar4
        }
    }

    /// One configured chat list — same dedup rationale as liveThread.
    private func liveList(store: MessageStore) -> some View {
        LiveChatListView(
            onSelect: { uid, name in threadSelection = (uid, name) },
            onOpenSettings: { showSettings = true },
            selectedThreadId: threadSelection?.uid,
            onOpenSafety: { showSafety = true },
            typingObserver: appState.typingObserver
        )
        .environment(\.messageStore, store)
        .environment(\.messageSendService, appState.messageSendService)
    }

    @ViewBuilder
    private func connectedShell(identity: EnrolledIdentity) -> some View {
        if let store = appState.messageStore {
            #if os(iOS)
            if hSizeClass == .regular {
                // iPad / large iPhone landscape — 78-pt nav rail (Chats /
                // Calls / People / Safety + profile) beside the active
                // destination; Chats is a list↔thread split-view.
                iPadShell(store: store)
            } else {
                compactConnectedShell(store: store)
            }
            #else
            macOSConnectedShell(store: store)
            #endif
        } else {
            ChatListView()
        }
    }

    #if os(iOS)
    @ViewBuilder
    private func compactConnectedShell(store: MessageStore) -> some View {
        TabView(selection: $selectedTab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: MainTab.chats) {
                NavigationStack(path: $chatsPath) {
                    LiveChatListView(
                        onSelect: { uid, name in chatsPath.append(.thread(uid: uid, name: name)) },
                        onOpenSettings: nil,
                        typingObserver: appState.typingObserver
                    )
                    .environment(\.messageStore, store)
                    .environment(\.messageSendService, appState.messageSendService)
                    .navigationDestination(for: ChatsRoute.self) { route in
                        chatsDestination(route, store: store)
                    }
                }
            }
            Tab("Calls", systemImage: "phone.fill", value: MainTab.calls) {
                NavigationStack { CallsView() }
            }
            Tab("You", systemImage: "person.fill", value: MainTab.you) {
                NavigationStack {
                    SettingsView(embedded: true, onReEnroll: { Task { await runReEnroll() } })
                }
            }
        }
        .tint(palette.brand)
    }

    @ViewBuilder
    private func chatsDestination(_ route: ChatsRoute, store: MessageStore) -> some View {
        switch route {
        case let .thread(uid, name):
            liveThread(
                sel: (uid, name), store: store,
                onBack: { if !chatsPath.isEmpty { chatsPath.removeLast() } },
                onOpenContact: { chatsPath.append(.contact(uid: uid, name: name)) }
            )
            .toolbar(.hidden, for: .tabBar)
        case let .contact(uid, name):
            ContactInfoView(
                displayName: name,
                avatarColor: avatarColor(for: uid),
                threadUserId: uid,
                onMessage: { if !chatsPath.isEmpty { chatsPath.removeLast() } },
                onAudioCall: { startCall(to: uid, name: name, kind: "audio") },
                onVideoCall: { startCall(to: uid, name: name, kind: "video") }
            )
            .toolbar(.hidden, for: .tabBar)
        }
    }

    // MARK: iPad nav-rail shell

    @ViewBuilder
    private func iPadShell(store: MessageStore) -> some View {
        HStack(spacing: 0) {
            iPadNavRail
            Group {
                switch iPadRail {
                case .chats:
                    NavigationSplitView {
                        liveList(store: store)
                            .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
                    } detail: {
                        if let sel = threadSelection {
                            liveThread(
                                sel: sel, store: store,
                                onBack: { threadSelection = nil },
                                onOpenContact: { contactSheet = ContactRef(uid: sel.uid, name: sel.name) }
                            )
                        } else {
                            WelcomePlaceholderView()
                        }
                    }
                case .calls:
                    CallsView()
                case .people:
                    peopleColumn(store: store)
                case .safety:
                    SafetyCenterView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.bg.ignoresSafeArea())
        .sheet(item: $contactSheet) { ref in contactInfoSheet(ref) }
    }

    private var iPadNavRail: some View {
        VStack(spacing: 6) {
            Image("LoginHero")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .shadow(color: palette.brand.opacity(0.27), radius: 8, y: 3)
                .padding(.bottom, 18)
                .accessibilityHidden(true)

            railItem(.chats, symbol: "bubble.left.and.bubble.right", label: "Chats")
            railItem(.calls, symbol: "phone", label: "Calls")
            railItem(.people, symbol: "person.2", label: "People")
            railItem(.safety, symbol: "lock.shield", label: "Safety")

            Spacer()

            Button { showSettings = true } label: {
                HearthAvatar(name: "You", color: palette.avatar2, size: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your profile and settings")
        }
        .padding(.top, 34)
        .padding(.bottom, 16)
        .frame(width: 78)
        .frame(maxHeight: .infinity)
        .background(palette.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.border).frame(width: 0.5)
        }
    }

    private func railItem(_ dest: RailDestination, symbol: String, label: String) -> some View {
        let on = iPadRail == dest
        return Button { iPadRail = dest } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: on ? .semibold : .regular))
                Text(label)
                    .interFont(size: 10.5, weight: on ? .semibold : .medium)
            }
            .foregroundStyle(on ? palette.brand : palette.inkMuted)
            .frame(width: 58)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(on ? palette.brandSoft : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// People directory — the roster doubles as the contact list in v0.4.0
    /// (no groups). Selecting a person opens their thread in the Chats split.
    private func peopleColumn(store: MessageStore) -> some View {
        LiveChatListView(
            onSelect: { uid, name in
                threadSelection = (uid, name)
                iPadRail = .chats
            },
            onOpenSettings: nil,
            typingObserver: appState.typingObserver
        )
        .environment(\.messageStore, store)
        .environment(\.messageSendService, appState.messageSendService)
    }
    #endif

    /// Contact-info sheet for the iPad/macOS split shells.
    private func contactInfoSheet(_ ref: ContactRef) -> some View {
        ContactInfoView(
            displayName: ref.name,
            avatarColor: avatarColor(for: ref.uid),
            threadUserId: ref.uid,
            onMessage: {
                contactSheet = nil
                threadSelection = (ref.uid, ref.name)
            },
            onAudioCall: {
                contactSheet = nil
                startCall(to: ref.uid, name: ref.name, kind: "audio")
            },
            onVideoCall: {
                contactSheet = nil
                startCall(to: ref.uid, name: ref.name, kind: "video")
            }
        )
        .hearthTheme(palette)
    }

    #if os(macOS)
    @ViewBuilder
    private func macOSConnectedShell(store: MessageStore) -> some View {
        // macOS chrome: hidden titlebar (set on the WindowGroup),
        // NavigationSplitView for the list↔thread layout. We strip
        // the default sidebar toggle button (no use case for hiding
        // the chat list) and drop the .ultraThinMaterial overlay so
        // the LiveChatListView's own palette.bg paints the sidebar
        // edge-to-edge — the previous overlay produced a visible
        // gap + a white half-tab artifact at the splitter.
        NavigationSplitView {
            liveList(store: store)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            if let sel = threadSelection {
                liveThread(
                    sel: sel, store: store,
                    onBack: { threadSelection = nil },
                    onOpenContact: { contactSheet = ContactRef(uid: sel.uid, name: sel.name) }
                )
            } else {
                WelcomePlaceholderView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 720)
        .sheet(item: $contactSheet) { ref in contactInfoSheet(ref) }
        .sheet(isPresented: $showSafety) {
            SafetyCenterView()
                .hearthTheme(palette)
                .frame(minWidth: 420, minHeight: 520)
        }
    }
    #endif

    private func errorShell(message: String) -> some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(palette.brand)
                Text("Something went wrong")
                    .frauncesFont(size: 24, weight: .semibold)
                    .foregroundStyle(palette.ink)
                Text(message)
                    .interFont(size: 13)
                    .foregroundStyle(palette.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button {
                    appState.transition(to: .bootstrapping)
                } label: {
                    Text("Retry")
                        .interFont(size: 15, weight: .semibold)
                        .foregroundStyle(palette.bubbleOutInk)
                        .frame(minWidth: 120, minHeight: 44)
                        .background(Capsule().fill(palette.brand))
                }
                .buttonStyle(.plain)
                Text("Version: \(AppVersion.string)")
                    .monoFont(size: 10)
                    .foregroundStyle(palette.inkMuted.opacity(0.7))
                    .padding(.top, 4)
            }
        }
    }
}

#if DEBUG
/// Floating dev overlay reachable by toggling `dev.spike_shell_visible`
/// in `@AppStorage`. Hosts the Spike CallKit-trigger button + tab switcher
/// kept around for ongoing manual QA.
struct SpikeDevOverlay: View {
    @Environment(\.hearth) private var palette
    @State private var tab: SpikeTab = .welcome
    @State private var ringCountdown: Int? = nil

    enum SpikeTab: String, CaseIterable, Identifiable {
        case welcome, chats, thread
        var id: String { rawValue }
        var label: String {
            switch self {
            case .welcome: return "Welcome"
            case .chats:   return "Chat list"
            case .thread:  return "Thread"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch tab {
                case .welcome:
                    WelcomeView()
                case .chats:
                    ChatListView()
                case .thread:
                    if let first = ChatPreview.sample.first {
                        ChatThreadView(contact: first)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 6) {
                #if os(iOS)
                devCallKitButton
                #endif
                tabButtons
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .background(palette.bg.ignoresSafeArea())
    }

    private var tabButtons: some View {
        HStack(spacing: 6) {
            ForEach(SpikeTab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    Text(t.label)
                        .interFont(size: 12, weight: tab == t ? .semibold : .regular)
                        .foregroundStyle(tab == t ? .white : palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(
                            Capsule().fill(tab == t ? palette.brand : palette.surface.opacity(0.9))
                        )
                        .overlay(
                            Capsule().stroke(palette.borderStrong, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    #if os(iOS)
    private var devCallKitButton: some View {
        Button {
            scheduleIncomingCallKitRing()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "phone.arrow.down.left.fill")
                    .font(.system(size: 14, weight: .bold))
                Text(ringCountdown.map { "Ringing in \($0)s — LOCK NOW" }
                     ?? "DEV: CallKit ring in 5s")
                    .interFont(size: 12, weight: .bold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Capsule().fill(Color(hex: 0xE53E3E)))
            .overlay(
                Capsule().stroke(.white.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(ringCountdown != nil)
    }

    private func scheduleIncomingCallKitRing() {
        ringCountdown = 5
        Task { @MainActor in
            for remaining in (1...5).reversed() {
                ringCountdown = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let uuid = UUID()
            do {
                try await CallKitProvider.shared.reportIncoming(uuid: uuid, from: "Mom", isVideo: true)
                NSLog("[spike] CallKit reportIncoming OK, uuid=\(uuid)")
            } catch {
                NSLog("[spike] CallKit reportIncoming FAILED: \(error)")
            }
            ringCountdown = nil
        }
    }
    #endif
}
#endif
