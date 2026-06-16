import XCTest
import WebRTC
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

/// Guards the WebRTC video pipeline against dependency regressions.
/// stasel/WebRTC 125 shipped a macOS slice with RTCMTLNSVideoView
/// compiled out, and 141+ ship it without per-class headers — both
/// break this suite at link or build time. See
/// docs/ops/2026-04-29-macos-video.md.
final class VideoPipelineTests: XCTestCase {

    func test_videoCapturer_builds_track_on_this_platform() {
        let service = CallService()
        let capturer = VideoCapturer(factory: service.factory)
        XCTAssertEqual(capturer.videoTrack.trackId, "video0")
        XCTAssertEqual(capturer.videoTrack.kind, "video")
        // Headless CI machines may have zero devices; the API itself
        // must still be callable on both platforms.
        _ = RTCCameraVideoCapturer.captureDevices()
        capturer.stop()
    }

    #if os(macOS)
    @MainActor
    func test_metal_video_view_attaches_as_renderer() {
        let view = RTCMTLNSVideoView(frame: .zero)
        let service = CallService()
        let source = service.factory.videoSource()
        let track = service.factory.videoTrack(with: source, trackId: "video-test")
        track.add(view)
        track.remove(view)
    }
    #endif
}
