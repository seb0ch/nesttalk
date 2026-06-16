import SwiftUI

/// Minimal settings surface — appearance, log export, version,
/// re-enroll. Presented as a sheet from the chat-list gear button.
public struct SettingsView: View {
    @Environment(\.hearth) private var palette
    @Environment(\.dismiss) private var dismiss
    @AppStorage("nt.palette") private var paletteChoice: String = "auto"
    @State private var showReEnrollConfirm = false
    @State private var logExportURL: URL?

    /// Wipes the enrolled identity + session and routes back to
    /// onboarding. Injected so the view stays decoupled from AppState.
    public let onReEnroll: () -> Void
    /// `true` when hosted as the iPhone "You" tab (inside a NavigationStack):
    /// drops the sheet's X-close, uses the design's large "You" title, and
    /// surfaces the Safety Center push. `false` is the macOS gear sheet.
    public let embedded: Bool

    public init(embedded: Bool = false, onReEnroll: @escaping () -> Void = {}) {
        self.embedded = embedded
        self.onReEnroll = onReEnroll
    }

    private static let paletteOptions: [(value: String, label: String)] = [
        ("auto", "Auto"),
        ("daylight", "Daylight"),
        ("nightlight", "Nightlight"),
        ("paper", "Paper"),
    ]

    public var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section("Appearance") {
                    Picker("Palette", selection: $paletteChoice) {
                        ForEach(Self.paletteOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if embedded {
                    Section("Safety") {
                        NavigationLink {
                            SafetyCenterView()
                        } label: {
                            Label("Safety center", systemImage: "lock.shield")
                        }
                    }
                }

                Section("Support") {
                    if let url = logExportURL {
                        ShareLink(item: url) {
                            Label("Export logs (last 7 days)", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Label("No logs to export yet", systemImage: "doc.text")
                            .foregroundStyle(palette.inkMuted)
                    }
                    LabeledContent("Version", value: Self.versionString)
                }

                Section {
                    Button(role: .destructive) {
                        showReEnrollConfirm = true
                    } label: {
                        Label("Re-enroll this device", systemImage: "arrow.triangle.2.circlepath")
                    }
                } footer: {
                    Text("Removes this device's session and returns to the invite screen. Your message history stays on the device; you'll need a fresh invite from the family admin.")
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: embedded ? nil : 420, minHeight: embedded ? nil : 380)
        #if os(iOS)
        .toolbar(embedded ? .hidden : .automatic, for: .navigationBar)
        #endif
        .onAppear { logExportURL = Self.prepareLogExport() }
        .confirmationDialog(
            "Re-enroll this device?",
            isPresented: $showReEnrollConfirm,
            titleVisibility: .visible
        ) {
            Button("Re-enroll", role: .destructive) {
                dismiss()
                onReEnroll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need a fresh invite to reconnect.")
        }
    }

    private var header: some View {
        HStack {
            Text(embedded ? "You" : "Settings")
                .frauncesFont(size: embedded ? 34 : 22, weight: .semibold)
                .foregroundStyle(palette.ink)
                .tracking(embedded ? -0.8 : 0)
            Spacer()
            if !embedded {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(palette.inkSoft)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    static var versionString: String { AppVersion.string }

    /// Concatenate the NTLogger daily files into one shareable text
    /// file in the temp dir. Logs carry envelope metadata + error
    /// codes only — never message content (NTLogger contract).
    static func prepareLogExport() -> URL? {
        let dir = NTLogger.defaultBaseURL()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        let logs = entries.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !logs.isEmpty else { return nil }

        var merged = Data()
        for file in logs {
            merged.append(Data("===== \(file.lastPathComponent) =====\n".utf8))
            merged.append((try? Data(contentsOf: file)) ?? Data())
            merged.append(Data("\n".utf8))
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("nesttalk-logs.txt")
        guard (try? merged.write(to: out, options: .atomic)) != nil else { return nil }
        return out
    }
}
