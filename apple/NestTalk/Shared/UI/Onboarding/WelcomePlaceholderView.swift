import SwiftUI

/// Empty-state for the iPad / macOS detail pane when no chat is
/// selected. Same brand-tinted background as the live thread view, so
/// the transition into a selection feels continuous.
public struct WelcomePlaceholderView: View {
    @Environment(\.hearth) private var palette

    public init() {}

    public var body: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 56))
                    .foregroundStyle(palette.brand.opacity(0.6))
                Text("Pick a conversation")
                    .frauncesFont(size: 22, weight: .semibold)
                    .foregroundStyle(palette.ink)
                Text("Tap a name on the left to read or reply.")
                    .interFont(size: 13)
                    .foregroundStyle(palette.inkMuted)
            }
        }
    }
}
