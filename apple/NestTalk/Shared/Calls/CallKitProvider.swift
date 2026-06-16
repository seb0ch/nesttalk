#if os(iOS)
import Foundation
import CallKit
import UIKit
import WebRTC

/// Metadata for a VoIP-pushed incoming call, retained so a lock-screen
/// answer can be turned into a real in-app call before the WS delivers
/// `incoming_call` (cold launch). `callId` is the server call id (also the
/// CallKit UUID string).
public struct IncomingCallMeta: Sendable, Equatable {
    public let callId: String
    public let fromUserId: String
    public let fromName: String
    public let kind: String
    public init(callId: String, fromUserId: String, fromName: String, kind: String) {
        self.callId = callId
        self.fromUserId = fromUserId
        self.fromName = fromName
        self.kind = kind
    }
}

/// Wires outgoing / incoming calls into the iOS CallKit UI — lock-screen
/// ring, answer-from-CarPlay, recent-calls integration.
///
/// **RTCAudioSession ownership.** WebRTC manages audio through
/// `RTCAudioSession`, a CocoaAudioSession wrapper. Touching raw
/// `AVAudioSession.sharedInstance()` from app code while WebRTC is
/// running causes audio drops, route-switch glitches, and CallKit
/// desync. The pattern this class enforces:
///
///   1. `useManualAudio = true` at init — WebRTC won't auto-activate.
///   2. `provider(_:didActivate:)` — call
///      `RTCAudioSession.shared.audioSessionDidActivate(s)` and set
///      `isAudioEnabled = true`.
///   3. `provider(_:didDeactivate:)` — call
///      `audioSessionDidDeactivate(s)` and `isAudioEnabled = false`.
///
/// CallKit owns the audio-session lifecycle; WebRTC cooperates.
public final class CallKitProvider: NSObject {

    public static let shared = CallKitProvider()

    public let provider: CXProvider
    public let callController = CXCallController()

    /// Hooks for the application layer. Set from the messaging-stack
    /// bring-up so tap-to-answer / hangup actually drive `CallService`.
    /// `onStart` carries (uuid, handleValue, displayName) — handleValue
    /// is whatever was passed in `CXHandle(type:value:)`, so callers
    /// can put a userId there (preferred) or fall back to a display
    /// name.
    public var onAnswer: (@Sendable (UUID) async -> Void)?
    public var onEnd:    (@Sendable (UUID) async -> Void)?
    public var onStart:  (@Sendable (UUID, String, String?) async -> Void)?

    /// Calls we've reported (incoming via reportNewIncomingCall +
    /// outgoing via reportOutgoing). `providerDidReset` walks this set
    /// so we tear down peer connections for both directions; the
    /// CXCallController's call observer only reflects calls we
    /// requested through CXCallController, not arbitrary inbound
    /// reports, so we can't rely on it.
    private var trackedUUIDs: Set<UUID> = []
    private let trackedLock = NSLock()

    /// Actions the user took before the app layer wired its hooks —
    /// a lock-screen answer/hangup racing app cold-launch (VoIP push
    /// arrives, CallKit rings, user reacts while the transport is still
    /// bootstrapping and `CallCoordinator` doesn't exist yet). Buffered
    /// here; the coordinator drains them when the WS `incoming_call`
    /// for the same CallKit UUID arrives.
    private var pendingAnswerUUIDs: Set<UUID> = []
    private var pendingEndUUIDs: Set<UUID> = []

    /// Metadata for incoming calls reported to CallKit from a VoIP push,
    /// keyed by CallKit UUID. Lets a lock-screen answer that lands BEFORE
    /// the WS delivers `incoming_call` (cold launch) be turned into a real
    /// in-app call without waiting for the socket — otherwise the app
    /// foregrounds to the roster with no call surface. Cleared on
    /// untrack/end/reset.
    private var incomingMeta: [UUID: IncomingCallMeta] = [:]

    public func track(uuid: UUID) {
        trackedLock.lock(); defer { trackedLock.unlock() }
        trackedUUIDs.insert(uuid)
    }

    public func untrack(uuid: UUID) {
        trackedLock.lock(); defer { trackedLock.unlock() }
        trackedUUIDs.remove(uuid)
        incomingMeta.removeValue(forKey: uuid)
        pendingAnswerUUIDs.remove(uuid)
    }

    /// Consume a buffered lock-screen answer for `uuid`. Returns true
    /// at most once per answer.
    public func takePendingAnswer(uuid: UUID) -> Bool {
        trackedLock.lock(); defer { trackedLock.unlock() }
        return pendingAnswerUUIDs.remove(uuid) != nil
    }

    /// Consume a buffered lock-screen hangup/decline for `uuid`.
    public func takePendingEnd(uuid: UUID) -> Bool {
        trackedLock.lock(); defer { trackedLock.unlock() }
        return pendingEndUUIDs.remove(uuid) != nil
    }

    /// Record metadata for an incoming call reported to CallKit (from the
    /// VoIP push), so a lock-screen answer can be synthesized into a real
    /// call without the WS `incoming_call`.
    public func registerIncomingMeta(uuid: UUID, _ meta: IncomingCallMeta) {
        trackedLock.lock(); defer { trackedLock.unlock() }
        incomingMeta[uuid] = meta
    }

    /// Pop a buffered lock-screen answer that has push metadata — the
    /// coordinator uses it to synthesize + accept the incoming call on cold
    /// launch. Returns at most once per answer.
    public func takePendingAnsweredMeta() -> IncomingCallMeta? {
        trackedLock.lock(); defer { trackedLock.unlock() }
        // Only consume metas we can actually route (non-empty fromUserId).
        // An older push without from_user_id is left in pendingAnswerUUIDs so
        // the WS incoming_call path can still drain it — consuming it here
        // would strand the answer and drop the user on the roster.
        guard let uuid = pendingAnswerUUIDs.first(where: {
            (incomingMeta[$0]?.fromUserId.isEmpty == false)
        }) else { return nil }
        pendingAnswerUUIDs.remove(uuid)
        return incomingMeta.removeValue(forKey: uuid)
    }

    /// Metadata for a still-pending incoming call (answer arrived after the
    /// coordinator wired its hooks but before the WS `incoming_call`).
    public func incomingMeta(for uuid: UUID) -> IncomingCallMeta? {
        trackedLock.lock(); defer { trackedLock.unlock() }
        return incomingMeta[uuid]
    }

    public override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = true
        cfg.maximumCallsPerCallGroup = 1
        cfg.maximumCallGroups = 1
        cfg.supportedHandleTypes = [.generic]
        cfg.iconTemplateImageData = nil
        self.provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: .main)

        // Audio-session policy. Manual mode hands lifecycle to CallKit.
        let rtcConfig = RTCAudioSessionConfiguration.webRTC()
        rtcConfig.category = AVAudioSession.Category.playAndRecord.rawValue
        rtcConfig.mode = AVAudioSession.Mode.voiceChat.rawValue
        // .allowBluetooth + .allowBluetoothA2DP — NOT .defaultToSpeaker
        // (forcing speaker over earpiece breaks expected audio routing
        // for voice calls; CallKit's speaker button is the user-driven
        // override).
        rtcConfig.categoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        RTCAudioSessionConfiguration.setWebRTC(rtcConfig)

        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.useManualAudio = true
        rtcSession.isAudioEnabled = false
    }

    /// Start outgoing call — shows the "calling…" UI and registers with
    /// CallKit so the call appears in Recents.
    /// - Parameters:
    ///   - uuid: per-call UUID; tracked so providerDidReset can tear
    ///     it down on system reset.
    ///   - remoteUserId: server-side user id, embedded as the CXHandle
    ///     value. CallService reads it back from `onStart` to know who
    ///     to dial.
    ///   - remoteDisplayName: shown to the user in the system UI.
    public func reportOutgoing(
        uuid: UUID,
        remoteUserId: String,
        remoteDisplayName: String,
        isVideo: Bool,
        onDenied: (@Sendable () -> Void)? = nil
    ) {
        track(uuid: uuid)
        let handle = CXHandle(type: .generic, value: remoteUserId)
        let start = CXStartCallAction(call: uuid, handle: handle)
        // Drives the CallKit "<App> Audio"/"<App> Video" label.
        start.isVideo = isVideo
        start.contactIdentifier = remoteDisplayName
        let tx = CXTransaction(action: start)
        callController.request(tx) { [weak self] error in
            if let error {
                NSLog("[callkit] CXStartCallAction request failed: \(error)")
                self?.untrack(uuid: uuid)
                onDenied?()
            }
        }
    }

    /// Report incoming call from a VoIP push — this is what makes the
    /// lock-screen UI appear while the app is closed.
    public func reportIncoming(uuid: UUID, fromUserId: String? = nil, from remoteDisplayName: String, isVideo: Bool) async throws {
        track(uuid: uuid)
        let update = CXCallUpdate()
        // Handle value carries the user id (so CallService can route);
        // localizedCallerName carries the display name (what the user
        // actually sees). If we only have the display name (legacy
        // tests), fall back to using it as the handle.
        update.remoteHandle = CXHandle(type: .generic, value: fromUserId ?? remoteDisplayName)
        update.localizedCallerName = remoteDisplayName
        // Drives the CallKit "<App> Audio"/"<App> Video" label.
        update.hasVideo = isVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        do {
            try await provider.reportNewIncomingCall(with: uuid, update: update)
        } catch {
            // A duplicate UUID is the benign push-vs-WS race: the call is
            // already ringing, so converge on it silently (keep it tracked).
            if Self.isDuplicateUUID(error) { return }
            // Any other error means CallKit REFUSED the ring (DND/block/etc):
            // it will never exist. Drop the speculative tracking entry (else
            // providerDidReset synthesizes a stale onEnd) and rethrow so the
            // caller tears the call down instead of letting it linger.
            untrack(uuid: uuid)
            throw error
        }
    }

    /// True when CallKit rejected a report only because the UUID is already
    /// known — a benign race between the VoIP push and the WS-driven ring,
    /// not a real failure. Shared by the push and WS report paths.
    public static func isDuplicateUUID(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == CXErrorDomainIncomingCall
            && ns.code == CXErrorCodeIncomingCallError.callUUIDAlreadyExists.rawValue
    }

    public func reportEnded(uuid: UUID, reason: CXCallEndedReason = .remoteEnded) {
        provider.reportCall(with: uuid, endedAt: nil, reason: reason)
        untrack(uuid: uuid)
    }
}

extension CallKitProvider: CXProviderDelegate {
    public func providerDidReset(_ provider: CXProvider) {
        // CallKit told us to wipe state. Walk OUR tracked set —
        // CXCallController.callObserver only reflects calls we
        // requested via CXCallController (outgoing transactions);
        // incoming-via-VoIP-push reports are NOT in that list.
        let snapshot: Set<UUID>
        trackedLock.lock()
        snapshot = trackedUUIDs
        trackedUUIDs.removeAll()
        incomingMeta.removeAll()
        pendingAnswerUUIDs.removeAll()
        pendingEndUUIDs.removeAll()
        trackedLock.unlock()

        for uuid in snapshot {
            Task { await onEnd?(uuid) }
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        track(uuid: action.callUUID)
        // Fulfill PROMPTLY — CXStartCallAction has a system deadline
        // (a few seconds). Awaiting the full setup (permission prompts,
        // TURN fetch, POST /calls, WebRTC offer) before fulfill would
        // let normal network latency time the action out, leaving a
        // failed CallKit UI over a live server call. Setup runs async;
        // CallCoordinator.performOutgoing reports the call ended (which
        // CallKitProvider.reportEnded surfaces) if it can't complete.
        action.fulfill()
        Task {
            await onStart?(
                action.callUUID,
                action.handle.value,                      // user id (per reportOutgoing)
                action.contactIdentifier                  // display name (optional)
            )
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let onAnswer {
            Task {
                await onAnswer(action.callUUID)
                action.fulfill()
            }
        } else {
            // Cold-launch race: the user answered before the app layer
            // wired its hooks. Buffer; CallCoordinator drains on the
            // WS incoming_call for this UUID and auto-accepts.
            trackedLock.lock()
            pendingAnswerUUIDs.insert(action.callUUID)
            trackedLock.unlock()
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        untrack(uuid: action.callUUID)
        if let onEnd {
            Task {
                await onEnd(action.callUUID)
                action.fulfill()
            }
        } else {
            trackedLock.lock()
            pendingEndUUIDs.insert(action.callUUID)
            pendingAnswerUUIDs.remove(action.callUUID)
            trackedLock.unlock()
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.audioSessionDidActivate(audioSession)
        rtcSession.isAudioEnabled = true
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.audioSessionDidDeactivate(audioSession)
        rtcSession.isAudioEnabled = false
    }
}

#endif
