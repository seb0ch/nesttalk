import SwiftUI

/// Home screen — iPhone chat list with family-circle shelf.
/// Ports `NTChatList` from `docs/design/nesttalk-bundle/project/nt-screens-1.jsx`.
public struct ChatListView: View {
    @Environment(\.hearth) private var palette
    public let chats: [ChatPreview]

    public init(chats: [ChatPreview] = ChatPreview.sample) {
        self.chats = chats
    }

    public var body: some View {
        ZStack(alignment: .top) {
            palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 32)
                    .padding(.bottom, 12)

                chatRoundedPanel
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nest")
                        .frauncesFont(size: 34, weight: .semibold)
                        .foregroundStyle(palette.ink)
                        .tracking(-0.8)
                    Text("8 in your circle · all safe")
                        .interFont(size: 13)
                        .foregroundStyle(palette.inkMuted)
                }
                Spacer()
                HStack(spacing: 10) {
                    circleButton(icon: "magnifyingglass", bg: palette.surface, fg: palette.ink, size: 40, iconSize: 19, stroke: true)
                    circleButton(icon: "plus",            bg: palette.brand,   fg: palette.bubbleOutInk, size: 40, iconSize: 20, stroke: false)
                }
            }
            FamilyCircleShelfView(members: chats)
        }
    }

    private var chatRoundedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ALL CHATS")
                .interFont(size: 11, weight: .semibold)
                .foregroundStyle(palette.inkMuted)
                .tracking(1.2)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(chats) { chat in
                        ChatRow(chat: chat)
                        Divider()
                            .background(palette.border)
                            .padding(.leading, 74)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            palette.surface
                .clipShape(RoundedCorner(radius: 28, corners: [.topLeft, .topRight]))
        )
    }

    private func circleButton(
        icon: String, bg: Color, fg: Color, size: CGFloat, iconSize: CGFloat, stroke: Bool
    ) -> some View {
        ZStack {
            Circle().fill(bg).frame(width: size, height: size)
            if stroke {
                Circle().stroke(palette.border, lineWidth: 0.5).frame(width: size, height: size)
            }
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(fg)
        }
    }
}

// MARK: - Chat row

private struct ChatRow: View {
    @Environment(\.hearth) private var palette
    let chat: ChatPreview

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HearthAvatar(name: chat.name, color: avatarColor, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(chat.name)
                        .frauncesFont(size: 17, weight: .semibold)
                        .foregroundStyle(palette.ink)
                    Spacer()
                    Text(chat.time)
                        .interFont(size: 12)
                        .foregroundStyle(chat.unread > 0 ? palette.brand : palette.inkSoft)
                }
                HStack {
                    Text(chat.last)
                        .interFont(size: 14)
                        .foregroundStyle(chat.unread > 0 ? palette.ink : palette.inkMuted)
                        .lineLimit(1)
                    Spacer()
                    if chat.unread > 0 {
                        Text("\(chat.unread)")
                            .interFont(size: 11, weight: .semibold)
                            .foregroundStyle(palette.bubbleOutInk)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(palette.brand))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var avatarColor: Color {
        switch chat.avatarColorIndex {
        case 0: return palette.avatar1
        case 1: return palette.avatar2
        case 2: return palette.avatar3
        default: return palette.avatar4
        }
    }
}

// MARK: - Rounded-top shape

private struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: Set<Corner>
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = radius
        let tl = corners.contains(.topLeft)     ? r : 0
        let tr = corners.contains(.topRight)    ? r : 0
        let br = corners.contains(.bottomRight) ? r : 0
        let bl = corners.contains(.bottomLeft)  ? r : 0
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                 radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                 radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                 radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                 radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        return p
    }
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
}
