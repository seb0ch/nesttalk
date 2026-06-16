import Foundation
import WebRTC
import AVFoundation

/// Wraps `RTCCameraVideoCapturer` and pipes frames into a WebRTC video
/// track. Works on iOS and macOS — stasel/WebRTC 140's macOS slice
/// exports `RTCCameraVideoCapturer` (the 125 build already did, but the
/// render side was missing; see docs/ops/2026-04-29-macos-video.md).
public final class VideoCapturer {

    public let videoSource: RTCVideoSource
    public let videoTrack: RTCVideoTrack
    private let capturer: RTCCameraVideoCapturer
    private var currentDevice: AVCaptureDevice?

    public init(factory: RTCPeerConnectionFactory, trackId: String = "video0") {
        self.videoSource = factory.videoSource()
        self.videoTrack = factory.videoTrack(with: videoSource, trackId: trackId)
        self.capturer = RTCCameraVideoCapturer(delegate: videoSource)
    }

    /// Start capturing at 30 fps. Caller must have requested
    /// AVCaptureDevice.requestAccess(for: .video) at app open time,
    /// NOT here mid-ring. iOS prefers the front camera; macOS built-in
    /// cameras report `.unspecified` position, so take the first device
    /// (external webcams included).
    public func start() async throws {
        let devices = RTCCameraVideoCapturer.captureDevices()
        #if os(iOS)
        let preferred = devices.first(where: { $0.position == .front }) ?? devices.first
        #else
        let preferred = devices.first
        #endif
        guard let device = preferred else {
            throw NSError(
                domain: "nesttalk.video",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no capture device"]
            )
        }
        try await startCapture(with: device)
    }

    public func stop() {
        capturer.stopCapture()
    }

    /// Flip front ↔ back camera on iOS; on macOS cycle to the next
    /// available device (no-op with a single built-in camera).
    public func flip() async throws {
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let current = currentDevice else { return }
        #if os(iOS)
        let target: AVCaptureDevice.Position = (current.position == .front) ? .back : .front
        guard let device = devices.first(where: { $0.position == target }) else { return }
        #else
        guard devices.count > 1,
              let idx = devices.firstIndex(of: current)
        else { return }
        let device = devices[(idx + 1) % devices.count]
        #endif
        try await startCapture(with: device)
    }

    private func startCapture(with device: AVCaptureDevice) async throws {
        self.currentDevice = device
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = pickFormat(from: formats)
        let fps = pickFps(from: format)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            capturer.startCapture(with: device, format: format, fps: fps) { err in
                if let err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            }
        }
    }

    private func pickFormat(from formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format {
        // Pick the highest-resolution format whose max dimension fits
        // within 1280×720 — keeps upload bandwidth in check for cellular
        // calls and matches v0.2.3 quality defaults.
        let target: Int32 = 720
        let chosen = formats
            .filter { CMVideoFormatDescriptionGetDimensions($0.formatDescription).height <= target }
            .max { lhs, rhs in
                CMVideoFormatDescriptionGetDimensions(lhs.formatDescription).height
                    < CMVideoFormatDescriptionGetDimensions(rhs.formatDescription).height
            }
        return chosen ?? formats.first!
    }

    private func pickFps(from format: AVCaptureDevice.Format) -> Int {
        let ranges = format.videoSupportedFrameRateRanges
        guard let r = ranges.first else { return 30 }
        return Int(min(r.maxFrameRate, 30))
    }
}
