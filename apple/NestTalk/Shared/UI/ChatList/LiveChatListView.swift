import SwiftUI
import GRDB
import GRDBQuery

/// Live chat list — observes ThreadSummaryQuery so new messages from
/// `MessageReceiveService` push fresh previews into the UI without a
/// reload tick. Falls back to a placeholder when no MessageStore is
/// in environment (preview / spike-mode).
///
/// Visual layout follows `nt-screens-1.jsx` `NTChatList`: pill header
/// row with search/+ buttons, a horizontal "family circle" shelf, and
/// a rounded-top "Recent" panel containing the chat rows.
public struct LiveChatListView: View {
    @Environment(\.hearth) private var palette
    @Environment(\.messageStore) private var storeBox
    public let onSelect: (String, String) -> Void
    public let onOpenSettings: (() -> Void)?
    /// Currently-open thread id — drives the macOS sidebar selected-row
    /// highlight (the permanent split keeps a conversation selected).
    public let selectedThreadId: String?
    /// Opens the Safety Center (macOS sidebar safety footer).
    public let onOpenSafety: (() -> Void)?
    @ObservedObject var typingObserver: TypingObserver

    public init(
        onSelect: @escaping (String, String) -> Void = { _, _ in },
        onOpenSettings: (() -> Void)? = nil,
        selectedThreadId: String? = nil,
        onOpenSafety: (() -> Void)? = nil,
        typingObserver: TypingObserver = .inert
    ) {
        self.onSelect = onSelect
        self.onOpenSettings = onOpenSettings
        self.selectedThreadId = selectedThreadId
        self.onOpenSafety = onOpenSafety
        self.typingObserver = typingObserver
    }

    public var body: some View {
        ZStack {
            // iPhone: lavender behind a rounded-top white "Recent"
            // card. macOS: single white surface — the two-tone iPhone
            // composition reads as competing backgrounds inside a
            // narrow desktop sidebar.
            #if os(macOS)
            palette.surfaceAlt.ignoresSafeArea()
            #else
            palette.bg.ignoresSafeArea()
            #endif

            if let store = storeBox {
                let context: DatabaseContext = .readWrite { store.dbQueue }
                LiveListBody(
                    onSelect: onSelect,
                    onOpenSettings: onOpenSettings,
                    selectedThreadId: selectedThreadId,
                    onOpenSafety: onOpenSafety,
                    typingObserver: typingObserver
                )
                .databaseContext(context)
            } else {
                ChatListView()
            }
        }
    }
}

private struct LiveListBody: View {
    @Environment(\.hearth) private var palette
    @Query(ThreadSummaryQuery()) private var summaries: [ThreadSummary]
    let onSelect: (String, String) -> Void
    let onOpenSettings: (() -> Void)?
    let selectedThreadId: String?
    let onOpenSafety: (() -> Void)?
    @ObservedObject var typingObserver: TypingObserver

    /// Last-message preview, overridden by a live "typing…" signal.
    private func preview(for s: ThreadSummary) -> String {
        if typingObserver.typing[s.threadUserId] == true { return "typing…" }
        return s.last.isEmpty ? "Tap to start a conversation" : s.last
    }

    var body: some View {
        #if os(macOS)
        macSidebar
        #else
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, headerTopPadding)
                .padding(.bottom, 10)

            recentPanel
        }
        #endif
    }

    // MARK: - macOS sidebar

    /// macOS sidebar ported from `nt-screens-2.jsx` `NTMac`: a surfaceAlt
    /// column with a logo + "Nest" wordmark, a rounded search field, a
    /// "Family circle" section label, selected-row (brand) chat pills, and
    /// a Safety footer card. The selected row tracks the live split-view
    /// selection rather than unread state.
    #if os(macOS)
    private var macSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("LoginHero")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .shadow(color: palette.brand.opacity(0.27), radius: 5, y: 2)
                    .accessibilityHidden(true)
                Text("Nest")
                    .frauncesFont(size: 18, weight: .semibold)
                    .foregroundStyle(palette.ink)
                    .tracking(-0.3)
                Spacer()
                if onOpenSettings != nil {
                    Button {
                        onOpenSettings?()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(palette.ink)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(palette.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(palette.border, lineWidth: 0.5)
                                    )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 32)
            .padding(.bottom, 10)

            macSearchField
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            Text("Family circle")
                .interFont(size: 10.5, weight: .bold)
                .foregroundStyle(palette.inkMuted)
                .tracking(1.2)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)

            macChatList

            macSafetyFooter
        }
    }

    private var macSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(palette.inkSoft)
            Text("Search conversations")
                .interFont(size: 12.5)
                .foregroundStyle(palette.inkSoft)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.border, lineWidth: 0.5)
                )
        )
    }

    private var macChatList: some View {
        Group {
            if summaries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(palette.inkMuted)
                    Text("No conversations yet")
                        .interFont(size: 13)
                        .foregroundStyle(palette.inkMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(summaries) { s in
                            Button {
                                onSelect(s.threadUserId, s.displayName)
                            } label: {
                                macRow(for: s)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func macRow(for s: ThreadSummary) -> some View {
        let selected = s.threadUserId == selectedThreadId
        let unread = s.unreadCount > 0
        let typing = typingObserver.typing[s.threadUserId] == true
        let nameColor = selected ? palette.bubbleOutInk : palette.ink
        let timeColor = selected ? palette.bubbleOutInk.opacity(0.8)
            : (unread ? palette.brand : palette.inkSoft)
        let previewColor = selected ? palette.bubbleOutInk.opacity(0.9)
            : (typing ? palette.brand : palette.inkMuted)
        return HStack(alignment: .center, spacing: 10) {
            HearthAvatar(name: s.displayName, color: avatarColor(for: s.threadUserId), size: 34)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(s.displayName)
                        .interFont(size: 13, weight: .semibold)
                        .foregroundStyle(nameColor)
                        .tracking(-0.1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(timestampLabel(s.lastSortKey))
                        .interFont(size: 10.5)
                        .foregroundStyle(timeColor)
                        .lineLimit(1)
                        .fixedSize()
                }
                HStack(alignment: .center, spacing: 3) {
                    Text(preview(for: s))
                        .interFont(size: 11.5)
                        .foregroundStyle(previewColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if unread && !selected {
                        Text("\(s.unreadCount)")
                            .interFont(size: 10, weight: .bold)
                            .foregroundStyle(palette.bubbleOutInk)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(palette.brand))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? palette.brand : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var macSafetyFooter: some View {
        Button { onOpenSafety?() } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.accent)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nest is secure")
                        .interFont(size: 12, weight: .semibold)
                        .foregroundStyle(palette.ink)
                    Text("End-to-end encrypted")
                        .interFont(size: 11)
                        .foregroundStyle(palette.inkMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.accentSoft)
            )
        }
        .buttonStyle(.plain)
        .disabled(onOpenSafety == nil)
        .padding(10)
        .accessibilityLabel("Safety center: nest is secure, end-to-end encrypted")
    }
    #endif

    /// macOS hidden-titlebar windows still reserve ~28pt for the
    /// traffic-light chrome at the top-left. Push the header below
    /// it so "Nest" doesn't sit next to the close/min/max buttons.
    private var headerTopPadding: CGFloat {
        #if os(macOS)
        return 32
        #else
        return 8
        #endif
    }

    /// Pick a background for the search pill that contrasts with the
    /// outer panel: surface vs lavender on iPhone, surfaceAlt vs
    /// surface on macOS. Without this the pill goes invisible on
    /// macOS where the whole sidebar is already palette.surface.
    private var searchPillBackground: Color {
        #if os(macOS)
        return palette.surfaceAlt
        #else
        return palette.surface
        #endif
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nest")
                        .frauncesFont(size: 34, weight: .semibold)
                        .foregroundStyle(palette.ink)
                        .tracking(-0.8)
                    Text("\(summaries.count) in your circle · all safe")
                        .interFont(size: 13)
                        .foregroundStyle(palette.inkMuted)
                        .tracking(0.2)
                }
                Spacer()
                HStack(spacing: 10) {
                    if onOpenSettings != nil {
                        Button {
                            onOpenSettings?()
                        } label: {
                            pillButton(systemImage: "gearshape",
                                       iconColor: palette.ink,
                                       background: searchPillBackground,
                                       stroke: palette.border)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                    }
                    pillButton(systemImage: "magnifyingglass",
                               iconColor: palette.ink,
                               background: searchPillBackground,
                               stroke: palette.border,
                               iconSize: 19)
                    pillButton(systemImage: "plus",
                               iconColor: palette.bubbleOutInk,
                               background: palette.brand,
                               stroke: nil,
                               weight: .semibold,
                               iconSize: 20)
                }
            }

            #if os(iOS)
            if !familyCircle.isEmpty {
                familyCircleShelf
                    .padding(.top, 16)
            }
            #endif
        }
    }

    private func pillButton(
        systemImage: String,
        iconColor: Color,
        background: Color,
        stroke: Color?,
        weight: Font.Weight = .regular,
        iconSize: CGFloat = 19
    ) -> some View {
        ZStack {
            Circle().fill(background)
            if let stroke {
                Circle().stroke(stroke, lineWidth: 0.5)
            }
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: weight))
                .foregroundStyle(iconColor)
        }
        .frame(width: 40, height: 40)
    }

    // MARK: - Family circle shelf

    /// First five roster members — used as the horizontal "family
    /// circle" shelf at the top of the screen. We treat every roster
    /// entry as part of the family in v0.4.0 since groups don't exist.
    private var familyCircle: [ThreadSummary] {
        Array(summaries.prefix(5))
    }

    private var familyCircleShelf: some View {
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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(familyCircle) { s in
                        Button {
                            onSelect(s.threadUserId, s.displayName)
                        } label: {
                            VStack(spacing: 6) {
                                HearthAvatar(
                                    name: s.displayName,
                                    color: avatarColor(for: s.threadUserId),
                                    size: 52,
                                    ring: true,
                                    ringColor: palette.brandSoft
                                )
                                .padding(.top, 3)
                                Text(firstName(s.displayName))
                                    .interFont(size: 11, weight: .medium)
                                    .foregroundStyle(palette.ink)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 58)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Recent panel

    private var recentPanel: some View {
        VStack(spacing: 0) {
            Text("RECENT")
                .interFont(size: 11, weight: .semibold)
                .foregroundStyle(palette.inkMuted)
                .tracking(1.2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)

            if summaries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundStyle(palette.inkMuted)
                    Text("No conversations yet")
                        .interFont(size: 14)
                        .foregroundStyle(palette.inkMuted)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(summaries.enumerated()), id: \.element.id) { idx, s in
                            Button {
                                onSelect(s.threadUserId, s.displayName)
                            } label: {
                                row(for: s)
                            }
                            .buttonStyle(.plain)
                            if idx < summaries.count - 1 {
                                Rectangle()
                                    .fill(palette.border)
                                    .frame(height: 0.5)
                                    .padding(.leading, 76)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if os(iOS)
        // iPhone uses the rounded-top "card on lavender" pattern from
        // the design mocks — nice bottom-of-screen tuck.
        .background(
            RoundedTopRectangle(cornerRadius: 28)
                .fill(palette.surface)
                .ignoresSafeArea(edges: .bottom)
        )
        .padding(.top, 12)
        #else
        // macOS sidebar: a single flat surface from the chrome down,
        // no rounded transition — the rounded-top idiom only reads
        // when there's a wider lavender background tucked behind it.
        .background(palette.surface.ignoresSafeArea(edges: .bottom))
        #endif
    }

    private func row(for s: ThreadSummary) -> some View {
        let active = s.unreadCount > 0
        return HStack(spacing: 13) {
            HearthAvatar(name: s.displayName, color: avatarColor(for: s.threadUserId), size: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(s.displayName)
                    .interFont(size: 16, weight: .semibold)
                    .foregroundStyle(palette.ink)
                    .tracking(-0.2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(preview(for: s))
                    .interFont(size: 14, weight: active ? .medium : .regular)
                    .foregroundStyle(typingObserver.typing[s.threadUserId] == true ? palette.brand : palette.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text(timestampLabel(s.lastSortKey))
                    .interFont(size: 11, weight: active ? .semibold : .regular)
                    .foregroundStyle(active ? palette.brand : palette.inkSoft)
                    .lineLimit(1)
                    .fixedSize()
                if active {
                    unreadBadge(count: s.unreadCount)
                } else {
                    Color.clear.frame(width: 18, height: 18)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func unreadBadge(count: Int) -> some View {
        Text("\(count)")
            .interFont(size: 11, weight: .bold)
            .foregroundStyle(palette.bubbleOutInk)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(palette.brand))
    }

    // MARK: - Helpers

    /// Stable per-user picker into the four-color avatar palette.
    private func avatarColor(for userId: String) -> Color {
        let hash = userId.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        switch (abs(hash) % 4) {
        case 0: return palette.avatar1
        case 1: return palette.avatar2
        case 2: return palette.avatar3
        default: return palette.avatar4
        }
    }

    private func firstName(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }

    /// Format the latest-message timestamp the way the design mock
    /// shows it: clock for today, "Yesterday", weekday for the last
    /// week, otherwise short date. `key` is `received_at ?? sent_at`
    /// in milliseconds (see `MessageStore.Message.sort_key`); 0 means
    /// the thread has no messages yet, so we render an empty string.
    private func timestampLabel(_ key: Int64) -> String {
        guard key > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(key) / 1000)
        let cal = Calendar.current
        let now = Date()
        let f = DateFormatter()
        if cal.isDateInToday(date) {
            f.dateFormat = "h:mm a"
            return f.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = cal.dateComponents([.day], from: date, to: now).day, days < 7 {
            f.dateFormat = "EEE"
            return f.string(from: date)
        }
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

// MARK: - Shapes

/// Rectangle with only the top two corners rounded — used for the
/// "Recent" panel that sits flush against the bottom of the screen.
private struct RoundedTopRectangle: Shape {
    let cornerRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                 radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                 radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
