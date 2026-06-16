import Foundation

public extension APIClient {
    /// Stamp a fresh W3C `traceparent` header on a request and log the
    /// trace-id (NTLogger `transport`) so it correlates with the server's
    /// `[req] trace=<id>` line. Call right after building a URLRequest for a
    /// traced flow (send / call / key-resolve). The server reads this id (or
    /// mints its own when absent) and echoes it in `X-NT-Trace-Id`.
    static func stampTrace(_ req: inout URLRequest, _ label: String) {
        let traceId = randomHex(16)   // 32 hex — W3C trace-id
        let spanId = randomHex(8)     // 16 hex — W3C parent/span-id
        req.setValue("00-\(traceId)-\(spanId)-01", forHTTPHeaderField: "traceparent")
        NTLogger.transport.debug("trace=\(traceId) \(label)")
    }

    private static func randomHex(_ count: Int) -> String {
        var g = SystemRandomNumberGenerator()
        var s = ""
        s.reserveCapacity(count * 2)
        for _ in 0..<count {
            s += String(format: "%02x", UInt8.random(in: 0...255, using: &g))
        }
        return s
    }
}
