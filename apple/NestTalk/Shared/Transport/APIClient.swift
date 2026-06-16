import Foundation

/// Thin URLSession wrapper pinned to the local REALITY API base URL.
///
/// All traffic is loopback — the REALITY outbound lives in the sing-box process
/// (Libbox) and relays to the remote server. The REST of the app should never
/// hold a URL to the real remote host; it talks to `APIClient` which in turn
/// talks to `http://127.0.0.1:<port>/…`.
public struct APIClient: Sendable {
    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Server `/api/v1/health` response shape (v0.2.3 `server/cmd/nesttalk-server/routes.go`).
    public struct HealthResponse: Decodable, Sendable {
        public let ok: Bool
        public let server_time: Int64
        public let generation: Int64
        public let jwt_kid: String
        public let api_version: String
    }

    /// `GET /api/v1/health` — cheapest possible end-to-end roundtrip. Used by
    /// the Day-1 spike integration test to prove the transport stack works.
    public func health() async throws -> HealthResponse {
        let url = baseURL.appendingPathComponent("api/v1/health")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIClientError.http(code: code)
        }
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }
}

public enum APIClientError: Error, CustomStringConvertible, Sendable {
    case http(code: Int)

    public var description: String {
        switch self {
        case .http(let code): return "APIClient HTTP \(code)"
        }
    }
}
