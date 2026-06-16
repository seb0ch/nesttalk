import SwiftUI

/// "Calls" tab. The design bundle defines the Calls *tab* in the bottom bar
/// (`nt-components.jsx` NTTabBar) but ships no dedicated calls-list frame, and
/// the client keeps no local call-history store yet (recent calls live only in
/// the server's admin-only `list-recent-calls`). So this is an honest, on-brand
/// empty state in the NestTalk design language; it becomes a real list once a
/// client-side history surface lands.
public struct CallsView: View {
    @Environment(\.hearth) private var palette

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            emptyState
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg.ignoresSafeArea())
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var header: some View {
        HStack {
            Text("Calls")
                .frauncesFont(size: 34, weight: .semibold)
                .foregroundStyle(palette.ink)
                .tracking(-0.8)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.brandSoft)
                .frame(width: 84, height: 84)
                .overlay {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(palette.brand)
                }
            Text("No recent calls")
                .frauncesFont(size: 22, weight: .semibold)
                .foregroundStyle(palette.ink)
                .tracking(-0.4)
            Text("Start a voice or video call from any chat. Calls in your nest are end-to-end encrypted.")
                .interFont(size: 14)
                .foregroundStyle(palette.inkMuted)
                .lineSpacing(20 - 14)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    CallsView()
        .hearthTheme(.daylight)
}
