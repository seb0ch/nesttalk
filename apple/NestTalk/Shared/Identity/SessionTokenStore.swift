import Foundation

/// Persists the most recent `ActiveSession` (sessionToken + expiresAt +
/// deviceId) so a warm relaunch can reuse a valid bearer token without
/// re-running the connect handshake. Tokens are short-lived per the
/// server (typical 24h); `SessionRefresher` re-runs `connect` ~5 minutes
/// before expiry.
public enum SessionTokenStore {
    public static let tag = "com.nesttalk.session.v1"

    public static func save(_ session: ActiveSession) throws {
        let payload = try JSONEncoder().encode(Codable_(session))
        try KeychainBlob.upsert(account: tag, data: payload)
    }

    public static func load() -> ActiveSession? {
        guard
            let data = try? KeychainBlob.read(account: tag),
            let codable = try? JSONDecoder().decode(Codable_.self, from: data)
        else { return nil }
        return codable.session
    }

    public static func delete() {
        try? KeychainBlob.delete(account: tag)
    }

    private struct Codable_: Codable {
        let sessionToken: String
        let expiresAtMillis: Int64
        let deviceId: String
        init(_ s: ActiveSession) {
            sessionToken = s.sessionToken
            expiresAtMillis = Int64(s.expiresAt.timeIntervalSince1970 * 1000)
            deviceId = s.deviceId
        }
        var session: ActiveSession {
            ActiveSession(
                sessionToken: sessionToken,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAtMillis) / 1000),
                deviceId: deviceId
            )
        }
    }
}
