import SwiftUI

/// Invite entry screen. iOS uses the camera-based QR scanner by
/// default with a fallback to paste-mode; macOS is paste-only (the
/// stasel/WebRTC + AVCapture pair on macOS doesn't ship a working
/// continuation-camera path through the QR pipeline yet).
public struct InviteScanView: View {
    @Environment(\.hearth) private var palette
    @State private var pasted: String = ""
    @State private var parseError: String? = nil
    @FocusState private var pasteFocused: Bool
    #if os(iOS)
    @State private var mode: Mode = .scan
    private enum Mode: Equatable { case scan, paste }
    #endif
    public let onSubmit: (EnrollmentPayload) -> Void
    public let onBack: () -> Void

    public init(
        onSubmit: @escaping (EnrollmentPayload) -> Void,
        onBack: @escaping () -> Void = {}
    ) {
        self.onSubmit = onSubmit
        self.onBack = onBack
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                Text("Back")
            }
            .interFont(size: 15, weight: .medium)
            .foregroundStyle(palette.brand)
        }
        .buttonStyle(.plain)
    }

    private func submit(_ raw: String) {
        NSLog("[invite] submit called raw.count=\(raw.count)")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            NSLog("[invite] empty")
            parseError = "Paste a nesttalk:// or https:// invite link first."
            return
        }
        let payload = EnrollmentPayload.parse(trimmed)
        NSLog("[invite] parsed: hasReality=\(payload.hasRealityBootstrap) code=\(payload.code) apiUuid=\(payload.apiUuid ?? "nil") turnUuid=\(payload.turnUuid ?? "nil")")
        guard payload.hasRealityBootstrap else {
            parseError = "Invite link is missing transport details. Ask the admin to issue a new one."
            return
        }
        parseError = nil
        NSLog("[invite] calling onSubmit")
        onSubmit(payload)
    }

    public var body: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            #if os(iOS)
            switch mode {
            case .scan:  scanContent
            case .paste: pasteContent
            }
            #else
            pasteContent
            #endif
        }
    }

    // MARK: - iOS scan path

    #if os(iOS)
    private var scanContent: some View {
        ZStack {
            QRScannerView { value in
                submit(value)
            }
            .ignoresSafeArea()

            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.7), lineWidth: 2)
                    .frame(width: 240, height: 240)
                Text("Point at the QR on your invite screen")
                    .interFont(size: 13, weight: .medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                    .padding(.top, 8)
                Spacer()
                Button {
                    mode = .paste
                } label: {
                    Text("Use text invite instead")
                        .interFont(size: 14, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 18)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 32)
            }
        }
    }
    #endif

    // MARK: - Paste path

    private var pasteContent: some View {
        // ScrollView + .scrollDismissesKeyboard so the user can swipe
        // the keyboard away with a vertical drag and reach the
        // submit button. The keyboard toolbar also provides an
        // explicit Done button so the keyboard never strands them.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                backButton
                Text("Paste your invite")
                    .frauncesFont(size: 28, weight: .semibold)
                    .foregroundStyle(palette.ink)
                    .tracking(-0.5)
                Text("Paste the `nesttalk://…` or `https://…` invite link you received.")
                    .interFont(size: 14)
                    .foregroundStyle(palette.inkMuted)

                TextEditor(text: $pasted)
                    .monoFont(size: 13)
                    .foregroundStyle(palette.ink)
                    .focused($pasteFocused)
                    .frame(minHeight: 120, maxHeight: 220)
                    .padding(10)
                    .background(palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(palette.borderStrong, lineWidth: 0.5)
                    )

                Button {
                    pasteFocused = false
                    submit(pasted)
                } label: {
                    Text("Join family")
                        .interFont(size: 16, weight: .semibold)
                        .foregroundStyle(palette.bubbleOutInk)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(palette.brand))
                }
                .buttonStyle(.plain)
                .disabled(pasted.isEmpty)
                .opacity(pasted.isEmpty ? 0.4 : 1.0)

                if let parseError {
                    Text(parseError)
                        .interFont(size: 13, weight: .medium)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }

                #if os(iOS)
                Button {
                    pasteFocused = false
                    mode = .scan
                } label: {
                    Text("Scan QR instead")
                        .interFont(size: 14, weight: .medium)
                        .foregroundStyle(palette.brand)
                }
                .buttonStyle(.plain)
                #endif

                Spacer(minLength: 80)
            }
            .padding(24)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { pasteFocused = false }
            }
        }
        #endif
    }
}
