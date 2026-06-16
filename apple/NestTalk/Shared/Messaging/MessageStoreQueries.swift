import Foundation
import GRDB
import GRDBQuery

/// `Queryable` implementations bridging GRDB's `ValueObservation` into
/// SwiftUI `@Query` properties. Both queries are read-only and run on
/// any thread — GRDBQuery handles the boundary marshalling.

/// One-row-per-thread summary for `ChatListView`. A "thread" here
/// includes every enrolled non-revoked roster member, even if there's
/// no message history yet — empty rows render as "Tap to start a
/// conversation" affordances. The chat list is the de-facto contact
/// list for v0.4.0; until a separate roster screen ships, this query
/// is the only place users see who's in the family.
public struct ThreadSummary: Equatable, Sendable, Identifiable, Hashable {
    public let threadUserId: String
    public let displayName: String
    public let last: String
    public let lastSortKey: Int64
    public let unreadCount: Int

    public var id: String { threadUserId }
}

public struct ThreadSummaryQuery: ValueObservationQueryable, Hashable {
    public static var defaultValue: [ThreadSummary] { [] }
    public init() {}

    public func fetch(_ db: Database) throws -> [ThreadSummary] {
        // LEFT JOIN: every non-revoked roster user, plus their latest
        // message (if any). Users with no message history surface
        // empty `last` string and lastSortKey = 0 so they sort to
        // the bottom (after active threads).
        //
        // `unread` counts incoming messages without a row in the
        // local `read_receipts` table — see `markThreadRead`. Only
        // direction='in' counts; outbound rows are always
        // self-authored and never count as unread.
        let rows = try Row.fetchAll(db, sql: """
            SELECT u.user_id       AS user_id,
                   u.display_name  AS display_name,
                   nt_decrypt(latest.ciphertext, latest.plaintext) AS last,
                   COALESCE(latest.sort_key, 0) AS sort_key,
                   COALESCE(unread.cnt, 0) AS unread_count
              FROM users u
              LEFT JOIN (
                  SELECT m.thread_user_id, m.plaintext, m.ciphertext, m.sort_key
                    FROM messages m
                    JOIN (
                        SELECT thread_user_id, MAX(sort_key) AS max_key
                          FROM messages GROUP BY thread_user_id
                    ) latest_idx
                      ON latest_idx.thread_user_id = m.thread_user_id
                     AND latest_idx.max_key       = m.sort_key
              ) latest ON latest.thread_user_id = u.user_id
              LEFT JOIN (
                  SELECT m.thread_user_id, COUNT(*) AS cnt
                    FROM messages m
                    LEFT JOIN read_receipts r ON r.message_id = m.id
                   WHERE m.direction = 'in' AND r.message_id IS NULL
                   GROUP BY m.thread_user_id
              ) unread ON unread.thread_user_id = u.user_id
             WHERE u.revoked = 0
             ORDER BY sort_key DESC, display_name ASC
        """)
        return rows.compactMap { row in
            guard
                let uid = row["user_id"] as String?,
                let name = row["display_name"] as String?,
                let key  = row["sort_key"] as Int64?
            else { return nil }
            let unread = (row["unread_count"] as Int64?).map(Int.init) ?? 0
            return ThreadSummary(
                threadUserId: uid,
                displayName: name,
                last: (row["last"] as String?) ?? "",
                lastSortKey: key,
                unreadCount: unread
            )
        }
    }
}

/// All messages in one thread, ordered by sort_key ascending.
///
/// **Equatable** (refined here as `Hashable` since the conformance is
/// free for a one-`String` struct) is what GRDBQuery uses to decide
/// whether two `Query(constant:)` instances reference the same
/// observation. `Queryable` already requires `Equatable`; the
/// `Hashable` refinement is a no-op for GRDBQuery's `==` comparison
/// but lets us drop the queryable into Sets / Dictionaries if a
/// future caller wants to. As long as `threadUserId` stays the same
/// across parent re-renders, `LiveThreadBody`'s `_messages =
/// Query(constant: ...)` re-init produces an equal value, and
/// GRDBQuery keeps the underlying `ValueObservation` alive — no
/// tear-down per keystroke.
public struct ThreadMessagesQuery: ValueObservationQueryable, Hashable {
    public static var defaultValue: [MessageStore.Message] { [] }
    public let threadUserId: String

    public init(threadUserId: String) {
        self.threadUserId = threadUserId
    }

    public func fetch(_ db: Database) throws -> [MessageStore.Message] {
        try MessageStore.Message
            .filter(Column("thread_user_id") == threadUserId)
            .order(Column("sort_key").asc)
            .limit(500)
            .fetchAll(db)
    }
}

/// Every reaction attached to a message in `threadUserId`'s thread.
/// `LiveThreadBody` groups them by `message_id` into bubble chips.
public struct ThreadReactionsQuery: ValueObservationQueryable, Hashable {
    public static var defaultValue: [MessageStore.Reaction] { [] }
    public let threadUserId: String

    public init(threadUserId: String) {
        self.threadUserId = threadUserId
    }

    public func fetch(_ db: Database) throws -> [MessageStore.Reaction] {
        try MessageStore.Reaction.fetchAll(
            db,
            sql: """
            SELECT r.* FROM reactions r
            JOIN messages m ON m.id = r.message_id
            WHERE m.thread_user_id = ?
            """,
            arguments: [threadUserId]
        )
    }
}
