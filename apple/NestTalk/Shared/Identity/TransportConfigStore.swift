import Foundation

/// Persists `TransportConfig` (REALITY bootstrap + UUIDs) post-enroll so
/// subsequent launches can rebuild the libbox tunnel without forcing
/// the user to re-paste the invite. `turnUuid` is filled at enrollment-
/// complete; without it the TURN side of calls falls back to direct
/// candidates (which the relay-only ICE policy then rejects).
public enum TransportConfigStore {
    public static let tag = "com.nesttalk.transport.v1"

    public static func save(_ config: TransportConfig) throws {
        let payload = try JSONEncoder().encode(Codable_(config))
        try KeychainBlob.upsert(account: tag, data: payload)
    }

    public static func load() -> TransportConfig? {
        guard
            let data = try? KeychainBlob.read(account: tag),
            let codable = try? JSONDecoder().decode(Codable_.self, from: data)
        else { return nil }
        return codable.config
    }

    public static func delete() {
        try? KeychainBlob.delete(account: tag)
    }

    private struct Codable_: Codable {
        let apiUuid: String
        let turnUuid: String?
        let serverAddress: String
        let serverPort: Int
        let serverName: String
        let realityPublicKey: String
        let realityShortID: String

        init(_ c: TransportConfig) {
            apiUuid = c.apiUuid
            turnUuid = c.turnUuid
            serverAddress = c.bootstrap.serverAddress
            serverPort = c.bootstrap.serverPort
            serverName = c.bootstrap.serverName
            realityPublicKey = c.bootstrap.realityPublicKey
            realityShortID = c.bootstrap.realityShortID
        }
        var config: TransportConfig {
            TransportConfig(
                apiUuid: apiUuid,
                turnUuid: turnUuid,
                bootstrap: TransportConfig.Bootstrap(
                    serverAddress: serverAddress,
                    serverPort: serverPort,
                    serverName: serverName,
                    realityPublicKey: realityPublicKey,
                    realityShortID: realityShortID
                )
            )
        }
    }
}
