import SwiftUI

/// Chat message bubble — 22-pt radius, bottom-right / bottom-left tail at
/// 8-pt on the sender's side. Direct port of `NTBubble` from
/// `docs/design/nesttalk-bundle/project/nt-components.jsx`.
public struct MessageBubble: View {
    @Environment(\.hearth) private var palette
    public let text: String
    public let outgoing: Bool
    public let time: String?
    public let delivered: Bool
    /// Peer has read the message — the check tints brand instead of
    /// accent. Implies `delivered` visually even when that flag is off.
    public let read: Bool
    public let tail: Bool
    public let small: Bool
    /// Max bubble width (design caps at 78% of the thread width,
    /// `nt-components.jsx` NTBubble `maxWidth: '78%'`). `nil` = uncapped.
    public let maxWidth: CGFloat?

    public init(
        text: String,
        outgoing: Bool,
        time: String? = nil,
        delivered: Bool = false,
        read: Bool = false,
        tail: Bool = true,
        small: Bool = false,
        maxWidth: CGFloat? = nil
    ) {
        self.text = text
        self.outgoing = outgoing
        self.time = time
        self.delivered = delivered
        self.read = read
        self.tail = tail
        self.small = small
        self.maxWidth = maxWidth
    }

    public var body: some View {
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 3) {
            Text(text)
                .interFont(size: 15.5)
                .foregroundStyle(outgoing ? palette.bubbleOutInk : palette.bubbleInInk)
                .tracking(-0.1)
                .lineSpacing(21 - 15.5)
                .frame(maxWidth: maxWidth, alignment: outgoing ? .trailing : .leading)
                .padding(.horizontal, small ? 14 : 16)
                .padding(.vertical,   small ?  8 : 10)
                .background(
                    BubbleShape(outgoing: outgoing, tail: tail)
                        .fill(outgoing ? palette.bubbleOut : palette.bubbleIn)
                        .shadow(color: outgoing ? .clear : palette.border, radius: 0, x: 0, y: 1)
                )

            if time != nil || delivered || read {
                HStack(spacing: 4) {
                    if let time {
                        Text(time)
                            .interFont(size: 11)
                            .foregroundStyle(palette.inkSoft)
                    }
                    if read {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.brand)
                    } else if delivered {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.accent)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }
}

private struct BubbleShape: Shape {
    let outgoing: Bool
    let tail: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 22
        let tailR: CGFloat = 8
        let brR: CGFloat = (outgoing && tail)  ? tailR : r
        let blR: CGFloat = (!outgoing && tail) ? tailR : r
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                 radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - brR))
        p.addArc(center: CGPoint(x: rect.maxX - brR, y: rect.maxY - brR),
                 radius: brR, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + blR, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + blR, y: rect.maxY - blR),
                 radius: blR, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                 radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        return p
    }
}
