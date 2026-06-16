import Foundation

public extension APIClient {

    struct PutReactionRequest: Encodable, Sendable {
        public let envelope: String
        public let sent_at: Int64
    }

    struct PutReactionResponse: Decodable, Sendable {
        public let id: String
        public let received_at: Int64
    }

    struct ReactionsPage: Decodable, Sendable {
        public let reactions: [Item]
        public let next_cursor: PageCursor?

        public struct Item: Decodable, Sendable {
            public let id: String
            public let message_id: String
            public let sender_user_id: String
            public let envelope: String
            public let sent_at: Int64
            public let received_at: Int64
        }
    }

    func putReaction(
        messageId: String,
        envelopeBase64: String,
        sentAt: Date,
        sessionToken: String?
    ) async throws -> PutReactionResponse {
        let url = baseURL
            .appendingPathComponent("api/v1/messages")
            .appendingPathComponent(messageId)
            .appendingPathComponent("reactions")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(PutReactionRequest(
            envelope: envelopeBase64,
            sent_at: Int64(sentAt.timeIntervalSince1970 * 1000)
        ))
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 403 {
                // Same typed rotation contract as message sends —
                // ReactionService re-fetches keys, re-seals, retries.
                let parsed = try? JSONDecoder().decode(ServerError.self, from: data)
                if let active = parsed?.active_recipient_device_id {
                    throw APIClient.SendError.recipientDeviceRotated(activeDeviceId: active)
                }
            }
            throw APIClient.SendError.http(code: code, body: nil)
        }
        return try JSONDecoder().decode(PutReactionResponse.self, from: data)
    }

    func reactionsSince(
        sinceReceivedAt: Int64? = nil,
        sinceId: String? = nil,
        limit: Int = 100,
        sessionToken: String?
    ) async throws -> ReactionsPage {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/reactions/since"),
            resolvingAgainstBaseURL: false
        )!
        var qi: [URLQueryItem] = [.init(name: "limit", value: String(limit))]
        if let sinceReceivedAt { qi.append(.init(name: "since_received_at", value: String(sinceReceivedAt))) }
        if let sinceId         { qi.append(.init(name: "since_id",          value: sinceId)) }
        components.queryItems = qi
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIClient.SendError.http(code: code, body: nil)
        }
        return try JSONDecoder().decode(ReactionsPage.self, from: data)
    }
}
