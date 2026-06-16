import Foundation

/// Parameters needed to stand up the REALITY transport on device.
///
/// Mirrors the fields encoded in the v0.2.3 `nesttalk://i/<blob>` invite payload.
/// `apiUuid` is the v2ray/sing-box VLESS inbound UUID for API traffic; `turnUuid`
/// is a second VLESS inbound UUID reserved for the TURN relay tunnel (optional —
/// absent during enrollment, present after connect).
public struct TransportConfig: Sendable, Equatable {
    public let apiUuid: String
    public let turnUuid: String?
    public let bootstrap: Bootstrap

    public struct Bootstrap: Sendable, Equatable {
        public let serverAddress: String     // e.g. "nest.example.com"
        public let serverPort: Int           // e.g. 443
        public let serverName: String        // REALITY SNI target, e.g. "cloudflare.com"
        public let realityPublicKey: String  // base64, x25519
        public let realityShortID: String    // hex, 8–16 chars

        public init(
            serverAddress: String,
            serverPort: Int,
            serverName: String,
            realityPublicKey: String,
            realityShortID: String
        ) {
            self.serverAddress = serverAddress
            self.serverPort = serverPort
            self.serverName = serverName
            self.realityPublicKey = realityPublicKey
            self.realityShortID = realityShortID
        }
    }

    public init(apiUuid: String, turnUuid: String?, bootstrap: Bootstrap) {
        self.apiUuid = apiUuid
        self.turnUuid = turnUuid
        self.bootstrap = bootstrap
    }

    /// A stable string that changes only when something transport-observable changes —
    /// used by the runtime to decide whether to reload libbox or keep the current ports.
    public var fingerprint: String {
        "\(bootstrap.serverAddress):\(bootstrap.serverPort)|\(bootstrap.serverName)|\(bootstrap.realityPublicKey)|\(bootstrap.realityShortID)|\(apiUuid)|\(turnUuid ?? "")"
    }
}

/// Snapshot returned by `RealityTransport.start()` — local URLs the rest of the
/// app talks to instead of the remote server. All traffic sent to these addresses
/// is tunneled through REALITY to the real server.
public struct TransportInfoSnapshot: Sendable, Equatable {
    public let apiBaseURL: URL
    public let turnLocalAddress: String?

    public init(apiBaseURL: URL, turnLocalAddress: String?) {
        self.apiBaseURL = apiBaseURL
        self.turnLocalAddress = turnLocalAddress
    }
}

/// Errors raised by the transport layer.
public enum TransportError: Error, CustomStringConvertible, Sendable {
    case unavailable(String)
    case configInvalid(String)

    public var description: String {
        switch self {
        case .unavailable(let message):   return "Transport unavailable: \(message)"
        case .configInvalid(let message): return "Transport config invalid: \(message)"
        }
    }
}
