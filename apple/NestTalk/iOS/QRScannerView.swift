#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit

/// Camera-based QR scanner for iOS invite onboarding. Wraps
/// `AVCaptureSession` + `AVCaptureMetadataOutput` filtering `.qr` and
/// surfaces the first valid `nesttalk://` or `https://` URL via
/// `onResult`. The user can tap "Use text invite instead" to fall back
/// to paste mode.
public struct QRScannerView: UIViewControllerRepresentable {
    public let onResult: (String) -> Void

    public init(onResult: @escaping (String) -> Void) {
        self.onResult = onResult
    }

    public func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onResult = onResult
        return vc
    }

    public func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}

    public final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onResult: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
        }

        public override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Permission must be requested explicitly before the
            // capture session can deliver frames; without this, iOS
            // never even shows the system prompt — the camera just
            // stays black. We ask on first appearance so the prompt
            // is the first thing the user sees.
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted { self?.bringUpSession() }
                    }
                }
            case .authorized:
                bringUpSession()
            case .denied, .restricted:
                // Surface a tap-target the user can use to bail out
                // to the paste path. The parent view already provides
                // the paste fallback; we just leave the screen black
                // until they back out.
                break
            @unknown default:
                break
            }
        }

        private func bringUpSession() {
            if session.inputs.isEmpty {
                configureSession()
            }
            if !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.session.startRunning()
                }
            }
        }

        public override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        public override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        private func configureSession() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer
        }

        public func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard
                let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                object.type == .qr,
                let value = object.stringValue
            else { return }
            // Filter for the schemes we accept; ignore other QRs.
            guard value.hasPrefix("nesttalk://") || value.hasPrefix("https://") else {
                return
            }
            // Capture once.
            session.stopRunning()
            onResult?(value)
        }
    }
}
#endif
