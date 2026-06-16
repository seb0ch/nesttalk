import SwiftUI
import WebRTC

/// SwiftUI wrapper around WebRTC's Metal-backed video view. Renders a
/// remote `RTCVideoTrack` (or a local-preview track) on iOS via
/// `RTCMTLVideoView` and on macOS via `RTCMTLNSVideoView`.
public struct RTCVideoViewWrapper: View {
    public let track: RTCVideoTrack?
    public init(track: RTCVideoTrack?) {
        self.track = track
    }

    public var body: some View {
        Inner(track: track)
            .background(Color.black)
    }

    #if os(iOS)
    private struct Inner: UIViewRepresentable {
        let track: RTCVideoTrack?
        func makeUIView(context: Context) -> RTCMTLVideoView {
            let v = RTCMTLVideoView(frame: .zero)
            v.videoContentMode = .scaleAspectFill
            return v
        }
        func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
            if let track {
                track.add(uiView)
            }
        }
        static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: ()) {
            // RTCVideoTrack auto-removes the renderer on dealloc.
        }
    }
    #else
    /// macOS: `RTCMTLNSVideoView` requires stasel/WebRTC 140 — the 125
    /// macOS slice compiled the class out (see
    /// docs/ops/2026-04-29-macos-video.md). Unlike its iOS sibling it
    /// has no `videoContentMode`; aspect handling is renderer-default.
    private struct Inner: NSViewRepresentable {
        let track: RTCVideoTrack?
        func makeNSView(context: Context) -> RTCMTLNSVideoView {
            RTCMTLNSVideoView(frame: .zero)
        }
        func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) {
            if let track {
                track.add(nsView)
            }
        }
        static func dismantleNSView(_ nsView: RTCMTLNSVideoView, coordinator: ()) {
            // RTCVideoTrack auto-removes the renderer on dealloc.
        }
    }
    #endif
}
