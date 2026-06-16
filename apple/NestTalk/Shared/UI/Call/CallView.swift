import SwiftUI
import WebRTC

/// Full-screen call UI — remote video fills the frame, local preview
/// rides as a PiP tile, controls along the bottom. Visual frame from
/// `docs/design/nesttalk-bundle/project/nt-screens-2.jsx` (call frame).
/// Drives and observes `CallCoordinator`.
public struct CallView: View {
    @Environment(\.hearth) private var palette
    @ObservedObject var coordinator: CallCoordinator

    public init(coordinator: CallCoordinator) {
        self.coordinator = coordinator
    }

    private var contactName: String {
        switch coordinator.phase {
        case .outgoingRinging(_, let peer), .active(_, let peer),
             .incomingRinging(_, let peer, _):
            return peer.displayName
        case .idle:
            return ""
        }
    }

    private var statusLine: String {
        switch coordinator.phase {
        case .outgoingRinging: return "Calling…"
        // CallView only renders for `.incomingRinging` once the user has
        // answered (see CallOverlay), so this surfaces during the connect.
        case .incomingRinging: return "Connecting…"
        case .active:          return coordinator.isReconnecting ? "Reconnecting…" : "Connected"
        case .idle:            return ""
        }
    }

    public var body: some View {
        ZStack {
            // Remote video — or the ink backdrop + avatar while the
            // peer's track hasn't arrived (audio call / still ringing).
            palette.ink.ignoresSafeArea()
            if let remote = coordinator.remoteVideoTrack {
                RTCVideoViewWrapper(track: remote)
                    .ignoresSafeArea()
            }

            VStack {
                // Top bar
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contactName)
                            .frauncesFont(size: 22, weight: .semibold)
                            .foregroundStyle(.white)
                        Text(statusLine)
                            .interFont(size: 12)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    // Local preview PiP (video calls with a live capturer).
                    if coordinator.isVideoEnabled, let local = coordinator.localVideoTrack {
                        RTCVideoViewWrapper(track: local)
                            .frame(width: 92, height: 128)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(.white.opacity(0.25), lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 40)

                Spacer()

                // Avatar placeholder while no remote video renders.
                if coordinator.remoteVideoTrack == nil {
                    HearthAvatar(name: contactName, color: palette.brand, size: 88)
                        .scaleEffect(1.2)
                }

                Spacer()

                // Controls
                HStack(spacing: 24) {
                    // Mute/video toggles are no-ops until the media session
                    // exists (no capturer yet during the connect window);
                    // disable them so a tap can't desync the UI from the
                    // track that later starts enabled.
                    callButton(
                        icon: coordinator.isMuted ? "mic.slash.fill" : "mic.fill",
                        background: .white.opacity(coordinator.isMuted ? 0.45 : 0.2),
                        enabled: coordinator.mediaReady
                    ) { coordinator.toggleMute() }
                    callButton(
                        icon: coordinator.isVideoEnabled ? "video.fill" : "video.slash.fill",
                        background: .white.opacity(coordinator.isVideoEnabled ? 0.2 : 0.45),
                        enabled: coordinator.mediaReady
                    ) { coordinator.toggleVideo() }
                    callButton(
                        icon: "phone.down.fill",
                        background: Color(hex: 0xE53E3E),
                        large: true
                    ) { coordinator.hangUp() }
                }
                .padding(.bottom, 48)
            }
        }
    }

    private func callButton(
        icon: String, background: Color, large: Bool = false,
        enabled: Bool = true, onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            Image(systemName: icon)
                .font(.system(size: large ? 24 : 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: large ? 72 : 56, height: large ? 72 : 56)
                .background(Circle().fill(background))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Overlay router for the call surfaces — mounted above the connected
/// shell in `AppRouter`. iOS ringing is CallKit's full-screen system UI,
/// so the in-app overlay only appears for outgoing/active phases there;
/// macOS additionally renders the `IncomingCallSheet` card.
public struct CallOverlay: View {
    @ObservedObject var coordinator: CallCoordinator

    public init(coordinator: CallCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        switch coordinator.phase {
        case .idle:
            EmptyView()
        case .incomingRinging(_, let peer, _):
            if coordinator.isAnswering {
                // Answered — show the connecting call surface immediately.
                // Phase stays `.incomingRinging` until media is up, but the
                // ring UI (CallKit on iOS, the sheet on macOS) is gone the
                // instant the user accepts; without this the user stares at
                // the chat list while `performAccept` sets up media.
                CallView(coordinator: coordinator)
            } else {
                #if os(macOS)
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    IncomingCallSheet(
                        displayName: peer.displayName,
                        onAccept: { coordinator.acceptIncomingCall() },
                        onDecline: { coordinator.declineIncomingCall() }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(radius: 24)
                }
                #else
                // CallKit owns the iOS ring surface.
                EmptyView()
                #endif
            }
        case .outgoingRinging, .active:
            CallView(coordinator: coordinator)
        }
    }
}
