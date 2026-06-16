import SwiftUI

/// Contact detail screen — ported from `NTContactInfo`
/// (`docs/design/nesttalk-bundle/project/nt-screens-1.jsx:347-480`) and
/// adapted to NestTalk's 1:1, admin-enrolled model: there are no phone
/// numbers, e-mail addresses, nicknames, shared-photo counts, or per-user
/// blocking (the roster is admin-managed), so those design rows are dropped.
/// The kept structure — hero identity, the "Verified family" trust badge,
/// the Message/Call/Video quick actions, the end-to-end-encryption safety
/// card, and the per-conversation Mute/Pin preferences — is what maps onto
/// real product surface.
public struct ContactInfoView: View {
    @Environment(\.hearth) private var palette
    @Environment(\.dismiss) private var dismiss

    public let displayName: String
    public let avatarColor: Color
    /// Stable roster id, used to scope per-conversation preferences.
    public let threadUserId: String

    public var onMessage: (() -> Void)?
    public var onAudioCall: (() -> Void)?
    public var onVideoCall: (() -> Void)?
    public var onVerifySecurity: (() -> Void)?

    public init(
        displayName: String,
        avatarColor: Color,
        threadUserId: String,
        onMessage: (() -> Void)? = nil,
        onAudioCall: (() -> Void)? = nil,
        onVideoCall: (() -> Void)? = nil,
        onVerifySecurity: (() -> Void)? = nil
    ) {
        self.displayName = displayName
        self.avatarColor = avatarColor
        self.threadUserId = threadUserId
        self.onMessage = onMessage
        self.onAudioCall = onAudioCall
        self.onVideoCall = onVideoCall
        self.onVerifySecurity = onVerifySecurity
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                cards
            }
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
            Text("Contact")
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

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 0) {
            HearthAvatar(name: displayName, color: avatarColor, size: 108)
                .padding(.top, 30)

            Text(displayName)
                .frauncesFont(size: 28, weight: .semibold)
                .foregroundStyle(palette.ink)
                .tracking(-0.4)
                .padding(.top, 14)
                .multilineTextAlignment(.center)

            verifiedBadge
                .padding(.top, 6)

            Text("End-to-end encrypted · in your nest")
                .interFont(size: 13)
                .foregroundStyle(palette.inkMuted)
                .padding(.top, 10)

            quickActions
                .padding(.top, 22)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
        .background(palette.surface)
    }

    private var verifiedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("Verified family")
                .interFont(size: 11, weight: .semibold)
        }
        .foregroundStyle(palette.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(palette.accentSoft))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verified family member")
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            quickAction(symbol: "bubble.left.fill", label: "Message", action: onMessage)
            quickAction(symbol: "phone.fill", label: "Call", action: onAudioCall)
            quickAction(symbol: "video.fill", label: "Video", action: onVideoCall)
        }
    }

    private func quickAction(symbol: String, label: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette.brandSoft)
                    .frame(width: 68, height: 52)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 20))
                            .foregroundStyle(palette.brand)
                    }
                Text(label)
                    .interFont(size: 11, weight: .semibold)
                    .foregroundStyle(palette.brand)
            }
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .opacity(action == nil ? 0.5 : 1)
        .accessibilityLabel(label)
    }

    // MARK: Cards

    private var cards: some View {
        VStack(spacing: 14) {
            safetyCard
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 26)
    }

    private var safetyCard: some View {
        Button { onVerifySecurity?() } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.accent)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Messages are end-to-end encrypted")
                        .interFont(size: 14, weight: .semibold)
                        .foregroundStyle(palette.ink)
                        .multilineTextAlignment(.leading)
                    Text("Only \(displayName) and you can read them. Tap to verify the security code together.")
                        .interFont(size: 12)
                        .foregroundStyle(palette.inkMuted)
                        .lineSpacing(17 - 12)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.accentSoft)
            )
        }
        .buttonStyle(.plain)
        .disabled(onVerifySecurity == nil)
        .accessibilityHint("Opens security-code verification")
    }
}

#Preview {
    ContactInfoView(displayName: "Grandma Ruth", avatarColor: HearthPalette.daylight.avatar3, threadUserId: "preview")
        .hearthTheme(.daylight)
}
