import SwiftUI

/// Horizontal strip of family members with a 52-pt avatar ring below the
/// "Family circle" eyebrow. Matches the mocks in `nt-screens-1.jsx` —
/// section "Nest shelf".
public struct FamilyCircleShelfView: View {
    @Environment(\.hearth) private var palette
    public let members: [ChatPreview]

    public init(members: [ChatPreview]) {
        self.members = members.filter { $0.nest != nil }.prefix(5).map { $0 }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("FAMILY CIRCLE")
                    .interFont(size: 11, weight: .semibold)
                    .foregroundStyle(palette.inkMuted)
                    .tracking(1.2)
                Spacer()
                Text("View all")
                    .interFont(size: 12, weight: .semibold)
                    .foregroundStyle(palette.brand)
            }
            .padding(.bottom, 10)

            HStack(spacing: 14) {
                ForEach(members) { chat in
                    VStack(spacing: 6) {
                        HearthAvatar(
                            name: chat.name,
                            color: avatarColor(for: chat),
                            size: 52,
                            ring: true,
                            ringColor: palette.brandSoft
                        )
                        Text(chat.name.split(separator: " ").first.map(String.init) ?? chat.name)
                            .interFont(size: 11, weight: .medium)
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 58)
                    }
                }
            }
        }
    }

    private func avatarColor(for chat: ChatPreview) -> Color {
        switch chat.avatarColorIndex {
        case 0: return palette.avatar1
        case 1: return palette.avatar2
        case 2: return palette.avatar3
        default: return palette.avatar4
        }
    }
}
