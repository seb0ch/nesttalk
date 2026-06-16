import SwiftUI

/// Welcome / login screen — hero icon + family-first voice + primary CTA.
/// Ports the onboarding frame in
/// `docs/design/nesttalk-bundle/project/nt-screens-2.jsx`.
public struct WelcomeView: View {
    @Environment(\.hearth) private var palette
    public var onScanInvite: () -> Void
    public var onPasteInvite: () -> Void

    public init(
        onScanInvite:  @escaping () -> Void = {},
        onPasteInvite: @escaping () -> Void = {}
    ) {
        self.onScanInvite  = onScanInvite
        self.onPasteInvite = onPasteInvite
    }

    public var body: some View {
        ZStack {
            // Flat background — the design's onboarding uses the icon's
            // own drop-shadow as the only depth cue (nt-screens-2.jsx).
            palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("NestTalk")
                        .frauncesFont(size: 18, weight: .semibold)
                        .foregroundStyle(palette.ink)
                        .tracking(-0.3)
                    Spacer()
                }
                .padding(.top, 8)

                Spacer()
                hero
                Spacer().frame(height: 40)
                titleBlock
                Spacer().frame(height: 56)
                ctas
                Spacer()
                Text("Version: \(AppVersion.string)")
                    .monoFont(size: 10)
                    .foregroundStyle(palette.inkMuted.opacity(0.7))
                    .padding(.bottom, 6)
            }
            .padding(.horizontal, 28)
        }
    }

    private var hero: some View {
        Image("LoginHero")
            .resizable()
            .scaledToFit()
            .frame(width: 200, height: 200)
            .shadow(color: palette.brand.opacity(0.33), radius: 40, x: 0, y: 20)
            .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(spacing: 12) {
            Text("A private nest\nfor your people.")
                .frauncesFont(size: 36, weight: .semibold)
                .foregroundStyle(palette.ink)
                .tracking(-0.8)
                .lineSpacing(36 * 0.08)
                .multilineTextAlignment(.center)
            Text("End-to-end encrypted messages and calls — just for family.")
                .interFont(size: 15)
                .foregroundStyle(palette.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
    }

    #if os(macOS)
    // macOS has no camera invite-scan path (the scan view is paste-only),
    // so the desktop welcome shows a SINGLE primary CTA — the paste/link
    // action promoted to the filled brand style — and width-constrained so
    // it doesn't stretch across the whole window.
    private var ctas: some View {
        Button(action: onPasteInvite) {
            Text("I have a text invite")
                .interFont(size: 16, weight: .semibold)
                .foregroundStyle(palette.bubbleOutInk)
                .frame(maxWidth: 280, minHeight: 52)
                .background(Capsule().fill(palette.brand))
        }
        .buttonStyle(.plain)
    }
    #else
    private var ctas: some View {
        VStack(spacing: 14) {
            Button(action: onScanInvite) {
                Text("Scan invite")
                    .interFont(size: 16, weight: .semibold)
                    .foregroundStyle(palette.bubbleOutInk)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Capsule().fill(palette.brand))
            }
            .buttonStyle(.plain)

            Button(action: onPasteInvite) {
                Text("I have a text invite")
                    .interFont(size: 15, weight: .medium)
                    .foregroundStyle(palette.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Capsule().stroke(palette.borderStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
    #endif
}
