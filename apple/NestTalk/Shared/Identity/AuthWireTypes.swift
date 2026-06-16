import Foundation

// ----- Server JSON contracts for /api/v1/auth/* -----
// Must stay byte-identical to `server/cmd/nesttalk-server/routes.go` at v0.2.3.
// Any change here breaks the client ⇄ server handshake.

struct EnrollStartRequest: Encodable {
    let code: String
}
struct EnrollStartResponse: Decodable {
    let challenge: String  // base64 (std) of raw challenge bytes
}

struct EnrollCompleteRequest: Encodable {
    let code: String
    let device_pubkey: String
    let message_pubkey: String
    let attestation: String
}
struct EnrollCompleteResponse: Decodable {
    let user_id: String
    let device_id: String
    let display_name: String
    let color_hint: Int
}

struct ConnectChallengeRequest: Encodable {
    let device_id: String
}
struct ConnectChallengeResponse: Decodable {
    let nonce: String  // base64 (std)
}

struct ConnectCompleteRequest: Encodable {
    let device_id: String
    let nonce: String
    let attestation: String
}
struct ConnectCompleteResponse: Decodable {
    let session_token: String
    let expires_at: Int64  // unix seconds
}

struct ServerErrorBody: Decodable {
    let error: String
    let reason: String?
}

/// Outcome of a successful enrollment. Returned to UI for display-name /
/// avatar-color rendering. `sessionToken` is filled by the follow-up connect
/// handshake, not by enroll itself.
public struct EnrolledIdentity: Equatable, Sendable {
    public let userId: String
    public let deviceId: String
    public let displayName: String
    public let colorHint: Int
}

public struct ActiveSession: Equatable, Sendable {
    public let sessionToken: String
    public let expiresAt: Date
    public let deviceId: String
}
