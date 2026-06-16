import Foundation

public extension APIClient {

    struct CreateCallRequest: Encodable, Sendable {
        public let callee_user_id: String
        public let kind: String
    }

    struct CreateCallResponse: Decodable, Sendable {
        public let call_id: String
        public let state: String
    }

    struct CallResultResponse: Decodable, Sendable {
        public let state: String
        public let ended_reason: String?
    }

    struct RelayCredentials: Decodable, Sendable {
        public let username: String
        public let password: String
        public let ttl_seconds: Int
        public let urls: [String]
    }

    /// Glare: the server already has a ringing/connected call between this
    /// pair (the peer called us at the same instant). Carries the existing
    /// call so the caller can pivot into ANSWERING it instead of both sides
    /// timing out. (POST /calls → 409 with these fields.)
    struct CallGlareError: Error, Sendable {
        let existingCallId: String
        let existingCallerUserId: String
        let existingCallKind: String
        let existingCallState: String   // "ringing" | "connected"
    }

    /// `POST /calls` → 409 `error="busy"`: a participant is already on a call
    /// with a THIRD party. Unlike glare, the requester is NOT a participant in
    /// the blocking call, so NO existing-call metadata is carried — only the
    /// busy participant (always self or the dialed peer). This is a terminal
    /// dial failure, never a recoverable ring pivot.
    struct CallBusyError: Error, Sendable {
        let busyUserId: String?
    }

    func createCall(
        calleeUserId: String,
        kind: String = "audio",
        sessionToken: String?
    ) async throws -> CreateCallResponse {
        let url = baseURL.appendingPathComponent("api/v1/calls")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        Self.stampTrace(&req, "POST /api/v1/calls")
        req.httpBody = try JSONEncoder().encode(CreateCallRequest(callee_user_id: calleeUserId, kind: kind))
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIClient.SendError.malformedResponse
        }
        if http.statusCode == 409 {
            // Decode on the `error` discriminator. ONLY a same-pair glare —
            // where this client IS a participant — is recoverable as a
            // simultaneous-call race; its body carries the existing-call
            // metadata. A `busy` conflict (the dialed peer is on another call)
            // must NOT be treated as glare: synthesizing a ring for a call this
            // client isn't part of would route through accept/end on an
            // unauthorized call. Gate strictly on error == "glare".
            struct ConflictBody: Decodable {
                let error: String?
                let busy_user_id: String?
                let existing_call_id: String?
                let existing_caller_user_id: String?
                let existing_call_kind: String?
                let existing_call_state: String?
            }
            let body = try? JSONDecoder().decode(ConflictBody.self, from: data)
            if body?.error == "glare",
               let id = body?.existing_call_id,
               let caller = body?.existing_caller_user_id,
               let kind = body?.existing_call_kind {
                // Fail CLOSED on a missing/unknown state. The pivot to an
                // incoming ring is only safe for an explicitly `ringing` call;
                // an older server (version skew) omits existing_call_state even
                // for a CONNECTED same-pair call, and defaulting that to
                // "ringing" would synthesize a ring for a live call and could
                // tear it down. Anything other than "ringing" → no pivot.
                throw CallGlareError(
                    existingCallId: id,
                    existingCallerUserId: caller,
                    existingCallKind: kind,
                    existingCallState: body?.existing_call_state ?? "unknown"
                )
            }
            if body?.error == "busy" {
                throw CallBusyError(busyUserId: body?.busy_user_id)
            }
            throw APIClient.SendError.http(code: 409, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIClient.SendError.http(code: http.statusCode, body: nil)
        }
        return try JSONDecoder().decode(CreateCallResponse.self, from: data)
    }

    func acceptCall(_ callId: String, sessionToken: String?) async throws -> CallResultResponse {
        try await callAction(callId: callId, action: "accept", sessionToken: sessionToken)
    }
    func declineCall(_ callId: String, sessionToken: String?) async throws -> CallResultResponse {
        try await callAction(callId: callId, action: "decline", sessionToken: sessionToken)
    }
    func cancelCall(_ callId: String, sessionToken: String?) async throws -> CallResultResponse {
        try await callAction(callId: callId, action: "cancel", sessionToken: sessionToken)
    }
    func endCall(_ callId: String, sessionToken: String?) async throws -> CallResultResponse {
        try await callAction(callId: callId, action: "end", sessionToken: sessionToken)
    }

    struct RegisterPushTokenRequest: Encodable, Sendable {
        public let token: String
        public let env: String
    }

    /// `POST /api/v1/devices/push-token`. The token is hex-encoded
    /// (PKPushCredentials.token bytes); env is "dev" for sandbox builds
    /// (Debug aps-environment=development) or "prod" otherwise.
    func registerPushToken(
        token: String,
        env: String,
        sessionToken: String?
    ) async throws {
        let url = baseURL.appendingPathComponent("api/v1/devices/push-token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(RegisterPushTokenRequest(token: token, env: env))
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIClient.SendError.http(code: code, body: nil)
        }
    }

    func relaySession(sessionToken: String?) async throws -> RelayCredentials {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/relay/session"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = []
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        Self.stampTrace(&req, "GET /api/v1/relay/session")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIClient.SendError.http(code: code, body: nil)
        }
        return try JSONDecoder().decode(RelayCredentials.self, from: data)
    }

    // MARK: - internals

    private func callAction(callId: String, action: String, sessionToken: String?) async throws -> CallResultResponse {
        let url = baseURL
            .appendingPathComponent("api/v1/calls")
            .appendingPathComponent(callId)
            .appendingPathComponent(action)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIClient.SendError.http(code: code, body: nil)
        }
        return try JSONDecoder().decode(CallResultResponse.self, from: data)
    }

    private func callPost<Req: Encodable, Resp: Decodable>(
        path: String,
        body: Req,
        sessionToken: String?,
        decodeAs: Resp.Type
    ) async throws -> Resp {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionToken {
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIClient.SendError.http(code: code, body: nil)
        }
        return try JSONDecoder().decode(Resp.self, from: data)
    }
}
