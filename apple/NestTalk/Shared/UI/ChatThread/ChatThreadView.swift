import SwiftUI

/// Chat thread (one-to-one) — header + E2E ribbon + timeline of bubbles.
/// Ports the chat-screen frame from
/// `docs/design/nesttalk-bundle/project/nt-screens-1.jsx`.
public struct ChatThreadView: View {
    @Environment(\.hearth) private var palette
    public let contact: ChatPreview
    public let messages: [ThreadMessage]

    public init(contact: ChatPreview, messages: [ThreadMessage] = .spikeSample) {
        self.contact = contact
        self.messages = messages
    }

    public var body: some View {
        ZStack(alignment: .top) {
            palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 32)
                    .padding(.bottom, 10)
                e2eRibbon
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(messages) { m in
                            MessageBubble(
                                text: m.text,
                                outgoing: m.outgoing,
                                time: m.time,
                                delivered: m.delivered
                            )
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(palette.ink)
            HearthAvatar(name: contact.name, color: palette.avatar1, size: 38)
            VStack(alignment: .leading, spacing: 0) {
                Text(contact.name)
                    .frauncesFont(size: 18, weight: .semibold)
                    .foregroundStyle(palette.ink)
                Text(contact.typing ? "typing…" : "active now")
                    .interFont(size: 12)
                    .foregroundStyle(palette.accent)
            }
            Spacer()
            Image(systemName: "phone.fill")
                .font(.system(size: 19))
                .foregroundStyle(palette.brand)
            Image(systemName: "video.fill")
                .font(.system(size: 19))
                .foregroundStyle(palette.brand)
        }
    }

    private var e2eRibbon: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 12))
                .foregroundStyle(palette.accent)
            Text("End-to-end encrypted — only Mom can read these")
                .interFont(size: 12, weight: .medium)
                .foregroundStyle(palette.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(palette.accentSoft)
        .clipShape(Capsule())
    }
}

public struct ThreadMessage: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String
    public let outgoing: Bool
    public let time: String?
    public let delivered: Bool
}

public extension Array where Element == ThreadMessage {
    static let spikeSample: [ThreadMessage] = [
        .init(text: "Hi sweetie! Did you land okay?", outgoing: false, time: "2:12 pm", delivered: false),
        .init(text: "Just landed 🧡", outgoing: true, time: "2:13 pm", delivered: true),
        .init(text: "Uber is on the way home — should be there in ~30 min.",
              outgoing: true, time: "2:13 pm", delivered: true),
        .init(text: "Call me when you're home, I want to hear about the flight",
              outgoing: false, time: "2:14 pm", delivered: false),
    ]
}
