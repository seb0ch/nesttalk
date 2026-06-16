import SwiftUI

/// Safety Center — the design surfaces safety three ways (a Settings row
/// "Safety center · Strong", the macOS sidebar "Nest is secure" footer, and
/// the contact E2E card) but ships no dedicated frame, so this screen is
/// built from the bundle's safety design-language (accentSoft cards, shield
/// tiles, 18-pt radius) over NestTalk's real posture: hybrid post-quantum
/// E2E (X25519 + ML-KEM-768), device keys held only in the Keychain, and
/// local history encrypted at rest. Copy is reassuring but never overclaims.
public struct SafetyCenterView: View {
    @Environment(\.hearth) private var palette
    @Environment(\.dismiss) private var dismiss

    /// Optional hook to open per-contact security-code verification.
    public var onVerifyContact: (() -> Void)?

    public init(onVerifyContact: (() -> Void)? = nil) {
        self.onVerifyContact = onVerifyContact
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusCard
                postureCard
                if onVerifyContact != nil {
                    verifyCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 26)
        }
        .background(palette.bg.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { header }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(palette.brand)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Spacer()
            Text("Safety center")
                .interFont(size: 16, weight: .semibold)
                .foregroundStyle(palette.ink)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 0.5)
        }
    }

    // MARK: Status hero card

    private var statusCard: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.accent)
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                }
            Text("Your nest is secure")
                .frauncesFont(size: 22, weight: .semibold)
                .foregroundStyle(palette.ink)
                .tracking(-0.4)
            Text("Every message and call is end-to-end encrypted. Only you and the people in your nest can read them.")
                .interFont(size: 13)
                .foregroundStyle(palette.inkMuted)
                .lineSpacing(19 - 13)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.accentSoft)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Posture rows

    private var postureCard: some View {
        VStack(spacing: 0) {
            postureRow(
                symbol: "key.horizontal.fill",
                title: "Post-quantum encryption",
                detail: "Hybrid X25519 + ML-KEM-768 protects every message, even against future quantum attacks."
            )
            divider
            postureRow(
                symbol: "iphone.gen3",
                title: "Keys stay on this device",
                detail: "Your private keys live only in this device's Keychain. The server only ever sees ciphertext."
            )
            divider
            postureRow(
                symbol: "internaldrive.fill",
                title: "History encrypted at rest",
                detail: "Messages stored on this device are sealed with a key only this device holds."
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.surface)
        )
    }

    private func postureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.brandSoft)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(palette.brand)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .interFont(size: 15, weight: .semibold)
                    .foregroundStyle(palette.ink)
                Text(detail)
                    .interFont(size: 12)
                    .foregroundStyle(palette.inkMuted)
                    .lineSpacing(17 - 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private var verifyCard: some View {
        Button { onVerifyContact?() } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(palette.brandSoft)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "qrcode")
                            .font(.system(size: 16))
                            .foregroundStyle(palette.brand)
                    }
                Text("Verify a security code")
                    .interFont(size: 15, weight: .medium)
                    .foregroundStyle(palette.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.inkSoft)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.surface)
            )
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle().fill(palette.border).frame(height: 0.5).padding(.leading, 60)
    }
}

#Preview {
    SafetyCenterView(onVerifyContact: {})
        .hearthTheme(.daylight)
}
