#if os(iOS)
import Foundation
import PushKit
import CallKit
import UIKit

/// Listens for VoIP pushes (`.voIP`) and reports them to CallKit.
///
/// Registration happens at app launch — `register()` is invoked from
/// `AppRouter.bootstrap` so the registry exists before any push arrives.
///
/// **Synchrony rule (Apple, iOS 13+).**
/// `pushRegistry(_:didReceiveIncomingPushWith:for:completion:)` MUST
/// **invoke** `CXProvider.reportNewIncomingCall(with:update:completion:)`
/// before this delegate method returns. The outer `completion()` itself
/// can fire asynchronously — what iOS requires is that `reportNew…` has
/// been *called* (synchronously, no `Task { }` wrapper) before the
/// delegate's stack frame unwinds. CallKit's inner completion may take
/// hundreds of ms to fire as the system shows the ring; that's fine.
/// The canonical pattern (Apple's PushKit/CallKit sample code) is to
/// call the outer `completion()` from inside the inner completion so
/// PushKit knows we've processed the push.
///
/// If we wrapped the report in a `Task` we'd cross a suspension point,
/// the delegate would return before `reportNew…` was even called, and
/// iOS would terminate the app + revoke the VoIP push entitlement on
/// subsequent retries — a silent ban that's a pain to recover from.
/// The implementation below avoids that by keeping the report call on
/// the calling thread.
///
/// On a malformed payload we still report a synthetic ended call so
/// the system at least sees SOMETHING — never nothing.
public final class PushKitHandler: NSObject {
    public static let shared = PushKitHandler()

    private let registry = PKPushRegistry(queue: .main)

    /// Called with the VoIP push token hex string when available.
    /// Host wires this to report the token to the server.
    public var onToken: ((String) -> Void)?

    /// The most recent VoIP push token, RETAINED so the host can upload it
    /// once a session exists — APNs typically hands the token at launch,
    /// before the user is authenticated, so the `onToken` callback alone
    /// would be lost. Read after connection (and on every refresh) to
    /// (re)register with the server.
    public private(set) var latestToken: String?

    /// Reporting hook injected by tests — substitutes a spy
    /// CXProvider so we can assert on call ordering. Production
    /// reads from `CallKitProvider.shared.provider`.
    public var providerForReporting: CXProvider?

    private var effectiveProvider: CXProvider {
        providerForReporting ?? CallKitProvider.shared.provider
    }

    public func register() {
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    /// Detect the running APNs environment.
    ///
    /// SecTaskCopyValueForEntitlement is macOS-only; on iOS the
    /// public Cocoa surface doesn't expose the entitlements blob to
    /// the app at runtime. We thread the choice through a Swift
    /// compilation condition (`NESTTALK_APNS_PROD`) wired in
    /// project.yml's Release config — same source of truth as the
    /// Release entitlements file. This is more reliable than
    /// `#if DEBUG` because the compilation condition is set
    /// per-build-config explicitly, not derived from Xcode's
    /// implicit DEBUG flag (which can be wrong in misconfigured
    /// TestFlight builds).
    public static func currentApnsEnv() -> String {
        // The embedded provisioning profile is the ground truth for the
        // token's APNs environment. An Apple-Development-signed build carries
        // a Development profile (aps-environment=development → SANDBOX token)
        // EVEN when built in the Release config — so the NESTTALK_APNS_PROD
        // compile flag alone reports "prod" while the device token is sandbox,
        // and APNs rejects the push with `BadEnvironmentKeyInToken`. Reading
        // the profile fixes that for any Debug/Release × dev/distribution combo.
        if let env = embeddedProvisioningApnsEnv() { return env }
        // Fallback when there's no embedded profile (e.g. Simulator): the
        // per-build-config compile flag.
        #if NESTTALK_APNS_PROD
        return "prod"
        #else
        return "dev"
        #endif
    }

    static func embeddedProvisioningApnsEnv() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return apnsEnv(fromProvisioning: data)
    }

    /// Extract `aps-environment` from a CMS-wrapped `.mobileprovision` blob.
    /// Returns "prod" for `production`, "dev" for `development`, nil if the
    /// embedded plist can't be located/parsed.
    static func apnsEnv(fromProvisioning data: Data) -> String? {
        guard let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<?xml"),
              // Search for the closing tag AFTER the opening one so a stray
              // "</plist>" before "<?xml" can't form an invalid (upper < lower)
              // string range and trap.
              let end = raw.range(of: "</plist>", range: start.lowerBound..<raw.endIndex),
              let plistData = String(raw[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = plist as? [String: Any],
              let ents = dict["Entitlements"] as? [String: Any],
              let aps = ents["aps-environment"] as? String
        else { return nil }
        switch aps {
        case "production":  return "prod"
        case "development": return "dev"
        // Unknown/malformed value → nil so currentApnsEnv() falls back to the
        // compile flag rather than silently mis-routing to sandbox.
        default:            return nil
        }
    }
}

extension PushKitHandler: PKPushRegistryDelegate {
    public func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        latestToken = hex
        onToken?(hex)
    }

    public func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        handleIncomingPush(payload: payload, type: type, completion: completion)
    }

    /// Test-friendly entry point — production code goes through the
    /// PKPushRegistryDelegate path; tests synthesize a payload and call
    /// this directly so they don't need a live `PKPushRegistry`.
    public func handleIncomingPush(
        payload: PKPushPayload,
        type: PKPushType,
        completion: @escaping () -> Void
    ) {
        process(dictionaryPayload: payload.dictionaryPayload,
                type: type, completion: completion)
    }

    /// Internal entry exposed to tests so they can synthesize a
    /// dictionary payload directly (PKPushPayload can't be init'd by
    /// app code; constructing a real PushKit one in tests is heavyweight).
    public func process(
        dictionaryPayload: [AnyHashable: Any],
        type: PKPushType,
        completion: @escaping () -> Void
    ) {
        // Always report SOMETHING to CallKit before this method returns —
        // even a malformed payload. Otherwise iOS sees an unfulfilled push
        // and may revoke the entitlement.
        let provider = effectiveProvider

        guard
            type == .voIP,
            let uuidString = dictionaryPayload["call_uuid"] as? String,
            let uuid = UUID(uuidString: uuidString)
        else {
            // Synthetic-ring path: report a placeholder incoming call,
            // immediately mark it ended, then fire the outer completion.
            // The timeline must still be: reportNewIncomingCall ➜
            // (CallKit ack) ➜ completion(). reportCall(with:endedAt:reason:)
            // is fire-and-forget and not part of the synchrony rule.
            let synthetic = UUID()
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: "Unknown")
            provider.reportNewIncomingCall(with: synthetic, update: update) { _ in
                provider.reportCall(
                    with: synthetic,
                    endedAt: nil,
                    reason: .failed
                )
                completion()
            }
            return
        }

        let fromName = (dictionaryPayload["from_name"] as? String) ?? "Unknown"
        let fromUserId = dictionaryPayload["from_user_id"] as? String
        // `kind` lets a cold-launch lock-screen answer set up the right media
        // (audio vs video). Absent in older server pushes → default video,
        // matching `update.hasVideo` below.
        let kind = (dictionaryPayload["kind"] as? String) ?? "video"
        let update = CXCallUpdate()
        // Handle value carries the user id when present (matches
        // CallKitProvider.reportIncoming so answer routing is uniform);
        // localizedCallerName is what the user sees.
        update.remoteHandle = CXHandle(type: .generic, value: fromUserId ?? fromName)
        update.localizedCallerName = fromName
        update.hasVideo = (kind == "video")
        update.supportsHolding = false
        update.supportsGrouping = false

        // The push's call_uuid IS the server call id, and the WS-driven
        // CallCoordinator derives its CallKit UUID from the same id —
        // both paths land on one CallKit call. Track it so
        // providerDidReset tears it down too.
        CallKitProvider.shared.track(uuid: uuid)
        // Retain who/what so a lock-screen answer arriving before the WS
        // delivers incoming_call (cold launch) can still be turned into an
        // in-app call instead of dumping the user on the roster.
        CallKitProvider.shared.registerIncomingMeta(
            uuid: uuid,
            IncomingCallMeta(
                callId: uuidString,
                fromUserId: fromUserId ?? "",
                fromName: fromName,
                kind: kind
            )
        )

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                // `callUUIDAlreadyExists` is NOT a failure: the WS-driven
                // CallCoordinator (reportIncoming) already registered this
                // exact call with CallKit — both paths deliberately use the
                // server call id as the UUID so they converge on ONE ring.
                // Reporting it ended here would tear down the legitimately
                // ringing (or already answered + connected) call — the
                // Mac→iPhone "fails after a few seconds" bug. Only a genuinely
                // fatal error should synthesize an ended call.
                if CallKitProvider.isDuplicateUUID(error) {
                    NSLog("[push] reportNewIncomingCall: UUID already registered (WS path owns the ring) — ok")
                } else {
                    NSLog("[push] reportNewIncomingCall failed: \(error)")
                    // CallKit disallowed the call (DND/block/etc): it will
                    // never exist, so drop the speculative tracking entry or
                    // a later providerDidReset would synthesize a stale
                    // onEnd/pending-end for a UUID that never rang.
                    CallKitProvider.shared.untrack(uuid: uuid)
                    provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
                }
            }
            completion()
        }
    }

}

#endif
