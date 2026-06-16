import Foundation

/// Generates a sing-box (libbox) JSON configuration that terminates REALITY
/// to the server and exposes two loopback inbounds the app talks to:
///
///   * `api-in`  — local TCP port → VLESS+REALITY outbound → server API
///   * `turn-in` — local TCP port → VLESS+REALITY outbound → server TURN (optional)
///
/// Ported verbatim from the v0.2.3 Flutter iOS client
/// (`client/ios/Runner/Transport/LibboxConfigBuilder.swift`). The JSON shape is
/// stable server-side, so no server change is required.
enum LibboxConfigBuilder {

    static func build(
        config: TransportConfig,
        apiPort: Int32,
        turnPort: Int32?
    ) throws -> String {
        let host = config.bootstrap.serverAddress
        let port = config.bootstrap.serverPort

        var inbounds: [[String: Any]] = [
            [
                "type": "direct",
                "tag": "api-in",
                "listen": "127.0.0.1",
                "listen_port": Int(apiPort),
                "network": "tcp",
                "override_address": "127.0.0.1",
                "override_port": 80,
            ],
        ]

        var outbounds: [[String: Any]] = [
            vlessOutbound(
                tag: "api-out",
                host: host,
                port: port,
                uuid: config.apiUuid,
                sni: config.bootstrap.serverName,
                publicKey: config.bootstrap.realityPublicKey,
                shortId: config.bootstrap.realityShortID
            ),
        ]

        var rules: [[String: Any]] = [
            [
                "inbound": ["api-in"],
                "action": "route",
                "outbound": "api-out",
            ],
        ]

        if let turnUuid = config.turnUuid, let turnPort {
            inbounds.append(
                [
                    "type": "direct",
                    "tag": "turn-in",
                    "listen": "127.0.0.1",
                    "listen_port": Int(turnPort),
                    "network": "tcp",
                    "override_address": "127.0.0.1",
                    "override_port": 80,
                ]
            )
            outbounds.append(
                vlessOutbound(
                    tag: "turn-out",
                    host: host,
                    port: port,
                    uuid: turnUuid,
                    sni: config.bootstrap.serverName,
                    publicKey: config.bootstrap.realityPublicKey,
                    shortId: config.bootstrap.realityShortID
                )
            )
            rules.append(
                [
                    "inbound": ["turn-in"],
                    "action": "route",
                    "outbound": "turn-out",
                ]
            )
        }

        let configJSON: [String: Any] = [
            "log": [
                "level": "info",
                "output": "stderr",
            ],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": [
                "rules": rules,
            ],
        ]

        let data = try JSONSerialization.data(
            withJSONObject: configJSON,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw TransportError.configInvalid("failed to encode libbox JSON")
        }
        return json
    }

    private static func vlessOutbound(
        tag: String,
        host: String,
        port: Int,
        uuid: String,
        sni: String,
        publicKey: String,
        shortId: String
    ) -> [String: Any] {
        [
            "type": "vless",
            "tag": tag,
            "server": host,
            "server_port": port,
            "uuid": uuid,
            "flow": "xtls-rprx-vision",
            "network": "tcp",
            "tls": [
                "enabled": true,
                "server_name": sni,
                "utls": [
                    "enabled": true,
                    "fingerprint": "chrome",
                ],
                "reality": [
                    "enabled": true,
                    "public_key": publicKey,
                    "short_id": shortId,
                ],
            ],
        ]
    }
}
