import Foundation
import Compression

/// Parsed `nesttalk://` invite handed to the client by the admin CLI.
///
/// Wire format (v0.2.0, unchanged through v0.2.3):
///
///   { "v": 1,
///     "code": "<enrollment-code>",
///     "transport": {
///       "kind": "reality",
///       "server_addr": "host:port",
///       "sni": "cloudflare.com",
///       "public_key": "<base64>",
///       "short_id": "<hex>",
///       "api_uuid":  "<vless-uuid>",    // optional
///       "turn_uuid": "<vless-uuid>"     // optional
///     }
///   }
///
/// Delivered as `base64url(zlib(utf8(json)))` and accepted from three URL
/// shapes:
///
///   * `nesttalk://i/<blob>`
///   * `nesttalk://enroll?data=<blob>`
///   * `https://<host>/i/<blob>`
///
/// Spec caps the decompressed JSON at 800 bytes and rejects envelopes >
/// 4 KB base64url to defuse zlib-bomb shaped invites.
public struct EnrollmentPayload: Sendable, Equatable {
    public let code: String
    public let bootstrap: TransportConfig.Bootstrap?
    public let apiUuid: String?
    public let turnUuid: String?

    public var hasRealityBootstrap: Bool { bootstrap != nil }

    /// Parse an invite URL. Returns a payload with nil bootstrap if the URL
    /// doesn't carry a recognised v0.2.0 blob (empty / oversized / unknown
    /// transport kind). Mirrors the Dart decoder's "best-effort, return
    /// empty-token" posture for compatibility.
    public static func parse(_ raw: String) -> EnrollmentPayload {
        guard let blob = extractBlob(raw) else {
            return empty
        }
        guard blob.count <= 4 * 1024 else { return empty }
        guard let decoded = base64URLDecode(blob) else { return empty }
        guard let uncompressed = zlibInflate(decoded), uncompressed.count <= 800 else {
            return empty
        }
        guard let root = try? JSONSerialization.jsonObject(with: uncompressed) as? [String: Any] else {
            return empty
        }
        guard (root["v"] as? Int) == 1 else { return empty }
        let code = (root["code"] as? String) ?? ""
        guard let transport = root["transport"] as? [String: Any],
              (transport["kind"] as? String) == "reality",
              let addr = transport["server_addr"] as? String,
              let sni = transport["sni"] as? String,
              let pub = transport["public_key"] as? String,
              let sid = transport["short_id"] as? String
        else {
            return EnrollmentPayload(code: code, bootstrap: nil, apiUuid: nil, turnUuid: nil)
        }
        let (host, port) = parseHostPort(addr)
        let bootstrap = TransportConfig.Bootstrap(
            serverAddress: host,
            serverPort: port,
            serverName: sni,
            realityPublicKey: pub,
            realityShortID: sid
        )
        return EnrollmentPayload(
            code: code,
            bootstrap: bootstrap,
            apiUuid:  transport["api_uuid"]  as? String,
            turnUuid: transport["turn_uuid"] as? String
        )
    }

    private static let empty = EnrollmentPayload(code: "", bootstrap: nil, apiUuid: nil, turnUuid: nil)

    // MARK: - URL blob extraction

    private static func extractBlob(_ raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }

        // nesttalk://enroll?data=<blob>
        if url.scheme == "nesttalk", url.host == "enroll" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            return comps?.queryItems?.first(where: { $0.name == "data" })?.value
        }

        // nesttalk://i/<blob>
        if url.scheme == "nesttalk", url.host == "i" {
            let p = url.path
            return p.hasPrefix("/") ? String(p.dropFirst()) : p.isEmpty ? nil : p
        }

        // https://<host>/i/<blob>
        if url.scheme == "https" || url.scheme == "http" {
            let comps = url.pathComponents
            if comps.count >= 3, comps[1] == "i" {
                return comps[2]
            }
        }
        return nil
    }

    // MARK: - base64url without padding

    private static func base64URLDecode(_ input: String) -> Data? {
        var s = input.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    // MARK: - zlib inflate via the Compression framework

    /// Wraps Darwin's `Compression` framework. `Compression.COMPRESSION_ZLIB`
    /// expects **raw deflate** without the 2-byte zlib header or 4-byte Adler32
    /// footer, so we strip them before calling.
    private static func zlibInflate(_ data: Data) -> Data? {
        guard data.count >= 6 else { return nil }
        let deflateOnly = data.dropFirst(2).dropLast(4)
        let destinationCap = 8 * 1024  // 8 KB hard cap on decompressed output
        var output = Data(count: destinationCap)
        let written = output.withUnsafeMutableBytes { (outBuf: UnsafeMutableRawBufferPointer) -> Int in
            guard let outPtr = outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return deflateOnly.withUnsafeBytes { (inBuf: UnsafeRawBufferPointer) -> Int in
                guard let inPtr = inBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return compression_decode_buffer(
                    outPtr, destinationCap,
                    inPtr,  deflateOnly.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        if written == 0 { return nil }
        return output.prefix(written)
    }

    // MARK: - server_addr parse

    private static func parseHostPort(_ addr: String) -> (String, Int) {
        // Spec: "host:port" with host possibly a plain hostname or an IP.
        // v0.2.3 didn't handle IPv6-bracketed addresses; follow that.
        if let i = addr.lastIndex(of: ":") {
            let host = String(addr[..<i])
            let port = Int(addr[addr.index(after: i)...]) ?? 443
            return (host.isEmpty ? addr : host, port)
        }
        return (addr, 443)
    }
}
