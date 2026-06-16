import Foundation

/// WebRTC signaling payload relayed peer-to-peer through the server's
/// `call_signal` WS frames. JSON shape is frozen by v0.2.3's
/// `call_media_session.dart`:
///
///   {"kind":"offer","sdp":...}            {"kind":"answer","sdp":...}
///   {"kind":"ice_restart_offer","sdp":...} / "ice_restart_answer"
///   {"kind":"ice","candidate":...,"sdpMid":...,"sdpMLineIndex":...}
///
/// The server never inspects the payload — it only checks the sender is
/// a participant of a live call before relaying.
public enum CallSignalPayload: Equatable, Sendable {
    case offer(sdp: String)
    case answer(sdp: String)
    case iceRestartOffer(sdp: String)
    case iceRestartAnswer(sdp: String)
    case ice(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?)
}

extension CallSignalPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, sdp, candidate, sdpMid, sdpMLineIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "offer":
            self = .offer(sdp: try c.decode(String.self, forKey: .sdp))
        case "answer":
            self = .answer(sdp: try c.decode(String.self, forKey: .sdp))
        case "ice_restart_offer":
            self = .iceRestartOffer(sdp: try c.decode(String.self, forKey: .sdp))
        case "ice_restart_answer":
            self = .iceRestartAnswer(sdp: try c.decode(String.self, forKey: .sdp))
        case "ice":
            self = .ice(
                candidate: try c.decode(String.self, forKey: .candidate),
                sdpMid: try c.decodeIfPresent(String.self, forKey: .sdpMid),
                sdpMLineIndex: try c.decodeIfPresent(Int32.self, forKey: .sdpMLineIndex)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown call_signal kind '\(kind)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .offer(let sdp):
            try c.encode("offer", forKey: .kind)
            try c.encode(sdp, forKey: .sdp)
        case .answer(let sdp):
            try c.encode("answer", forKey: .kind)
            try c.encode(sdp, forKey: .sdp)
        case .iceRestartOffer(let sdp):
            try c.encode("ice_restart_offer", forKey: .kind)
            try c.encode(sdp, forKey: .sdp)
        case .iceRestartAnswer(let sdp):
            try c.encode("ice_restart_answer", forKey: .kind)
            try c.encode(sdp, forKey: .sdp)
        case .ice(let candidate, let sdpMid, let sdpMLineIndex):
            try c.encode("ice", forKey: .kind)
            try c.encode(candidate, forKey: .candidate)
            try c.encodeIfPresent(sdpMid, forKey: .sdpMid)
            try c.encodeIfPresent(sdpMLineIndex, forKey: .sdpMLineIndex)
        }
    }

    /// Decode from the raw `payload` JSON carried by an inbound
    /// `ControlEvent.callSignal`. Returns nil for unknown kinds so a
    /// newer peer doesn't break an older client.
    public static func from(json data: Data) -> CallSignalPayload? {
        try? JSONDecoder().decode(CallSignalPayload.self, from: data)
    }
}
