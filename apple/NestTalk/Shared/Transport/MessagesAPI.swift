import Foundation

/// Wire shapes for the v0.2.3 `/api/v1/messages*` surface.
///
/// **Reading the server source (server/cmd/nesttalk-server/routes.go)**:
/// `POST /api/v1/messages` accepts `{envelope: <base64>, sent_at:
/// <int64>, reply_to_id?: <string>}` and returns `{id, received_at,
/// sent_at}`. The server reads the recipient routing UUIDs from the
/// envelope bytes themselves — there is no request-side
/// `recipient_user_id` field.
public extension APIClient {

    struct PostMessageRequest: Encodable, Sendable {
        public let envelope: String       // base64
        public let sent_at: Int64
        public let reply_to_id: String?

        public init(envelope: String, sent_at: Int64, reply_to_id: String?) {
            self.envelope = envelope
            self.sent_at = sent_at
            self.reply_to_id = reply_to_id
        }
    }

    struct PostMessageResponse: Decodable, Sendable {
        public let id: String
        public let received_at: Int64
        public let sent_at: Int64
    }

    struct ServerError: Decodable, Sendable {
        public let error: String
        public let reason: String?
        public let active_recipient_device_id: String?
    }

    enum SendError: Error, Sendable {
        case http(code: Int, body: ServerError?)
        case recipientDeviceRotated(activeDeviceId: String)
        case malformedResponse
        case retryable(code: Int)
    }

    func sendMessage(
        envelopeBase64: String,
        sentAt: Date,
        replyToId: String?,
        sessionToken: String?
    ) async throws -> PostMessageResponse {
        let url = baseURL.appendingPathComponent("api/v1/messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        Self.stampTrace(&req, "POST /api/v1/messages")
        let body = PostMessageRequest(
            envelope: envelopeBase64,
            sent_at: Int64(sentAt.timeIntervalSince1970 * 1000),
            reply_to_id: replyToId
        )
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SendError.malformedResponse
        }

        switch http.statusCode {
        case 200, 201:
            do {
                return try JSONDecoder().decode(PostMessageResponse.self, from: data)
            } catch {
                throw SendError.malformedResponse
            }
        case 403:
            // Recipient-device rotation. Server body carries
            // `active_recipient_device_id` so the caller can re-fetch
            // keys + re-seal.
            let parsed = try? JSONDecoder().decode(ServerError.self, from: data)
            if let active = parsed?.active_recipient_device_id {
                throw SendError.recipientDeviceRotated(activeDeviceId: active)
            }
            throw SendError.http(code: 403, body: parsed)
        case 408, 429, 500..<600:
            throw SendError.retryable(code: http.statusCode)
        default:
            let parsed = try? JSONDecoder().decode(ServerError.self, from: data)
            throw SendError.http(code: http.statusCode, body: parsed)
        }
    }

    /// `POST /api/v1/messages/{id}/ack` — wire shape `{kind: "received"|"read"}`.
    func ackMessage(
        id: String,
        kind: String,
        sessionToken: String?
    ) async throws {
        let url = baseURL
            .appendingPathComponent("api/v1/messages")
            .appendingPathComponent(id)
            .appendingPathComponent("ack")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(["kind": kind])
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SendError.http(code: code, body: nil)
        }
    }

    /// Query the server's authoritative delivery status for one of OUR
    /// outgoing messages (by server id). Returns the status string:
    /// "pending" | "delivered" | "read" | "expired" | "gone". Used to
    /// reconcile receipts that the best-effort WS broadcast missed while
    /// we were offline.
    func messageStatus(id: String, sessionToken: String?) async throws -> String {
        let url = baseURL
            .appendingPathComponent("api/v1/messages")
            .appendingPathComponent(id)
            .appendingPathComponent("status")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SendError.http(code: code, body: nil)
        }
        struct StatusResponse: Decodable { let status: String }
        return try JSONDecoder().decode(StatusResponse.self, from: data).status
    }

    struct PendingMessage: Decodable, Sendable {
        public let id: String
        public let sender_user_id: String
        public let envelope: String       // base64
        public let reply_to_id: String?
        public let sent_at: Int64
        public let received_at: Int64
    }

    /// Composite pagination cursor — the server emits an OBJECT
    /// (`{"received_at":…,"id":…}`), never a string. Modeling it as
    /// String? made JSONDecoder reject every non-empty page, silently
    /// breaking offline catch-up.
    struct PageCursor: Decodable, Sendable {
        public let received_at: Int64
        public let id: String
    }

    struct PendingResponse: Decodable, Sendable {
        public let messages: [PendingMessage]
        public let next_cursor: PageCursor?
    }

    func pendingMessages(
        sinceReceivedAt: Int64? = nil,
        sinceId: String? = nil,
        limit: Int = 100,
        sessionToken: String?
    ) async throws -> PendingResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/messages/pending"),
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
            throw SendError.http(code: code, body: nil)
        }
        return try JSONDecoder().decode(PendingResponse.self, from: data)
    }
}
