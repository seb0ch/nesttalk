import Foundation

#if canImport(Libbox)
import Libbox

/// Thin Swift wrapper around the Go-mobile sing-box runtime (`Libbox`).
///
/// Started once per app launch. Reloads its config in place when the caller
/// passes a `TransportConfig` with a different `fingerprint` (e.g. when the
/// user completes enrollment and we now have a TURN UUID alongside the API
/// UUID, or on reconfigure after restore).
///
/// Ported from `client/ios/Runner/Transport/LibboxRuntime.swift` at v0.2.3.
public final class RealityTransport {

    private let platform = PlatformStub()
    private let handler  = CommandHandler()
    private let basePath: URL
    private let workingPath: URL
    private let tempPath: URL
    private let logPath: URL

    private var setupComplete = false
    private var commandServer: LibboxCommandServer?
    private var apiPort: Int32 = 0
    private var turnPort: Int32 = 0
    private var lastFingerprint: String?

    public init(basePathOverride: URL? = nil) {
        let fm = FileManager.default
        let base: URL
        if let basePathOverride {
            base = basePathOverride
        } else {
            base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        basePath    = base.appendingPathComponent("NestTalkTransport", isDirectory: true)
        workingPath = basePath.appendingPathComponent("working", isDirectory: true)
        tempPath    = basePath.appendingPathComponent("tmp", isDirectory: true)
        logPath     = tempPath.appendingPathComponent("libbox-stderr.log")
    }

    /// Start or reload the REALITY runtime.
    ///
    /// Returns the local URLs the rest of the app talks to (loopback HTTP for the
    /// API, loopback turn:// for the TURN relay, when configured).
    public func start(config: TransportConfig) throws -> TransportInfoSnapshot {
        try ensureDirectories()
        try ensureSetup()
        try ensureCommandServer()

        if lastFingerprint != config.fingerprint {
            apiPort  = try reservePort(startingAt: 62080)
            turnPort = (config.turnUuid == nil) ? 0 : try reservePort(startingAt: 62180)
        }

        let configJSON = try LibboxConfigBuilder.build(
            config: config,
            apiPort: apiPort,
            turnPort: (config.turnUuid == nil) ? nil : turnPort
        )

        var err: NSError?
        if !LibboxCheckConfig(configJSON, &err) {
            throw TransportError.configInvalid(err?.localizedDescription ?? "unknown")
        }

        do {
            try commandServer?.startOrReloadService(configJSON, options: LibboxOverrideOptions())
        } catch {
            throw TransportError.unavailable("startOrReloadService: \(error.localizedDescription)")
        }

        lastFingerprint = config.fingerprint

        let apiURL = URL(string: "http://127.0.0.1:\(apiPort)")!
        let turnAddr = (config.turnUuid == nil) ? nil : "turn:127.0.0.1:\(turnPort)?transport=tcp"
        return TransportInfoSnapshot(apiBaseURL: apiURL, turnLocalAddress: turnAddr)
    }

    /// Stop the runtime. Safe to call after successful or failed `start`.
    public func stop() {
        commandServer?.close()
        commandServer = nil
        apiPort = 0
        turnPort = 0
        lastFingerprint = nil
    }

    /// Delete libbox's persisted working state (the sing-box cache-file).
    ///
    /// Call ONLY on a fresh enroll. A brand-new transport config makes any
    /// cache from a prior, now-defunct config irrelevant, and a stale
    /// cache-file there has been observed to poison the REALITY handshake
    /// ("reality verification failed" / `-1005`) until the dir is cleared by
    /// hand. The normal connect path never calls this, so an already-enrolled
    /// launch keeps its cache (no reconnect-speed regression in production).
    ///
    /// Scoped to `NestTalkTransport/working` only — app-namespaced, and inside
    /// the App Sandbox container in Release — so no other sing-box-based app
    /// is affected. `start()` recreates the directory via `ensureDirectories`.
    public func purgeWorkingState() {
        try? FileManager.default.removeItem(at: workingPath)
    }

    // MARK: - Internals

    private func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: basePath,    withIntermediateDirectories: true)
        try fm.createDirectory(at: workingPath, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempPath,    withIntermediateDirectories: true)
    }

    private func ensureSetup() throws {
        guard !setupComplete else { return }
        let options = LibboxSetupOptions()
        options.basePath    = basePath.path
        options.workingPath = workingPath.path
        options.tempPath    = tempPath.path
        options.logMaxLines = 500
        // See v0.2.3 commentary: the default unix-socket path exceeds sun_path
        // on the iOS simulator; loopback TCP sidesteps that on every target.
        let commandPort = try reservePort(startingAt: 62280)
        options.commandServerListenPort = commandPort
        options.commandServerSecret = UUID().uuidString
#if DEBUG
        options.debug = true
#endif
        var setupErr: NSError?
        if !LibboxSetup(options, &setupErr) {
            throw TransportError.unavailable(
                "LibboxSetup: \(setupErr?.localizedDescription ?? "unknown")"
            )
        }
        var redirectErr: NSError?
        LibboxRedirectStderr(logPath.path, &redirectErr)
        setupComplete = true
    }

    private func ensureCommandServer() throws {
        if commandServer != nil { return }
        var err: NSError?
        guard let server = LibboxNewCommandServer(handler, platform, &err) else {
            throw TransportError.unavailable(
                "LibboxNewCommandServer: \(err?.localizedDescription ?? "unknown")"
            )
        }
        do {
            try server.start()
        } catch {
            throw TransportError.unavailable(
                "commandServer.start: \(error.localizedDescription)"
            )
        }
        commandServer = server
    }

    private func reservePort(startingAt port: Int32) throws -> Int32 {
        var available: Int32 = 0
        var err: NSError?
        if LibboxAvailablePort(port, &available, &err) {
            return available
        }
        throw TransportError.unavailable(
            "LibboxAvailablePort: \(err?.localizedDescription ?? "unknown")"
        )
    }
}

// MARK: - Libbox protocol stubs
//
// Libbox requires a platform-info provider and a command-handler. On iOS /
// macOS we don't need the VPN/tunneling side of sing-box — we just run it as
// a local TCP proxy. So these stubs return empty / no-op answers.

private final class PlatformStub: NSObject, LibboxPlatformInterfaceProtocol {

    final class EmptyNetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        func hasNext() -> Bool { false }
        func next() -> LibboxNetworkInterface? { nil }
    }

    func autoDetectControl(_ fd: Int32) throws {}
    func clearDNSCache() {}
    func closeDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {}
    func closeNeighborMonitor(_ listener: (any LibboxNeighborUpdateListenerProtocol)?) throws {}

    func findConnectionOwner(
        _ ipProtocol: Int32,
        sourceAddress: String?,
        sourcePort: Int32,
        destinationAddress: String?,
        destinationPort: Int32
    ) throws -> LibboxConnectionOwner {
        throw TransportError.unavailable("Connection-owner lookup is not used in the app-internal transport.")
    }

    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        EmptyNetworkInterfaceIterator()
    }

    func includeAllNetworks() -> Bool { false }
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw TransportError.unavailable("Packet tunnel is not used in the app-internal transport.")
    }

    func readWIFIState() -> LibboxWIFIState? { nil }
    func registerMyInterface(_ name: String?) {}
    func send(_ notification: LibboxNotification?) throws {}
    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {}
    func startNeighborMonitor(_ listener: (any LibboxNeighborUpdateListenerProtocol)?) throws {}
    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }
    func underNetworkExtension() -> Bool { false }
    func usePlatformAutoDetectControl() -> Bool { false }
    func useProcFS() -> Bool { false }
}

private final class CommandHandler: NSObject, LibboxCommandServerHandlerProtocol {
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        status.available = false
        status.enabled = false
        return status
    }
    func serviceReload() throws {}
    func serviceStop() throws {}
    func setSystemProxyEnabled(_ enabled: Bool) throws {}
    func writeDebugMessage(_ message: String?) {
#if DEBUG
        if let message, !message.isEmpty { NSLog("[Libbox] %@", message) }
#endif
    }
}

#else

/// Stub for environments where the Libbox module isn't linked (e.g. macOS
/// target before the xcframework is rebuilt with a macOS slice, or Linux CI).
/// Production builds always link Libbox.
public final class RealityTransport {
    public init() {}
    public func start(config: TransportConfig) throws -> TransportInfoSnapshot {
        throw TransportError.unavailable("Libbox framework is not linked for this platform.")
    }
    public func stop() {}
    public func purgeWorkingState() {}
}

#endif
