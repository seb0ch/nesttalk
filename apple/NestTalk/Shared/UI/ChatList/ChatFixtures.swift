import Foundation

/// Sample chat data from `docs/design/nesttalk-bundle/project/nt-screens-1.jsx`
/// constant `NT_CHATS`. Used by `ChatListView` and `FamilyCircleShelfView`
/// during the spike before real message history is wired up.
///
/// Matches the bundle verbatim — same names, same preview text (including
/// the heart emoji), same order.
public struct ChatPreview: Identifiable, Equatable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let last: String
    public let time: String
    public let unread: Int
    public let pinned: Bool
    public let avatarColorIndex: Int
    public let nest: String?
    public let voice: Bool
    public let missed: Bool
    public let read: Bool
    public let typing: Bool
}

public extension ChatPreview {
    static let sample: [ChatPreview] = [
        .init(name: "Mom",           last: "Call me when you land sweetie 🧡",
              time: "2:14 pm",   unread: 2, pinned: true,
              avatarColorIndex: 0, nest: "Family",
              voice: false, missed: false, read: false, typing: false),
        .init(name: "Dad",           last: "Did you see the photo I sent?",
              time: "1:02 pm",   unread: 0, pinned: false,
              avatarColorIndex: 3, nest: "Family",
              voice: false, missed: false, read: false, typing: false),
        .init(name: "Grandma Ruth",  last: "Voice message · 0:42",
              time: "11:38 am",  unread: 1, pinned: false,
              avatarColorIndex: 2, nest: "Family",
              voice: true,  missed: false, read: false, typing: false),
        .init(name: "Kai",           last: "I'm walking home now",
              time: "Yesterday", unread: 0, pinned: false,
              avatarColorIndex: 1, nest: "Family",
              voice: false, missed: false, read: false, typing: false),
        .init(name: "Aunt Priya",    last: "Happy birthday!! 🎂",
              time: "Yesterday", unread: 0, pinned: false,
              avatarColorIndex: 0, nest: nil,
              voice: false, missed: false, read: false, typing: false),
        .init(name: "Uncle Theo",    last: "You: sounds good",
              time: "Mon",       unread: 0, pinned: false,
              avatarColorIndex: 3, nest: nil,
              voice: false, missed: false, read: true,  typing: false),
        .init(name: "Nana Iris",     last: "Missed call",
              time: "Sun",       unread: 0, pinned: false,
              avatarColorIndex: 2, nest: nil,
              voice: false, missed: true,  read: false, typing: false),
        .init(name: "Cousin Maya",   last: "lol same",
              time: "Fri",       unread: 0, pinned: false,
              avatarColorIndex: 1, nest: nil,
              voice: false, missed: false, read: false, typing: false),
    ]
}

// Initials helper used by HearthAvatar.
public extension String {
    var hearthInitials: String {
        let parts = split(separator: " ").compactMap { $0.first }.map(String.init)
        return parts.prefix(2).joined().uppercased()
    }
}
