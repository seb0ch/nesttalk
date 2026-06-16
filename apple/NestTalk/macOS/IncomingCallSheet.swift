#if os(macOS)
import SwiftUI

/// macOS lacks CallKit. We present a SwiftUI sheet when an inbound
/// `.incomingCall` arrives over the WS so the operator can accept or
/// decline. The sheet binds to a `IncomingCallSession` model fed by
/// `RestCallSignaling.events()`.
public struct IncomingCallSheet: View {
    @Environment(\.hearth) private var palette
    public let displayName: String
    public let onAccept: () -> Void
    public let onDecline: () -> Void

    public init(
        displayName: String,
        onAccept: @escaping () -> Void,
        onDecline: @escaping () -> Void
    ) {
        self.displayName = displayName
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "phone.fill.arrow.down.left")
                .font(.system(size: 56))
                .foregroundStyle(palette.brand)

            VStack(spacing: 4) {
                Text("Incoming call")
                    .interFont(size: 14)
                    .foregroundStyle(palette.inkMuted)
                Text(displayName)
                    .frauncesFont(size: 28, weight: .semibold)
                    .foregroundStyle(palette.ink)
            }

            HStack(spacing: 24) {
                Button(action: onDecline) {
                    HStack {
                        Image(systemName: "phone.down.fill")
                        Text("Decline")
                    }
                    .interFont(size: 14, weight: .semibold)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.red.opacity(0.92)))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: onAccept) {
                    HStack {
                        Image(systemName: "phone.fill")
                        Text("Accept")
                    }
                    .interFont(size: 14, weight: .semibold)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(palette.brand))
                    .foregroundStyle(palette.bubbleOutInk)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 360)
        .padding(28)
        .background(palette.surface)
    }
}

/// Compact in-call control bar overlaid on top of the chat window
/// during an active call. Mute, video toggle, end-call.
public struct OutgoingCallBar: View {
    @Environment(\.hearth) private var palette
    @Binding public var isMuted: Bool
    @Binding public var isVideoOn: Bool
    public let displayName: String
    public let onEnd: () -> Void

    public init(
        isMuted: Binding<Bool>,
        isVideoOn: Binding<Bool>,
        displayName: String,
        onEnd: @escaping () -> Void
    ) {
        self._isMuted = isMuted
        self._isVideoOn = isVideoOn
        self.displayName = displayName
        self.onEnd = onEnd
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.fill.connection")
                .foregroundStyle(palette.brand)
            Text("In call · \(displayName)")
                .interFont(size: 13, weight: .medium)
                .foregroundStyle(palette.ink)
            Spacer()
            Button { isMuted.toggle() } label: {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
            }
            .buttonStyle(.plain)
            Button { isVideoOn.toggle() } label: {
                Image(systemName: isVideoOn ? "video.fill" : "video.slash.fill")
            }
            .buttonStyle(.plain)
            Button(action: onEnd) {
                Image(systemName: "phone.down.fill")
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Circle().fill(Color.red))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(palette.surface)
        .overlay(Capsule().stroke(palette.border, lineWidth: 0.5))
        .clipShape(Capsule())
    }
}

#endif
