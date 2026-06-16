import SwiftUI

/// Flat colored circle with initials, optional family ring — direct port of
/// `NTAvatar` from `docs/design/nesttalk-bundle/project/nt-components.jsx`.
public struct HearthAvatar: View {
    public let name: String
    public let color: Color
    public let size: CGFloat
    public let ring: Bool
    public let ringColor: Color?

    public init(
        name: String,
        color: Color,
        size: CGFloat = 44,
        ring: Bool = false,
        ringColor: Color? = nil
    ) {
        self.name = name
        self.color = color
        self.size = size
        self.ring = ring
        self.ringColor = ringColor
    }

    public var body: some View {
        let inner = Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Text(name.hearthInitials)
                    .font(Typography.inter(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
                    .tracking(-0.2)
            )
        if ring {
            inner
                .padding(1)
                .overlay(
                    Circle().stroke(ringColor ?? color, lineWidth: 2)
                )
                .frame(width: size + 6, height: size + 6)
        } else {
            inner
        }
    }
}
