import SwiftUI
import GRDB
import GRDBQuery

/// Live chat thread backed by `MessageStore`. Used by `AppRouter` in
/// the connected phase so messages persisted by `MessageReceiveService`
/// stream into the UI via `ValueObservation`. Compose bar wired to
/// `MessageSendService` (env-injected by AppRouter).
///
/// Visual layout follows `nt-screens-1.jsx` `NTChatScreen`: surface
/// header strip with avatar + active-now indicator + phone/video
/// affordances, an end-to-end-encrypted ribbon under a date divider,
/// timestamped bubbles, and a capsule compose bar with a leading "+"
/// and trailing send button.
public struct LiveChatThreadView: View {
    @Environment(\.hearth) private var palette
    @Environment(\.messageStore) private var storeBox
    @Environment(\.messageSendService) private var sendService

    @State private var draft: String = ""
    @State private var isSending = false

    public let threadUserId: String
    public let displayName: String
    public let onBack: () -> Void
    /// Invoked with the call kind ("audio" | "video") when the user
    /// taps a header call affordance. nil hides the buttons' action
    /// (previews / tests without a call stack).
    public let onStartCall: ((String) -> Void)?
    /// Fires on every compose-bar keystroke — AppRouter wires it to
    /// TypingService so the peer sees "typing…".
    public let onTyping: (() -> Void)?
    /// Overrides the local-only read stamp with the server-acking path
    /// (AppState.markThreadRead). nil falls back to store-local marking.
    public let onMarkRead: (() -> Void)?
    /// Set/clear a reaction: (message, emoji-or-nil).
    public let onReact: ((MessageStore.Message, String?) -> Void)?
    /// Opens the contact-detail screen (tap on the thread header identity).
    public let onOpenContact: (() -> Void)?
    /// Inbound typing state for the header subtitle.
    @ObservedObject var typingObserver: TypingObserver

    public init(
        threadUserId: String,
        displayName: String,
        onBack: @escaping () -> Void = {},
        onStartCall: ((String) -> Void)? = nil,
        onTyping: (() -> Void)? = nil,
        onMarkRead: (() -> Void)? = nil,
        onReact: ((MessageStore.Message, String?) -> Void)? = nil,
        onOpenContact: (() -> Void)? = nil,
        typingObserver: TypingObserver = .inert
    ) {
        self.threadUserId = threadUserId
        self.displayName = displayName
        self.onBack = onBack
        self.onStartCall = onStartCall
        self.onTyping = onTyping
        self.onMarkRead = onMarkRead
        self.onReact = onReact
        self.onOpenContact = onOpenContact
        self.typingObserver = typingObserver
    }

    public var body: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            if let store = storeBox {
                content(store: store)
            } else {
                Text("MessageStore not configured")
                    .foregroundStyle(palette.inkMuted)
            }
        }
    }

    private func content(store: MessageStore) -> some View {
        let context: DatabaseContext = .readWrite { store.dbQueue }
        return LiveThreadBody(
            threadUserId: threadUserId,
            displayName: displayName,
            draft: $draft,
            isSending: $isSending,
            onSend: { text in
                Task { await sendMessage(text) }
            },
            onBack: onBack,
            onMarkRead: onMarkRead ?? { [weak store] in
                guard let store else { return }
                try? store.markThreadRead(threadUserId: threadUserId)
            },
            onStartCall: onStartCall,
            onTyping: onTyping,
            onReact: onReact,
            onOpenContact: onOpenContact,
            typingObserver: typingObserver
        )
        .databaseContext(context)
    }

    private func sendMessage(_ text: String) async {
        guard !text.isEmpty, let svc = sendService else { return }
        isSending = true
        _ = await svc.send(text: text, toUserId: threadUserId)
        isSending = false
        draft = ""
    }
}

private struct LiveThreadBody: View {
    @Environment(\.hearth) private var palette
    @Query<ThreadMessagesQuery> private var messages: [MessageStore.Message]
    @Query<ThreadReactionsQuery> private var reactions: [MessageStore.Reaction]
    @FocusState private var composeFocused: Bool
    /// Width of the message column, for the 78% bubble cap (NTBubble).
    @State private var contentWidth: CGFloat = 0

    @Binding var draft: String
    @Binding var isSending: Bool
    let threadUserId: String
    let displayName: String
    let onSend: (String) -> Void
    let onBack: () -> Void
    let onMarkRead: () -> Void
    let onStartCall: ((String) -> Void)?
    let onTyping: (() -> Void)?
    let onReact: ((MessageStore.Message, String?) -> Void)?
    let onOpenContact: (() -> Void)?
    @ObservedObject var typingObserver: TypingObserver

    static let reactionChoices = ["🧡", "👍", "😂", "😮", "😢", "🙏"]

    init(
        threadUserId: String,
        displayName: String,
        draft: Binding<String>,
        isSending: Binding<Bool>,
        onSend: @escaping (String) -> Void,
        onBack: @escaping () -> Void,
        onMarkRead: @escaping () -> Void,
        onStartCall: ((String) -> Void)? = nil,
        onTyping: (() -> Void)? = nil,
        onReact: ((MessageStore.Message, String?) -> Void)? = nil,
        onOpenContact: (() -> Void)? = nil,
        typingObserver: TypingObserver = .inert
    ) {
        self.threadUserId = threadUserId
        self.displayName = displayName
        self._draft = draft
        self._isSending = isSending
        self.onSend = onSend
        self.onBack = onBack
        self.onMarkRead = onMarkRead
        self.onStartCall = onStartCall
        self.onTyping = onTyping
        self.onReact = onReact
        self.onOpenContact = onOpenContact
        self.typingObserver = typingObserver
        self._messages = Query(constant: ThreadMessagesQuery(threadUserId: threadUserId))
        self._reactions = Query(constant: ThreadReactionsQuery(threadUserId: threadUserId))
    }

    private var peerIsTyping: Bool {
        typingObserver.typing[threadUserId] == true
    }

    /// message row id → reactions on it.
    private var reactionsByMessage: [String: [MessageStore.Reaction]] {
        Dictionary(grouping: reactions, by: \.message_id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        // macOS thread already feels desktop-y;
                        // the e2e ribbon adds visual clutter on the
                        // wider canvas. Keep it iOS-only where the
                        // user has only just opened the thread.
                        // E2E ribbon on both platforms — the macOS design
                        // (nt-screens-2.jsx NTMac) shows the same
                        // "End-to-end encrypted · Today" marker.
                        e2eRibbon
                            .padding(.top, 12)
                            .padding(.bottom, 6)

                        ForEach(Array(messages.enumerated()), id: \.element.id) { idx, m in
                            messageRow(m, previousIndex: idx - 1)
                                .id(m.id)
                        }
                        Color.clear.frame(height: 1).id("__bottom")
                    }
                    .frame(maxWidth: 720)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .onTapGesture { composeFocused = false }
                .onChange(of: messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("__bottom", anchor: .bottom)
                    }
                    // New incoming message while the user is in
                    // the thread should clear, not accumulate, the
                    // unread badge — so re-mark on every change.
                    onMarkRead()
                }
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo("__bottom", anchor: .bottom)
                    }
                    onMarkRead()
                }
            }

            composeBar
        }
        .background(palette.bg)
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { composeFocused = false }
            }
        }
        #endif
    }

    // MARK: - Message row (bubble + reactions)

    @ViewBuilder
    private func messageRow(_ m: MessageStore.Message, previousIndex: Int) -> some View {
        let outgoing = m.direction == "out"
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
            MessageBubble(
                text: m.plaintext ?? "(undecryptable)",
                outgoing: outgoing,
                time: bubbleTime(for: m, previousIndex: previousIndex),
                delivered: outgoing
                    && (m.state == "delivered" || m.state == "sent_to_server"),
                read: outgoing && m.state == "read",
                maxWidth: contentWidth > 0 ? contentWidth * 0.78 : nil
            )
            .contextMenu { reactionMenu(for: m) }

            if let chips = reactionsByMessage[m.id], !chips.isEmpty {
                reactionChips(chips)
                    .padding(.horizontal, 22)
                    .padding(.top, -6)
            }
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }

    @ViewBuilder
    private func reactionMenu(for m: MessageStore.Message) -> some View {
        // No menu until the message has a server id — a reaction made
        // before then could never reach the peer (nothing re-transmits
        // it when the id binds), so don't offer the affordance.
        if onReact != nil, m.server_id != nil {
            ForEach(Self.reactionChoices, id: \.self) { emoji in
                Button("\(emoji)") { onReact?(m, emoji) }
            }
            Button("Remove reaction", role: .destructive) { onReact?(m, nil) }
        }
    }

    private func reactionChips(_ chips: [MessageStore.Reaction]) -> some View {
        // Group identical emoji into "🧡 2"-style chips.
        let grouped = Dictionary(grouping: chips, by: \.reaction)
            .sorted { $0.value.count > $1.value.count }
        return HStack(spacing: 4) {
            ForEach(grouped, id: \.key) { emoji, list in
                Text(list.count > 1 ? "\(emoji) \(list.count)" : emoji)
                    .interFont(size: 12)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(palette.surfaceAlt))
                    .overlay(Capsule().stroke(palette.border, lineWidth: 0.5))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        #if os(macOS)
        macHeader
        #else
        iosHeader
        #endif
    }

    /// iPhone header — keeps the design-mock idiom (chevron + avatar +
    /// active-now dot + phone/video icons on a surface strip).
    private var iosHeader: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(palette.brand)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to chat list")

            Button { onOpenContact?() } label: {
                HStack(spacing: 10) {
                    HearthAvatar(name: displayName, color: palette.avatar1, size: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .interFont(size: 16, weight: .semibold)
                            .foregroundStyle(palette.ink)
                            .tracking(-0.2)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(peerIsTyping ? palette.brand : palette.success)
                                .frame(width: 6, height: 6)
                            Text(peerIsTyping ? "typing…" : "Active now · Family")
                                .interFont(size: 12)
                                .foregroundStyle(peerIsTyping ? palette.brand : palette.inkMuted)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpenContact == nil)
            .accessibilityLabel("\(displayName), contact info")

            Spacer()

            HStack(spacing: 16) {
                Button { onStartCall?("audio") } label: {
                    Image(systemName: "phone")
                        .font(.system(size: 22, weight: .regular))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Audio call")
                Button { onStartCall?("video") } label: {
                    Image(systemName: "video")
                        .font(.system(size: 22, weight: .regular))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Video call")
            }
            .foregroundStyle(palette.brand)
            .disabled(onStartCall == nil)
        }
        .padding(.horizontal, 14)
        .padding(.top, headerTopPadding)
        .padding(.bottom, 10)
        .background(palette.surface.ignoresSafeArea(edges: .top))
        .overlay(
            Rectangle()
                .fill(palette.border)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    /// macOS header — WhatsApp idiom: avatar + name on top, "last seen
    /// today at HH:MM" subtitle below in muted ink, video + phone
    /// glyphs flush right. No active-now dot (we don't have presence
    /// data yet — claiming "Active now" was misleading), no back
    /// chevron (NavigationSplitView shows the sidebar permanently).
    #if os(macOS)
    private var macHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { onOpenContact?() } label: {
                HStack(spacing: 10) {
                    HearthAvatar(name: displayName, color: palette.avatar1, size: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .interFont(size: 15, weight: .semibold)
                            .foregroundStyle(palette.ink)
                            .tracking(-0.2)
                        Text(peerIsTyping ? "typing…" : presenceSubtitle())
                            .interFont(size: 11)
                            .foregroundStyle(peerIsTyping ? palette.brand : palette.inkMuted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpenContact == nil)
            .accessibilityLabel("\(displayName), contact info")

            Spacer()

            HStack(spacing: 18) {
                Button { onStartCall?("video") } label: {
                    Image(systemName: "video")
                        .font(.system(size: 16, weight: .regular))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Video call")
                Button { onStartCall?("audio") } label: {
                    Image(systemName: "phone")
                        .font(.system(size: 15, weight: .regular))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Audio call")
            }
            .foregroundStyle(palette.brand)
            .disabled(onStartCall == nil)
        }
        .padding(.horizontal, 14)
        .padding(.top, headerTopPadding)
        .padding(.bottom, 10)
        .background(palette.surface.ignoresSafeArea(edges: .top))
        .overlay(
            Rectangle()
                .fill(palette.border)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    /// Subtitle under the contact name. We don't track presence yet,
    /// so this falls back to the time of the most recent message.
    /// Once the WS presence channel lands this can be wired to a
    /// "last seen" / "online" feed.
    private func presenceSubtitle() -> String {
        guard let last = messages.last else { return " " }
        let date = Date(timeIntervalSince1970: TimeInterval(last.sort_key) / 1000)
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) {
            f.dateFormat = "h:mm a"
            return "last seen today at \(f.string(from: date))"
        }
        if cal.isDateInYesterday(date) {
            f.dateFormat = "h:mm a"
            return "last seen yesterday at \(f.string(from: date))"
        }
        f.dateFormat = "MMM d 'at' h:mm a"
        return "last seen \(f.string(from: date))"
    }
    #endif

    /// macOS hidden-titlebar windows still reserve ~28pt for the
    /// traffic-light chrome at the top — pad the chat thread header
    /// down so back/avatar/name don't bash up against the window
    /// edge. iOS already gets safe-area top from the system.
    private var headerTopPadding: CGFloat {
        #if os(macOS)
        return 32
        #else
        return 6
        #endif
    }

    // MARK: - E2E ribbon

    private var e2eRibbon: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.accent)
            Text("End-to-end encrypted · \(todayLabel())")
                .interFont(size: 11, weight: .medium)
                .foregroundStyle(palette.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(palette.accentSoft))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Compose bar

    @ViewBuilder
    private var composeBar: some View {
        #if os(macOS)
        macComposeBar
        #else
        iosComposeBar
        #endif
    }

    #if os(macOS)
    /// Desktop composer (nt-screens-2.jsx NTMac): a rounded-rect field with
    /// a leading attach affordance and a labeled "Send" pill.
    private var macComposeBar: some View {
        HStack(spacing: 10) {
            Button { /* attachments — later sprint */ } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 18))
                    .foregroundStyle(palette.inkMuted)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.6)
            .accessibilityLabel("Attach (coming soon)")

            TextField("Message…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($composeFocused)
                .submitLabel(.send)
                .onSubmit { fireSend() }
                .onChange(of: draft) { _, new in
                    if !new.isEmpty { onTyping?() }
                }
                .interFont(size: 13)
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.bg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(palette.border, lineWidth: 0.5)
                        )
                )

            Button { fireSend() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Send")
                        .interFont(size: 13, weight: .semibold)
                }
                .foregroundStyle(palette.bubbleOutInk)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.brand)
                )
                .opacity(isSending ? 0.5 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(palette.surface)
        .overlay(
            Rectangle().fill(palette.border).frame(height: 0.5),
            alignment: .top
        )
    }
    #endif

    private var iosComposeBar: some View {
        HStack(spacing: 8) {
            Button {
                // attachments — wired in a later sprint
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.brand)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(palette.surfaceAlt))
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.7)

            HStack(spacing: 8) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($composeFocused)
                    .submitLabel(.send)
                    .onSubmit { fireSend() }
                    .onChange(of: draft) { _, new in
                        if !new.isEmpty { onTyping?() }
                    }
                    .interFont(size: 15)
                    .foregroundStyle(palette.ink)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(
                Capsule().fill(palette.bg)
            )
            .overlay(
                Capsule().stroke(palette.border, lineWidth: 0.5)
            )

            Button { fireSend() } label: {
                Image(systemName: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      ? "mic"
                      : "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.bubbleOutInk)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(palette.brand))
                    .opacity(isSending ? 0.5 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(palette.surface)
        .overlay(
            Rectangle()
                .fill(palette.border)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private func fireSend() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
    }

    // MARK: - Time labels

    /// Show a time label under a bubble only when the previous bubble
    /// is more than 4 minutes older or comes from the other side, so
    /// rapid back-and-forth stays uncluttered (matches the design
    /// mocks where only one of two adjacent bubbles carries a time).
    private func bubbleTime(for m: MessageStore.Message, previousIndex: Int) -> String? {
        if previousIndex >= 0 {
            let prev = messages[previousIndex]
            let sameSide = prev.direction == m.direction
            let dt = abs(m.sort_key - prev.sort_key)
            if sameSide && dt < 4 * 60 * 1000 { return nil }
        }
        let date = Date(timeIntervalSince1970: TimeInterval(m.sort_key) / 1000)
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    private func todayLabel() -> String {
        let cal = Calendar.current
        if let earliest = messages.first {
            let d = Date(timeIntervalSince1970: TimeInterval(earliest.sort_key) / 1000)
            if cal.isDateInToday(d) { return "Today" }
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f.string(from: d)
        }
        return "Today"
    }
}

// MARK: - Environment plumbing

private struct MessageStoreKey: EnvironmentKey {
    static let defaultValue: MessageStore? = nil
}

private struct MessageSendServiceKey: EnvironmentKey {
    static let defaultValue: MessageSendService? = nil
}

public extension EnvironmentValues {
    var messageStore: MessageStore? {
        get { self[MessageStoreKey.self] }
        set { self[MessageStoreKey.self] = newValue }
    }
    var messageSendService: MessageSendService? {
        get { self[MessageSendServiceKey.self] }
        set { self[MessageSendServiceKey.self] = newValue }
    }
}
