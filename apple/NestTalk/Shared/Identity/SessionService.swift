import Foundation
import CryptoKit

/// Drives the v0.2.0 enrollment + connect handshakes against the Go server.
///
/// Talks to `APIClient.baseURL` — which in production is the loopback URL
/// returned by `RealityTransport.start()`, so all traffic is tunneled
/// through REALITY. In tests an injected `URLSession` with a stub
/// `URLProtocol` replaces the transport entirely.
///
/// Wire contract is in `AuthWireTypes.swift` and must stay byte-identical
/// to `server/cmd/nesttalk-server/routes.go` at v0.2.3.
public final class SessionService {
    public enum Error: Swift.Error, CustomStringConvertible {
        case httpStatus(Int, String?)
        case badResponse(String)

        public var description: String {
            switch self {
            case .httpStatus(let code, let reason):
                return "SessionService HTTP \(code)" + (reason.map { " (\($0))" } ?? "")
            case .badResponse(let what):
                return "SessionService: \(what)"
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Enrollment

    /// One-shot enrollment.
    ///
    /// - Parameters:
    ///   - code: the enrollment code from the `nesttalk://` invite.
    ///   - identity: freshly-generated device identity (caller persists to
    ///     Keychain; this function does NOT persist — rollback is easier
    ///     if enrollment fails partway).
    ///   - messagePubKey: hybrid PQC public key (X25519 || ML-KEM-768).
    ///     During the spike this can be a placeholder; the crypto layer
    ///     owns the real bytes from Day 5+.
    /// - Returns: The server-assigned user/device identity for this device.
    public func enroll(
        code: String,
        identity: DeviceIdentity,
        messagePubKey: Data
    ) async throws -> EnrolledIdentity {
        // 1. /auth/enroll/start → challenge
        let startResp: EnrollStartResponse = try await post(
            "api/v1/auth/enroll/start",
            body: EnrollStartRequest(code: code)
        )
        guard let challenge = Data(base64Encoded: startResp.challenge) else {
            throw Error.badResponse("enroll/start challenge is not base64")
        }

        // 2. Sign challenge with device private key (Ed25519).
        let attestation = try identity.sign(challenge)

        // 3. /auth/enroll/complete
        let completeResp: EnrollCompleteResponse = try await post(
            "api/v1/auth/enroll/complete",
            body: EnrollCompleteRequest(
                code: code,
                device_pubkey:  identity.publicKey.rawRepresentation.base64EncodedString(),
                message_pubkey: messagePubKey.base64EncodedString(),
                attestation:    attestation.base64EncodedString()
            )
        )
        return EnrolledIdentity(
            userId:      completeResp.user_id,
            deviceId:    completeResp.device_id,
            displayName: completeResp.display_name,
            colorHint:   completeResp.color_hint
        )
    }

    // MARK: - Connect

    /// Log back in on a later run using the persisted device identity.
    ///
    /// The server issues a fresh nonce, client signs it, server returns a
    /// session token the caller stores (typically also in Keychain).
    public func connect(
        deviceId: String,
        identity: DeviceIdentity
    ) async throws -> ActiveSession {
        // 1. /auth/connect/challenge → nonce
        let challengeResp: ConnectChallengeResponse = try await post(
            "api/v1/auth/connect/challenge",
            body: ConnectChallengeRequest(device_id: deviceId)
        )
        guard let nonce = Data(base64Encoded: challengeResp.nonce) else {
            throw Error.badResponse("connect/challenge nonce is not base64")
        }
        let attestation = try identity.sign(nonce)

        // 2. /auth/connect/complete
        let completeResp: ConnectCompleteResponse = try await post(
            "api/v1/auth/connect/complete",
            body: ConnectCompleteRequest(
                device_id:   deviceId,
                nonce:       nonce.base64EncodedString(),
                attestation: attestation.base64EncodedString()
            )
        )
        // Server's `expires_at` field is **unix milliseconds** (per
        // `auth.go: expiry := now + SessionTTL.Milliseconds()`). Treating
        // it as seconds previously produced a Date ~50,000 years in the
        // future and crashed SessionRefresher.Task.sleep on the
        // `UInt64(secondsTillExpiry * 1_000_000_000)` conversion.
        return ActiveSession(
            sessionToken: completeResp.session_token,
            expiresAt:    Date(timeIntervalSince1970: TimeInterval(completeResp.expires_at) / 1000),
            deviceId:     deviceId
        )
    }

    // MARK: - HTTP glue

    private func post<Req: Encodable, Resp: Decodable>(
        _ path: String,
        body: Req
    ) async throws -> Resp {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.badResponse("not an HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let reason = (try? decoder.decode(ServerErrorBody.self, from: data))?.error
            throw Error.httpStatus(http.statusCode, reason)
        }
        return try decoder.decode(Resp.self, from: data)
    }
}
