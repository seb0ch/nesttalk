import Foundation

public extension APIClient {

    /// `GET /api/v1/keys/message/{userId}` — return the active device
    /// for the recipient. v0.4.0 single-active-device per user means
    /// the array has at most one entry; we take the first.
    struct MessageKeysResponse: Decodable, Sendable {
        public let devices: [Entry]
        public struct Entry: Decodable, Sendable {
            public let device_id: String
            public let public_key: String       // base64 Ed25519
            public let message_pubkey: String   // base64 X25519||MLKEM
            public let enrolled_at: Int64
            /// Non-nil once the server revokes this device. The list can
            /// carry revoked devices (their signing keys still verify
            /// messages spooled before revocation) — only `revoked_at ==
            /// nil` entries may be sealed/routed to.
            public let revoked_at: Int64?
        }
    }

    /// All devices for the user — active first, then historical
    /// (retained server-side precisely for signature verification of
    /// messages spooled before a re-enrollment).
    func fetchDevices(forUserId userId: String, sessionToken: String?) async throws -> [MessageKeysResponse.Entry] {
        let url = baseURL.appendingPathComponent("api/v1/keys/message").appendingPathComponent(userId)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIClient.SendError.http(code: code, body: nil)
        }
        return try JSONDecoder().decode(MessageKeysResponse.self, from: data).devices
    }

    func fetchActiveDevice(forUserId userId: String, sessionToken: String?) async throws -> MessageKeysResponse.Entry? {
        let url = baseURL.appendingPathComponent("api/v1/keys/message").appendingPathComponent(userId)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIClient.SendError.http(code: code, body: nil)
        }
        // Skip revoked devices — sealing/routing to one 403s server-side
        // and loses the message. The list is active-first, but a revoked
        // device can still appear (retained for signature verification).
        return try JSONDecoder().decode(MessageKeysResponse.self, from: data)
            .devices.first(where: { $0.revoked_at == nil })
    }

    struct RosterResponse: Decodable, Sendable {
        public let roster: [Entry]

        public struct Entry: Decodable, Sendable {
            public let user_id: String
            public let display_name: String
            public let color_hint: Int
            public let last_seen_at: Int64?
        }
    }

    /// `GET /api/v1/roster` — returns every enrolled non-revoked user
    /// except the caller. v0.2.3 server response shape:
    /// `{"roster": [{user_id, display_name, color_hint, last_seen_at}]}`.
    func fetchRoster(sessionToken: String?) async throws -> [RosterResponse.Entry] {
        let url = baseURL.appendingPathComponent("api/v1/roster")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIClient.SendError.http(code: code, body: nil)
        }
        return try JSONDecoder().decode(RosterResponse.self, from: data).roster
    }
}
