import Foundation
import GRDB
import CryptoKit

/// GRDB-backed local message history. Schema derived from
/// `client/lib/services/app_database.dart` at v0.2.3 (tables `users`,
/// `messages`, `pending_queue`, `reactions`, `read_receipts`) — shapes
/// and column names carried over unchanged so wire-format payloads
/// round-trip byte-for-byte.
///
/// **Encryption (at rest).** `init(path:wrapKey:)` accepts a 32-byte
/// `DatabaseWrapKey` and applies it two ways:
///
///  1. **App-level column encryption (load-bearing).** When a wrapKey
///     is present, message bodies are never written in cleartext: the
///     `messages.plaintext` column stays NULL and the body is AEAD-sealed
///     (ChaCha20-Poly1305, dedicated AAD) into `messages.ciphertext`.
///     `sealedForPersistence` seals on write and the per-connection
///     `nt_decrypt` SQL function opens on read (wired into the record's
///     `databaseSelection`), so the rest of the app still sees
///     `Message.plaintext` transparently. This
///     mirrors `pending_queue.plaintext_wrapped` (Sprint 1) and is the
///     active confidentiality control for the plain-GRDB build. It
///     protects message *content*; row metadata (peer id, timestamps,
///     state, sort key) remains cleartext at the SQLite layer.
///  2. **Full-database SQLCipher (optional, future).** When linked
///     against a SQLCipher-enabled GRDB variant (build flag
///     `NESTTALK_SQLCIPHER`), `applyEncryption` additionally issues
///     `PRAGMA key`, encrypting the whole file (metadata included). The
///     plain-GRDB build path is a no-op for this layer.
///
/// **Sendable.** GRDB's `DatabaseQueue` is internally thread-safe; it
/// serializes every `read` / `write` through its own queue. Marking
/// `MessageStore` `@unchecked Sendable` is correct because the only
/// mutable state is the dbQueue, and the `wrapKey` (SymmetricKey) and
/// the captured-but-unused `prepareDatabase` closure are immutable.
public final class MessageStore: @unchecked Sendable {

    public let dbQueue: DatabaseQueue
    private let wrapKey: SymmetricKey?

    /// AAD binding sealed bodies to this column's purpose — distinct from
    /// `PlaintextWrap.aad` so an outbox blob can never be opened as a
    /// message body or vice versa.
    static let bodyAAD = Data("nesttalk.msgbody.v1".utf8)

    /// Name of the per-connection SQL function that opens a sealed body.
    /// `nt_decrypt(ciphertext, plaintext)` returns the cleartext body:
    /// the opened `ciphertext` when a key is active and the blob is
    /// present, otherwise the `plaintext` column verbatim (no-key builds
    /// and legacy cleartext rows). Registered per database so the key
    /// lives on the connection — no process-global, so concurrent stores
    /// (e.g. parallel tests) never cross keys.
    static let bodyDecryptFunctionName = "nt_decrypt"

    /// Seal a body for persistence. With a key active the cleartext lives
    /// only in `ciphertext` (AEAD-sealed) and `plaintext` is NULL; with no
    /// key it stays cleartext. Pure value transform on the store's own key.
    ///
    /// FAILS CLOSED: if sealing throws (which should never happen for a small
    /// in-memory buffer with a valid key), the error propagates and the insert
    /// is aborted rather than silently writing the body in cleartext — at-rest
    /// confidentiality must not degrade to plaintext on a crypto/RNG failure.
    private func sealedForPersistence(_ message: Message) throws -> Message {
        guard let key = wrapKey, let body = message.plaintext else { return message }
        let sealed = try ChaChaPoly.seal(Data(body.utf8), using: key, authenticating: Self.bodyAAD)
        var m = message
        m.plaintext = nil
        m.ciphertext = sealed.combined
        return m
    }

    public init(path: String, wrapKey: SymmetricKey? = nil) throws {
        self.wrapKey = wrapKey
        var config = Configuration()
        config.prepareDatabase { db in
            try Self.applyEncryption(db: db, wrapKey: wrapKey)
            Self.registerBodyDecrypt(db: db, wrapKey: wrapKey)
        }
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory variant for tests.
    public static func inMemory(wrapKey: SymmetricKey? = nil) throws -> MessageStore {
        var config = Configuration()
        config.prepareDatabase { db in
            try Self.applyEncryption(db: db, wrapKey: wrapKey)
            Self.registerBodyDecrypt(db: db, wrapKey: wrapKey)
        }
        let queue = try DatabaseQueue(configuration: config)
        try Self.migrator.migrate(queue)
        return MessageStore(queue: queue, wrapKey: wrapKey)
    }

    private init(queue: DatabaseQueue, wrapKey: SymmetricKey?) {
        self.dbQueue = queue
        self.wrapKey = wrapKey
    }

    /// Register the per-connection `nt_decrypt(ciphertext, plaintext)`
    /// function. The key is captured here, so each database opens bodies
    /// with its own key and there is no shared mutable crypto state.
    private static func registerBodyDecrypt(db: Database, wrapKey: SymmetricKey?) {
        let fn = DatabaseFunction(bodyDecryptFunctionName, argumentCount: 2, pure: true) { values in
            let plaintext = String.fromDatabaseValue(values[1])
            guard let key = wrapKey, let cipher = Data.fromDatabaseValue(values[0]) else {
                return plaintext
            }
            guard
                let box = try? ChaChaPoly.SealedBox(combined: cipher),
                let opened = try? ChaChaPoly.open(box, using: key, authenticating: bodyAAD)
            else { return nil }
            return String(data: opened, encoding: .utf8)
        }
        db.add(function: fn)
    }

    /// Apply full-database `PRAGMA key` (SQLCipher) when linked, else no-op.
    /// Centralized here so whole-file encryption can be enabled by flipping
    /// the `NESTTALK_SQLCIPHER` build flag without touching call sites. This
    /// is the *optional* layer-2 control; app-level body encryption
    /// (`sealedForPersistence` on write, `nt_decrypt` on read) is the active
    /// layer-1 control and runs in every build regardless of this flag.
    private static func applyEncryption(db: Database, wrapKey: SymmetricKey?) throws {
        guard let wrapKey else { return }
        #if NESTTALK_SQLCIPHER
        try db.execute(sql: "PRAGMA key = \"x'\(wrapKey.hexString)'\"")
        try db.execute(sql: "PRAGMA cipher_page_size = 4096")
        #else
        // Plain GRDB build — the file itself is not encrypted at the SQLite
        // layer, so message bodies are protected by app-level column
        // encryption instead (sealed into `messages.ciphertext`). Metadata
        // columns remain cleartext until SQLCipher is wired.
        _ = wrapKey
        #endif
    }

    // MARK: - Migrations

    public static var migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()

        m.registerMigration("v1-initial-schema") { db in
            try db.create(table: "users") { t in
                t.column("user_id",      .text).primaryKey()
                t.column("display_name", .text).notNull()
                t.column("color_hint",   .integer).notNull().defaults(to: 0)
                t.column("revoked",      .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "messages") { t in
                t.column("id",               .text).primaryKey()
                t.column("thread_user_id",   .text).notNull().indexed()
                t.column("direction",        .text).notNull()   // "in" | "out"
                t.column("plaintext",        .text)
                t.column("ciphertext",       .blob)
                t.column("state",            .text).notNull()
                t.column("sent_at",          .integer).notNull()
                t.column("received_at",      .integer)
                t.column("sort_key",         .integer).notNull().indexed()
                t.column("reply_to",         .text)
            }
            try db.create(table: "pending_queue") { t in
                t.column("id",        .text).primaryKey()
                t.column("payload",   .blob).notNull()
                t.column("attempts",  .integer).notNull().defaults(to: 0)
                t.column("next_retry_at", .integer)
            }
            try db.create(table: "reactions") { t in
                t.column("message_id", .text).notNull().indexed()
                t.column("user_id",    .text).notNull()
                t.column("reaction",   .text).notNull()
                t.column("set_at",     .integer).notNull()
                t.primaryKey(["message_id", "user_id"])
            }
            try db.create(table: "read_receipts") { t in
                t.column("message_id", .text).primaryKey()
                t.column("read_at",    .integer).notNull()
            }
            try db.create(table: "local_cursors") { t in
                t.column("name",  .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }

        // v3: messages.server_id replaces the rewrite-PK pattern.
        //
        // Pre-v3 the send pipeline inserted a row with id = localId, then
        // UPDATE'd id to the server-assigned value on success. That
        // breaks every other table that references messages.id by
        // value (reactions, read_receipts, reply_to self-references)
        // because SQLite has no foreign-key cascade for our schema.
        // v3 splits the concerns: messages.id is a stable client UUID
        // for the lifetime of the row; server_id is set on 200 OK and
        // is the dedup join key for catch-up + acks. Migration v3
        // backfills server_id = id for legacy rows so existing local
        // installs keep working.
        // (Migration body lives below the v2 block to preserve order.)

        // v2: outbox completeness + local_id for messages.
        //
        // The v1 pending_queue stores only sealed payload + retry counter.
        // It can't recover from recipient-device rotation because the
        // sealed bytes are pinned to the old recipient pubkey. We add:
        // - recipient_user_id / pinned_recipient_device_id: routing
        // - message_id: ties the pending row to its messages.id
        // - plaintext_wrapped: AEAD-sealed plaintext under dbWrapKey, so
        //   the retry path can re-seal against a fresh recipient pubkey
        //   without ever keeping plaintext at rest.
        //
        // messages.local_id uniquely identifies a row before the server
        // assigns its canonical id — supports de-duplication when our
        // own message echoes back via the catch-up pull.
        m.registerMigration("v2-pending-queue-reencrypt") { db in
            try db.alter(table: "pending_queue") { t in
                t.add(column: "recipient_user_id", .text)
                t.add(column: "pinned_recipient_device_id", .text)
                t.add(column: "message_id", .text)
                t.add(column: "plaintext_wrapped", .blob)
            }
            try db.alter(table: "messages") { t in
                t.add(column: "local_id", .text)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_messages_local_id
                  ON messages(local_id) WHERE local_id IS NOT NULL
                """)
        }

        m.registerMigration("v3-messages-server-id") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "server_id", .text)
            }
            // Backfill carefully. Pre-v3, only rows the SERVER had handled
            // carried a server-assigned id: INCOMING messages (keyed by the
            // server id) and OUTGOING messages already accepted
            // (sent_to_server/delivered/read, whose id was rewritten to the
            // server value on 200). For those, id IS the server id → copy it.
            try db.execute(sql: """
                UPDATE messages SET server_id = id
                 WHERE server_id IS NULL
                   AND (direction = 'in' OR state IN ('sent_to_server', 'delivered', 'read'))
                """)
            // An OUTGOING row the server NEVER accepted still carries id ==
            // local id. Giving it a fake server_id would let a later retry's
            // completePendingSend delete the pending row without binding the
            // REAL server id (it matches on local_id), losing/desyncing the
            // message. Instead identify it by local_id = id so the durable
            // send/complete path can find + bind it, and tie any v1
            // pending_queue row (which shared the message id) to it.
            try db.execute(sql: """
                UPDATE messages SET local_id = id
                 WHERE local_id IS NULL AND server_id IS NULL AND direction = 'out'
                """)
            try db.execute(sql: "UPDATE pending_queue SET message_id = id WHERE message_id IS NULL")
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_messages_server_id
                  ON messages(server_id) WHERE server_id IS NOT NULL
                """)
        }

        // v4: durable read-ack tracking. A read receipt whose server ack
        // POST failed (or was made while paused) must survive relaunch and
        // be retried — otherwise the peer never sees "read". `acked = 0`
        // means "read locally, server not yet told". Existing rows backfill
        // to 0, NOT 1: before this migration a failed read-ack was silently
        // dropped, so a pre-v4 database can hold receipts the server never
        // got. Marking them acked=1 would strand those forever; backfilling
        // to 0 conservatively replays them on the next flush — the server
        // ack is idempotent, so re-acking an already-acked receipt is a
        // harmless no-op.
        m.registerMigration("v4-read-receipt-acked") { db in
            try db.alter(table: "read_receipts") { t in
                t.add(column: "acked", .integer).notNull().defaults(to: 0)
            }
        }

        // v5: preserve immutable send metadata across retries. Without the
        // original sent_at and reply_to_id, an outbox retry re-stamped the
        // message with the retry time (reordering it vs. the recipient) and
        // dropped the reply target (a reply became an ordinary message).
        m.registerMigration("v5-pending-original-metadata") { db in
            try db.alter(table: "pending_queue") { t in
                t.add(column: "original_sent_at", .integer)
                t.add(column: "reply_to_id", .text)
            }
            // Backfill from the matching messages row (tied by message_id ==
            // messages.local_id, with id as the pre-v3 fallback). Without this,
            // a row already queued at upgrade time would retry with original_
            // sent_at NULL — OutboxService then substitutes now(), shifting
            // ordering — and lose its reply linkage.
            try db.execute(sql: """
                UPDATE pending_queue SET
                    original_sent_at = (
                        SELECT m.sent_at FROM messages m
                         WHERE m.local_id = pending_queue.message_id OR m.id = pending_queue.message_id),
                    reply_to_id = (
                        SELECT m.reply_to FROM messages m
                         WHERE m.local_id = pending_queue.message_id OR m.id = pending_queue.message_id)
                 WHERE message_id IS NOT NULL AND original_sent_at IS NULL
                """)
        }

        // v6: tombstones for messages the receive pipeline REJECTED (forged
        // signature, unparseable, mis-routed) — they have no local row but
        // DO exist server-side, so a reaction targeting one can never apply
        // locally. Without a tombstone the reaction catch-up cursor pins on
        // it forever and hides every later reaction. The tombstone lets
        // catch-up dead-letter such reactions and move on.
        m.registerMigration("v6-rejected-message-tombstones") { db in
            try db.create(table: "rejected_messages") { t in
                t.column("server_id", .text).primaryKey()
                t.column("rejected_at", .integer).notNull()
            }
        }

        return m
    }()

    // MARK: - Models

    public struct Message: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
        public var id: String
        public var thread_user_id: String
        public var direction: String      // "in" | "out"
        public var plaintext: String?
        public var ciphertext: Data?
        public var state: String
        public var sent_at: Int64
        public var received_at: Int64?
        public var sort_key: Int64
        public var reply_to: String?
        public var local_id: String?
        public var server_id: String?

        public static let databaseTableName = "messages"

        public init(
            id: String,
            threadUserId: String,
            outgoing: Bool,
            plaintext: String?,
            state: String,
            sentAt: Date,
            receivedAt: Date? = nil,
            replyTo: String? = nil,
            localId: String? = nil,
            serverId: String? = nil
        ) {
            self.id = id
            self.thread_user_id = threadUserId
            self.direction = outgoing ? "out" : "in"
            self.plaintext = plaintext
            self.ciphertext = nil
            self.state = state
            self.sent_at = Int64(sentAt.timeIntervalSince1970 * 1000)
            self.received_at = receivedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
            // sort_key uses COALESCE(received_at, sent_at) semantics from v0.2.3
            self.sort_key = self.received_at ?? self.sent_at
            self.reply_to = replyTo
            self.local_id = localId
            self.server_id = serverId
        }

        // MARK: At-rest body encryption (read side)
        //
        // Fetches select the body through the per-connection `nt_decrypt`
        // function instead of the raw column, so a sealed `ciphertext` is
        // opened back into the `plaintext` the rest of the app expects, and
        // the raw `ciphertext` blob is deliberately NOT selected — the
        // in-memory model stays "plaintext populated, ciphertext nil",
        // which keeps `Equatable` stable across an insert → fetch round-trip.
        // The write side seals via `MessageStore.sealedForPersistence`
        // before the default `PersistableRecord` encode runs.
        public static let databaseSelection: [any SQLSelectable] = [
            Column("id"),
            Column("thread_user_id"),
            Column("direction"),
            SQL("\(sql: MessageStore.bodyDecryptFunctionName)(ciphertext, plaintext)").forKey("plaintext"),
            Column("state"),
            Column("sent_at"),
            Column("received_at"),
            Column("sort_key"),
            Column("reply_to"),
            Column("local_id"),
            Column("server_id"),
        ]
    }

    public struct Reaction: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
        public var message_id: String
        public var user_id: String
        public var reaction: String
        public var set_at: Int64

        public static let databaseTableName = "reactions"

        public init(messageId: String, userId: String, reaction: String, setAt: Date) {
            self.message_id = messageId
            self.user_id = userId
            self.reaction = reaction
            self.set_at = Int64(setAt.timeIntervalSince1970 * 1000)
        }
    }

    public struct User: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable, Identifiable {
        public var user_id: String
        public var display_name: String
        public var color_hint: Int
        public var revoked: Bool

        public static let databaseTableName = "users"
        public var id: String { user_id }

        public init(userId: String, displayName: String, colorHint: Int = 0, revoked: Bool = false) {
            self.user_id = userId
            self.display_name = displayName
            self.color_hint = colorHint
            self.revoked = revoked
        }
    }

    public func upsertUser(_ u: User) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO users (user_id, display_name, color_hint, revoked)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    display_name = excluded.display_name,
                    color_hint   = excluded.color_hint,
                    revoked      = excluded.revoked
                """,
                arguments: [u.user_id, u.display_name, u.color_hint, u.revoked]
            )
        }
    }

    public func allUsers() throws -> [User] {
        try dbQueue.read { db in
            try User.filter(Column("revoked") == false)
                .order(Column("display_name").asc)
                .fetchAll(db)
        }
    }

    public func upsertReaction(_ r: Reaction) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO reactions (message_id, user_id, reaction, set_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(message_id, user_id) DO UPDATE SET
                    reaction = excluded.reaction,
                    set_at   = excluded.set_at
                """,
                arguments: [r.message_id, r.user_id, r.reaction, r.set_at]
            )
        }
    }

    public func clearReaction(messageId: String, userId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM reactions WHERE message_id = ? AND user_id = ?",
                arguments: [messageId, userId]
            )
        }
    }

    public func reactions(forMessageId messageId: String) throws -> [Reaction] {
        try dbQueue.read { db in
            try Reaction
                .filter(Column("message_id") == messageId)
                .order(Column("set_at").asc)
                .fetchAll(db)
        }
    }

    /// Pending-queue row. Survives app relaunch via GRDB; OutboxService
    /// drives retries. `payload` is the sealed envelope pinned to
    /// `pinned_recipient_device_id`; on rotation, OutboxService unwraps
    /// `plaintext_wrapped` (sealed under dbWrapKey) and re-seals to the
    /// new active device.
    public struct PendingMessage: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
        public var id: String
        public var payload: Data
        public var attempts: Int
        public var next_retry_at: Int64?
        public var recipient_user_id: String?
        public var pinned_recipient_device_id: String?
        public var message_id: String?
        public var plaintext_wrapped: Data?
        /// The ORIGINAL send timestamp (ms). Immutable across retries — the
        /// server orders by it, so reusing `now()` on a retry would reorder
        /// the message relative to the recipient's view.
        public var original_sent_at: Int64?
        /// The reply target, preserved so a retried reply stays a reply.
        public var reply_to_id: String?

        public static let databaseTableName = "pending_queue"

        public init(
            id: String,
            payload: Data,
            attempts: Int = 0,
            nextRetryAt: Date? = nil,
            recipientUserId: String? = nil,
            pinnedRecipientDeviceId: String? = nil,
            messageId: String? = nil,
            plaintextWrapped: Data? = nil,
            originalSentAt: Date? = nil,
            replyToId: String? = nil
        ) {
            self.id = id
            self.payload = payload
            self.attempts = attempts
            self.next_retry_at = nextRetryAt.map { Int64($0.timeIntervalSince1970 * 1000) }
            self.recipient_user_id = recipientUserId
            self.pinned_recipient_device_id = pinnedRecipientDeviceId
            self.message_id = messageId
            self.plaintext_wrapped = plaintextWrapped
            self.original_sent_at = originalSentAt.map { Int64($0.timeIntervalSince1970 * 1000) }
            self.reply_to_id = replyToId
        }
    }

    // MARK: - API

    public func insert(_ message: Message) throws {
        let sealed = try sealedForPersistence(message)
        try dbQueue.write { db in
            try sealed.insert(db)
        }
    }

    public func thread(for threadUserId: String, limit: Int = 500) throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .filter(Column("thread_user_id") == threadUserId)
                .order(Column("sort_key").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func markRead(_ messageId: String, at: Date = Date()) throws {
        try dbQueue.write { db in
            // New receipt → acked = 0 (server not yet told). A REPLACE keeps
            // the row unacked until the server confirms.
            try db.execute(
                sql: "INSERT OR REPLACE INTO read_receipts (message_id, read_at, acked) VALUES (?, ?, 0)",
                arguments: [messageId, Int64(at.timeIntervalSince1970 * 1000)]
            )
        }
    }

    /// Mark a read receipt as acknowledged by the server (keyed by the
    /// message's SERVER id — the ack the peer received).
    public func markReadAcked(serverId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE read_receipts SET acked = 1
                 WHERE message_id IN (SELECT id FROM messages WHERE server_id = ?)
                """,
                arguments: [serverId]
            )
        }
    }

    /// Server ids of read receipts whose ack never landed (POST failed, or
    /// made while paused, possibly across a relaunch). Drained on reconnect
    /// / foreground so the peer eventually sees "read".
    public func unackedReadReceipts() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT m.server_id FROM read_receipts r
                  JOIN messages m ON m.id = r.message_id
                 WHERE r.acked = 0 AND m.server_id IS NOT NULL
                 ORDER BY r.read_at ASC, m.server_id ASC
                """
            )
        }
    }

    /// Incoming messages in `threadUserId` that have no read receipt
    /// yet — the set `AppState.markThreadRead` acks to the server
    /// before stamping them locally.
    public func unreadIncoming(threadUserId: String) throws -> [Message] {
        try dbQueue.read { db in
            try Message.fetchAll(
                db,
                sql: """
                SELECT m.* FROM messages m
                LEFT JOIN read_receipts r ON r.message_id = m.id
                WHERE m.thread_user_id = ? AND m.direction = 'in' AND r.message_id IS NULL
                """,
                arguments: [threadUserId]
            )
        }
    }

    /// Mark every incoming message in `threadUserId` as locally read.
    /// Used by `LiveChatThreadView.onAppear` so the chat-list unread
    /// badge clears the moment the user enters the conversation.
    /// Idempotent — `INSERT OR IGNORE` skips already-read rows.
    public func markThreadRead(threadUserId: String, at: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO read_receipts (message_id, read_at, acked)
                SELECT id, ?, 0
                  FROM messages
                 WHERE thread_user_id = ? AND direction = 'in'
                """,
                arguments: [Int64(at.timeIntervalSince1970 * 1000), threadUserId]
            )
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
    }

    /// Look up a row by its stable client id (the lifelong primary key).
    public func message(id: String) throws -> Message? {
        try dbQueue.read { db in
            try Message.filter(Column("id") == id).fetchOne(db)
        }
    }

    /// Look up a row by its server-assigned id (set on 200 OK from
    /// POST /api/v1/messages or carried in catch-up rows). The dedup
    /// join key for incoming traffic.
    public func message(serverId: String) throws -> Message? {
        try dbQueue.read { db in
            try Message.filter(Column("server_id") == serverId).fetchOne(db)
        }
    }

    /// Look up a row by its local_id (the client-generated UUID assigned
    /// at send time, pre-server-roundtrip). Used by MessageReceiveService
    /// to de-duplicate echoes of our own outgoing messages.
    public func message(localId: String) throws -> Message? {
        try dbQueue.read { db in
            try Message.filter(Column("local_id") == localId).fetchOne(db)
        }
    }

    /// Update an existing row's state + bind the server-assigned id.
    /// The send pipeline calls this on 200-OK. The row's `id` (the
    /// stable client UUID) is NEVER rewritten — every other table that
    /// references messages.id stays valid for the row's lifetime.
    public func updateMessage(localId: String, serverId: String?, state: String) throws {
        try dbQueue.write { db in
            if let serverId {
                try db.execute(
                    sql: "UPDATE messages SET server_id = ?, state = ? WHERE local_id = ?",
                    arguments: [serverId, state, localId]
                )
            } else {
                try db.execute(
                    sql: "UPDATE messages SET state = ? WHERE local_id = ?",
                    arguments: [state, localId]
                )
            }
        }
    }

    public func updateMessageState(id: String, state: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE messages SET state = ? WHERE id = ?",
                arguments: [state, id]
            )
        }
    }

    /// Record a server message id the receive pipeline rejected (forged /
    /// unparseable / mis-routed) so a reaction targeting it can be
    /// dead-lettered instead of wedging catch-up. Idempotent.
    public func tombstoneRejected(serverId: String, at: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO rejected_messages (server_id, rejected_at) VALUES (?, ?)",
                arguments: [serverId, Int64(at.timeIntervalSince1970 * 1000)]
            )
        }
    }

    /// Whether a server message id was rejected by the receive pipeline.
    public func isRejected(serverId: String) -> Bool {
        let found = try? dbQueue.read { db -> Bool in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM rejected_messages WHERE server_id = ?)",
                arguments: [serverId]
            ) ?? false
        }
        return found ?? false
    }

    public func updateMessageStateByServerId(_ serverId: String, state: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE messages SET state = ? WHERE server_id = ?",
                arguments: [state, serverId]
            )
        }
    }

    /// Mark an outgoing row failed/failed_permanently ONLY if it hasn't already
    /// been sent — `server_id IS NULL` is the SQL CAS guard. The first POST and
    /// OutboxService can race on the same pending row; if the outbox bound a
    /// server_id first (completePendingSend, atomic), a late failure from the
    /// original POST must NOT downgrade the now-sent message to failed. Returns
    /// whether a row was actually updated.
    @discardableResult
    public func markSendFailedIfUnsent(localId: String, state: String) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE messages SET state = ?
                 WHERE local_id = ? AND server_id IS NULL
                   AND state NOT IN ('sent_to_server', 'delivered', 'read')
                """,
                arguments: [state, localId]
            )
            return db.changesCount > 0
        }
    }

    /// Atomically mark an outgoing send permanently failed AND drop its
    /// pending_queue row in ONE transaction — only if it hasn't already been
    /// sent (`server_id IS NULL`, the same CAS as `markSendFailedIfUnsent`).
    /// Doing these as two separate writes risks a crash in between (or a
    /// swallowed delete error) that returns `failed_permanently` to the caller
    /// while the retry row survives — `OutboxService` would then re-send a
    /// message the user was told had permanently failed. Returns whether THIS
    /// call performed the transition (false → a concurrent send already bound
    /// the server id; the pending row is left for that path to reconcile).
    public func failPendingPermanentlyIfUnsent(
        localId: String, pendingId: String, state: String = "failed_permanently"
    ) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE messages SET state = ?
                 WHERE local_id = ? AND server_id IS NULL
                   AND state NOT IN ('sent_to_server', 'delivered', 'read')
                """,
                arguments: [state, localId]
            )
            let marked = db.changesCount > 0
            if marked {
                try db.execute(sql: "DELETE FROM pending_queue WHERE id = ?", arguments: [pendingId])
            }
            return marked
        }
    }

    /// Advance an outgoing row to "delivered" only if it hasn't already been
    /// read. The `state != 'read'` guard lives in SQL so a racing WS read
    /// receipt that lands during an async status reconcile can't be
    /// clobbered by a stale snapshot (never-downgrade, race-safe).
    public func markDeliveredIfNotRead(serverId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE messages SET state = 'delivered' WHERE server_id = ? AND state != 'read'",
                arguments: [serverId]
            )
        }
    }

    /// The plaintext stored for an inbound envelope we could authenticate but
    /// not decrypt (e.g. it was sealed for a device we have since rotated away
    /// from). Surfaces in the UI as a placeholder. Such ciphertext is
    /// permanently unreadable by the current device — an inherent property of
    /// E2EE re-enrollment; the sender resends as a new message if needed.
    public static let undecryptablePlaceholder = "(undecryptable envelope)"

    /// Outgoing rows whose delivery receipt is still open — they reached
    /// the server (`sent_to_server`) or were delivered but not yet read.
    /// Used to reconcile receipts the best-effort WS broadcast dropped
    /// while we were offline. Only rows with a server id are returnable
    /// (the status endpoint is keyed by server id).
    public func outgoingAwaitingReceipt() throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .filter(sql: "direction = 'out' AND server_id IS NOT NULL AND state IN ('sent_to_server', 'delivered')")
                .fetchAll(db)
        }
    }

    // MARK: - Pending queue API

    public func enqueuePending(_ pending: PendingMessage) throws {
        try dbQueue.write { db in try pending.insert(db) }
    }

    public func pendingDue(now: Date = Date()) throws -> [PendingMessage] {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return try dbQueue.read { db in
            try PendingMessage
                .filter(sql: "next_retry_at IS NULL OR next_retry_at <= ?", arguments: [nowMs])
                .order(sql: "next_retry_at IS NULL DESC, next_retry_at ASC")
                .fetchAll(db)
        }
    }

    public func deletePending(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_queue WHERE id = ?", arguments: [id])
        }
    }

    /// Atomically complete a successful send: bind the server id + lift the
    /// message state AND remove its pending_queue row in ONE transaction.
    /// Doing these as two separate writes (delete-then-update) risks a crash
    /// in between that leaves NO retry record AND NO server_id — a message
    /// the recipient may already hold, that the sender can't reconcile.
    ///
    /// CLAIM-GUARDED: the message update runs ONLY if THIS call still owns the
    /// pending row (the DELETE removed it). If the row is already gone — e.g.
    /// `failPendingPermanentlyIfUnsent` terminally failed it on the fast path
    /// while a stale outbox snapshot was mid-flight — we must NOT resurrect a
    /// message the user was told had permanently failed (phantom-send). Also
    /// makes a double-completion (fast path + outbox both succeed) idempotent:
    /// the second loses the claim and no-ops.
    public func completePendingSend(
        pendingId: String,
        messageLocalId: String?,
        serverId: String,
        state: String = "sent_to_server"
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_queue WHERE id = ?", arguments: [pendingId])
            let claimed = db.changesCount > 0
            if claimed, let messageLocalId {
                try db.execute(
                    sql: "UPDATE messages SET server_id = ?, state = ? WHERE local_id = ?",
                    arguments: [serverId, state, messageLocalId]
                )
            }
        }
    }

    public func updatePending(_ pending: PendingMessage) throws {
        try dbQueue.write { db in try pending.update(db) }
    }

    // MARK: - Cursors

    public func cursor(name: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db,
                sql: "SELECT value FROM local_cursors WHERE name = ?",
                arguments: [name])
        }
    }

    public func setCursor(name: String, value: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO local_cursors (name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value",
                arguments: [name, value]
            )
        }
    }
}

