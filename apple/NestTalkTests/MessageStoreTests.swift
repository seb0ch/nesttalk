import XCTest
import CryptoKit
import GRDB
#if os(iOS)
@testable import NestTalk_iOS
#elseif os(macOS)
@testable import NestTalk_macOS
#endif

final class MessageStoreTests: XCTestCase {

    func test_insert_and_fetch_thread_preserves_order() throws {
        let store = try MessageStore.inMemory()

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let msgs: [MessageStore.Message] = [
            .init(id: "m-3", threadUserId: "mom", outgoing: true,  plaintext: "Safe, xx",         state: "delivered", sentAt: t0.addingTimeInterval(+120)),
            .init(id: "m-1", threadUserId: "mom", outgoing: false, plaintext: "Land yet?",        state: "delivered", sentAt: t0),
            .init(id: "m-2", threadUserId: "mom", outgoing: true,  plaintext: "Just landed 🧡", state: "delivered", sentAt: t0.addingTimeInterval(+60)),
            .init(id: "m-o", threadUserId: "dad", outgoing: false, plaintext: "Photo sent",       state: "delivered", sentAt: t0),
        ]
        for m in msgs { try store.insert(m) }

        let momThread = try store.thread(for: "mom")
        XCTAssertEqual(momThread.map(\.id), ["m-1", "m-2", "m-3"])

        let dadThread = try store.thread(for: "dad")
        XCTAssertEqual(dadThread.map(\.id), ["m-o"])
    }

    func test_markRead_upserts_read_receipt() throws {
        let store = try MessageStore.inMemory()
        let m = MessageStore.Message(
            id: "m-1", threadUserId: "mom", outgoing: false,
            plaintext: "Hello", state: "delivered", sentAt: Date()
        )
        try store.insert(m)
        try store.markRead("m-1")
        // idempotent — calling again must not throw
        try store.markRead("m-1")

        let count = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM read_receipts WHERE message_id = ?", arguments: ["m-1"])
        }
        XCTAssertEqual(count, 1)
    }

    func test_count_reflects_inserts() throws {
        let store = try MessageStore.inMemory()
        XCTAssertEqual(try store.count(), 0)
        try store.insert(.init(
            id: "m-1", threadUserId: "x", outgoing: false,
            plaintext: "hi", state: "delivered", sentAt: Date()
        ))
        XCTAssertEqual(try store.count(), 1)
    }

    func test_in_memory_accepts_wrap_key_without_breakage() throws {
        // Plain-GRDB build path: passing a wrap key must not break basic
        // operations. SQLCipher enforcement is gated behind the
        // NESTTALK_SQLCIPHER build flag (deferred to a future sprint that
        // adds the dependency), but the plumbing is exercised here so a
        // future flip is a one-line change.
        let key = try DatabaseWrapKey.loadOrCreate(tag: "nt.test.dbwrap.\(UUID().uuidString)")
        defer { DatabaseWrapKey.deleteForTesting(tag: "nt.test.dbwrap.unused") }
        let store = try MessageStore.inMemory(wrapKey: key)
        try store.insert(.init(
            id: "wrap-1", threadUserId: "alice", outgoing: true,
            plaintext: "ok", state: "delivered", sentAt: Date()
        ))
        XCTAssertEqual(try store.count(), 1)
    }

    func test_schema_has_all_v0_2_3_tables() throws {
        let store = try MessageStore.inMemory()
        let tables: Set<String> = try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            return Set(rows.compactMap { $0["name"] as String? })
        }
        XCTAssertTrue(tables.contains("users"))
        XCTAssertTrue(tables.contains("messages"))
        XCTAssertTrue(tables.contains("pending_queue"))
        XCTAssertTrue(tables.contains("reactions"))
        XCTAssertTrue(tables.contains("read_receipts"))
    }
}

extension MessageStoreTests {
    /// Upgrade migration: a legacy un-namespaced DB at
    /// <bundle>/messages.sqlite must move into the per-user dir so
    /// history survives the path change instead of vanishing.
    @MainActor
    func test_legacy_real_db_migrates_with_history_intact() async throws {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let bundle = Bundle.main.bundleIdentifier ?? "NestTalk"
        let bundleDir = support.appendingPathComponent(bundle, isDirectory: true)
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let legacy = bundleDir.appendingPathComponent("messages.sqlite")
        let userId = "migrate-user-\(UUID().uuidString)"
        // Clean the legacy DB, the per-user dir, AND the `.legacy-owner`
        // ownership sentinel — the sentinel persists in real Application
        // Support and would quarantine the next run otherwise.
        try? fm.removeItem(at: bundleDir.appendingPathComponent(".legacy-owner"))
        defer {
            for sfx in ["", "-wal", "-shm"] { try? fm.removeItem(at: URL(fileURLWithPath: legacy.path + sfx)) }
            try? fm.removeItem(at: bundleDir.appendingPathComponent(userId))
            try? fm.removeItem(at: bundleDir.appendingPathComponent(".legacy-owner"))
        }

        // Build a REAL WAL-mode GRDB store at the legacy path and write a
        // message, so the migration is exercised against an actual SQLite
        // file set (main + WAL), not a marker file.
        let key = SymmetricKey(size: .bits256)
        do {
            let legacyStore = try MessageStore(path: legacy.path, wrapKey: key)
            try legacyStore.insert(MessageStore.Message(
                id: "m-legacy", threadUserId: "mom", outgoing: false,
                plaintext: "history survives", state: "delivered", sentAt: Date(),
                serverId: "srv-legacy"
            ))
        } // closing checkpoints WAL → main on the last connection

        // The owner is recorded at launch (here, simulated) from the
        // pre-re-enroll identity — without it, migration fails closed.
        AppState.claimLegacyOwnerIfUnclaimed(userId: userId)

        // Migrate by resolving the new path, then open it and verify the
        // row is present.
        let newPath = try AppState.messageStorePath(userId: userId)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "legacy main file must be moved")
        let migrated = try MessageStore(path: newPath, wrapKey: key)
        let row = try XCTUnwrap(migrated.message(serverId: "srv-legacy"))
        XCTAssertEqual(row.plaintext, "history survives")
    }

    /// Round-18 regression: the un-namespaced legacy DB belongs to whoever
    /// claims it first; a DIFFERENT account must be quarantined away from
    /// it, never have the prior account's messages copied into its dir.
    @MainActor
    func test_legacy_migration_quarantines_a_different_account() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let legacy = tmp.appendingPathComponent("messages.sqlite")
        let sentinel = tmp.appendingPathComponent(".legacy-owner")
        let key = SymmetricKey(size: .bits256)
        do {
            let s = try MessageStore(path: legacy.path, wrapKey: key)
            try s.insert(MessageStore.Message(
                id: "m1", threadUserId: "mom", outgoing: false,
                plaintext: "private", state: "delivered", sentAt: Date(), serverId: "srv1"))
        }

        // The owner was recorded (at launch) as userA.
        try Data("userA".utf8).write(to: sentinel)

        // User A (the recorded owner) receives the legacy DB.
        let dirA = tmp.appendingPathComponent("A", isDirectory: true)
        try fm.createDirectory(at: dirA, withIntermediateDirectories: true)
        let newA = dirA.appendingPathComponent("messages.sqlite")
        try AppState.migrateLegacyDBIfNeeded(
            legacy: legacy, newPath: newA, markerDir: dirA,
            currentUserId: "userA", ownerSentinel: sentinel)
        XCTAssertTrue(fm.fileExists(atPath: newA.path), "owner A must receive the legacy DB")

        // User B (a DIFFERENT account) must be quarantined — no copy.
        let dirB = tmp.appendingPathComponent("B", isDirectory: true)
        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
        let newB = dirB.appendingPathComponent("messages.sqlite")
        try AppState.migrateLegacyDBIfNeeded(
            legacy: legacy, newPath: newB, markerDir: dirB,
            currentUserId: "userB", ownerSentinel: sentinel)
        XCTAssertFalse(fm.fileExists(atPath: newB.path),
                       "a different account must NOT receive the prior account's DB")
    }

    /// Round-28 regression: completing a send binds the server id AND drops
    /// the pending row in ONE transaction, so a crash can't strand a
    /// delivered message with no retry record and no server_id.
    /// Round-48 regression: the v3 migration must NOT stamp a fake server_id on
    /// an outgoing row the server never accepted. A pre-v3 unsent outgoing row
    /// carried id == local id; giving it server_id = id would let a later retry
    /// complete + delete the pending row without binding the REAL server id,
    /// desyncing the message. Sent/incoming rows (id IS the server id) still
    /// backfill server_id.
    func test_v3_migration_does_not_fake_server_id_for_unsent_outgoing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("legacy.sqlite").path

        // Build a pre-v3 DB: v1 + v2 schema only (same migration identifiers
        // MessageStore uses, so its migrator resumes at v3).
        do {
            let pre = try DatabaseQueue(path: path)
            var m = DatabaseMigrator()
            m.registerMigration("v1-initial-schema") { db in
                try db.create(table: "messages") { t in
                    t.column("id", .text).primaryKey()
                    t.column("thread_user_id", .text).notNull()
                    t.column("direction", .text).notNull()
                    t.column("plaintext", .text)
                    t.column("ciphertext", .blob)
                    t.column("state", .text).notNull()
                    t.column("sent_at", .integer).notNull()
                    t.column("received_at", .integer)
                    t.column("sort_key", .integer).notNull()
                    t.column("reply_to", .text)
                }
                try db.create(table: "pending_queue") { t in
                    t.column("id", .text).primaryKey()
                    t.column("payload", .blob).notNull()
                    t.column("attempts", .integer).notNull().defaults(to: 0)
                    t.column("next_retry_at", .integer)
                }
                // Tables later migrations touch (v4 alters read_receipts) must
                // exist so the resumed migrator can run cleanly.
                try db.create(table: "users") { t in
                    t.column("user_id", .text).primaryKey()
                    t.column("display_name", .text).notNull()
                    t.column("color_hint", .integer).notNull().defaults(to: 0)
                    t.column("revoked", .boolean).notNull().defaults(to: false)
                }
                try db.create(table: "reactions") { t in
                    t.column("message_id", .text).notNull()
                    t.column("user_id", .text).notNull()
                    t.column("reaction", .text).notNull()
                    t.column("set_at", .integer).notNull()
                    t.primaryKey(["message_id", "user_id"])
                }
                try db.create(table: "read_receipts") { t in
                    t.column("message_id", .text).primaryKey()
                    t.column("read_at", .integer).notNull()
                }
                try db.create(table: "local_cursors") { t in
                    t.column("name", .text).primaryKey()
                    t.column("value", .text).notNull()
                }
            }
            m.registerMigration("v2-pending-queue-reencrypt") { db in
                try db.alter(table: "pending_queue") { t in
                    t.add(column: "recipient_user_id", .text)
                    t.add(column: "pinned_recipient_device_id", .text)
                    t.add(column: "message_id", .text)
                    t.add(column: "plaintext_wrapped", .blob)
                }
                try db.alter(table: "messages") { t in t.add(column: "local_id", .text) }
                try db.execute(sql: "CREATE UNIQUE INDEX idx_messages_local_id ON messages(local_id) WHERE local_id IS NOT NULL")
            }
            try m.migrate(pre)
            try pre.write { db in
                // Unsent outgoing: id == local id, never reached the server.
                try db.execute(sql: "INSERT INTO messages (id, thread_user_id, direction, plaintext, state, sent_at, sort_key) VALUES ('local-1','mom','out','hi','failed',1,1)")
                try db.execute(sql: "INSERT INTO pending_queue (id, payload, attempts) VALUES ('local-1', X'01', 1)")
                // Outgoing already accepted: id IS the server id.
                try db.execute(sql: "INSERT INTO messages (id, thread_user_id, direction, plaintext, state, sent_at, sort_key) VALUES ('srv-2','mom','out','done','sent_to_server',2,2)")
                // Incoming: id IS the server id.
                try db.execute(sql: "INSERT INTO messages (id, thread_user_id, direction, plaintext, state, sent_at, sort_key) VALUES ('srv-3','mom','in','hey','delivered',3,3)")
            }
        }

        // Open MessageStore → runs v3+.
        let store = try MessageStore(path: path, wrapKey: SymmetricKey(size: .bits256))

        // Unsent outgoing: NO fake server_id; identified by local_id; pending tied.
        XCTAssertNil(try store.message(serverId: "local-1"),
                     "an unsent outgoing row must not get a fake server_id")
        XCTAssertNotNil(try store.message(localId: "local-1"),
                        "an unsent outgoing row is identified by local_id after migration")
        let pendings = try store.pendingDue(now: Date(timeIntervalSinceNow: 9999))
        XCTAssertEqual(pendings.first?.message_id, "local-1",
                       "the v1 pending row must be tied to its message by message_id")

        // Sent + incoming: server_id backfilled.
        XCTAssertNotNil(try store.message(serverId: "srv-2"), "accepted outgoing keeps server_id = id")
        XCTAssertNotNil(try store.message(serverId: "srv-3"), "incoming keeps server_id = id")
    }

    /// Round-52 regression: the v5 migration adds pending_queue.original_sent_at
    /// + reply_to_id; existing queued rows must be BACKFILLED from their message,
    /// or a reply already queued at upgrade retries with shifted ordering
    /// (now() substituted) and lost reply linkage.
    func test_v5_migration_backfills_pending_reply_metadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("legacy.sqlite").path

        do {
            let pre = try DatabaseQueue(path: path)
            var m = DatabaseMigrator()
            m.registerMigration("v1-initial-schema") { db in
                try db.create(table: "messages") { t in
                    t.column("id", .text).primaryKey()
                    t.column("thread_user_id", .text).notNull()
                    t.column("direction", .text).notNull()
                    t.column("plaintext", .text)
                    t.column("ciphertext", .blob)
                    t.column("state", .text).notNull()
                    t.column("sent_at", .integer).notNull()
                    t.column("received_at", .integer)
                    t.column("sort_key", .integer).notNull()
                    t.column("reply_to", .text)
                }
                try db.create(table: "pending_queue") { t in
                    t.column("id", .text).primaryKey()
                    t.column("payload", .blob).notNull()
                    t.column("attempts", .integer).notNull().defaults(to: 0)
                    t.column("next_retry_at", .integer)
                }
                try db.create(table: "read_receipts") { t in
                    t.column("message_id", .text).primaryKey()
                    t.column("read_at", .integer).notNull()
                }
            }
            m.registerMigration("v2-pending-queue-reencrypt") { db in
                try db.alter(table: "pending_queue") { t in
                    t.add(column: "recipient_user_id", .text)
                    t.add(column: "pinned_recipient_device_id", .text)
                    t.add(column: "message_id", .text)
                    t.add(column: "plaintext_wrapped", .blob)
                }
                try db.alter(table: "messages") { t in t.add(column: "local_id", .text) }
                try db.execute(sql: "CREATE UNIQUE INDEX idx_messages_local_id ON messages(local_id) WHERE local_id IS NOT NULL")
            }
            try m.migrate(pre)
            try pre.write { db in
                // Reply target + an outgoing reply queued at an OLD sent_at.
                try db.execute(sql: "INSERT INTO messages (id, thread_user_id, direction, plaintext, state, sent_at, sort_key) VALUES ('parent-1','mom','in','q','delivered',100,100)")
                try db.execute(sql: "INSERT INTO messages (id, thread_user_id, direction, plaintext, state, sent_at, sort_key, reply_to) VALUES ('reply-1','mom','out','re','failed',12345,12345,'parent-1')")
                try db.execute(sql: "INSERT INTO pending_queue (id, payload, attempts, message_id) VALUES ('reply-1', X'01', 1, 'reply-1')")
            }
        }

        let store = try MessageStore(path: path, wrapKey: SymmetricKey(size: .bits256))
        let pending = try store.pendingDue(now: Date(timeIntervalSinceNow: 9999))
        let row = try XCTUnwrap(pending.first(where: { $0.id == "reply-1" }))
        XCTAssertEqual(row.original_sent_at, 12345,
                       "queued reply must keep its original sent_at across upgrade")
        XCTAssertEqual(row.reply_to_id, "parent-1",
                       "queued reply must keep its reply linkage across upgrade")
    }

    /// Round-50 regression: the first POST and OutboxService can race on the
    /// same durable row. A late failure from the original POST must never
    /// downgrade a message the outbox already sent — markSendFailedIfUnsent is
    /// a CAS guarded on `server_id IS NULL`.
    func test_mark_send_failed_is_skipped_once_sent() throws {
        let store = try MessageStore.inMemory()

        // Already sent (server_id bound, as a concurrent outbox would set).
        try store.insert(MessageStore.Message(
            id: "m-sent", threadUserId: "mom", outgoing: true, plaintext: "hi",
            state: "sent_to_server", sentAt: Date(), localId: "m-sent", serverId: "srv-1"))
        XCTAssertFalse(try store.markSendFailedIfUnsent(localId: "m-sent", state: "failed"),
                       "a sent message must not be marked failed")
        XCTAssertEqual(try store.message(serverId: "srv-1")?.state, "sent_to_server",
                       "state stays sent — success wins the race")

        // Genuinely unsent (no server_id) → the failure write applies.
        try store.insert(MessageStore.Message(
            id: "m-unsent", threadUserId: "mom", outgoing: true, plaintext: "yo",
            state: "sending", sentAt: Date(), localId: "m-unsent"))
        XCTAssertTrue(try store.markSendFailedIfUnsent(localId: "m-unsent", state: "failed_permanently"))
        XCTAssertEqual(try store.message(localId: "m-unsent")?.state, "failed_permanently")
    }

    func test_complete_pending_send_binds_and_deletes_atomically() throws {
        let store = try MessageStore.inMemory()
        let local = "local-x"
        try store.insert(MessageStore.Message(
            id: local, threadUserId: "mom", outgoing: true,
            plaintext: "hi", state: "failed", sentAt: Date(), localId: local))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: local, payload: Data([0x01]), attempts: 1,
            recipientUserId: "mom", messageId: local))

        try store.completePendingSend(pendingId: local, messageLocalId: local, serverId: "srv-X")

        let row = try XCTUnwrap(store.message(serverId: "srv-X"))
        XCTAssertEqual(row.state, "sent_to_server")
        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 9999)).count, 0,
                       "pending row must be removed in the same transaction")
    }

    /// Round-9 review: permanent failure must mark the message AND drop its
    /// pending row in ONE transaction. Two separate writes risk a crash (or a
    /// swallowed delete error) that returns failed_permanently to the caller
    /// while the retry row survives — the outbox would then re-send a message
    /// the user was told had permanently failed.
    func test_fail_pending_permanently_marks_and_deletes_atomically() throws {
        let store = try MessageStore.inMemory()
        let local = "local-fail"
        try store.insert(MessageStore.Message(
            id: local, threadUserId: "mom", outgoing: true,
            plaintext: "oops", state: "sending", sentAt: Date(), localId: local))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: local, payload: Data(), attempts: 1,
            recipientUserId: "mom", messageId: local))

        let marked = try store.failPendingPermanentlyIfUnsent(localId: local, pendingId: local)
        XCTAssertTrue(marked)
        XCTAssertEqual(try store.message(localId: local)?.state, "failed_permanently")
        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 9999)).count, 0,
                       "pending row must be removed in the same transaction")
    }

    /// CAS guard: if a concurrent send already bound the server id, the
    /// permanent-failure transition must be a no-op — success wins, and the
    /// (already-removed-by-completePendingSend) pending row is left untouched.
    func test_fail_pending_permanently_is_skipped_once_sent() throws {
        let store = try MessageStore.inMemory()
        let local = "local-sent"
        try store.insert(MessageStore.Message(
            id: local, threadUserId: "mom", outgoing: true, plaintext: "hi",
            state: "sent_to_server", sentAt: Date(), localId: local, serverId: "srv-9"))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: local, payload: Data(), attempts: 1,
            recipientUserId: "mom", messageId: local))

        let marked = try store.failPendingPermanentlyIfUnsent(localId: local, pendingId: local)
        XCTAssertFalse(marked, "a sent message must not be marked permanently failed")
        XCTAssertEqual(try store.message(serverId: "srv-9")?.state, "sent_to_server")
        XCTAssertEqual(try store.pendingDue(now: Date(timeIntervalSinceNow: 9999)).count, 1,
                       "pending row must be retained when the CAS loses to a concurrent send")
    }

    /// Round-10 review (phantom-send): once the fast path has terminally
    /// failed a message and removed its pending row, a stale outbox snapshot
    /// that later "succeeds" must NOT resurrect it. completePendingSend is
    /// claim-guarded — it only updates the message if its DELETE still owned
    /// the pending row.
    func test_complete_pending_send_does_not_resurrect_terminally_failed() throws {
        let store = try MessageStore.inMemory()
        let local = "local-resurrect"
        try store.insert(MessageStore.Message(
            id: local, threadUserId: "mom", outgoing: true,
            plaintext: "x", state: "sending", sentAt: Date(), localId: local))
        try store.enqueuePending(MessageStore.PendingMessage(
            id: local, payload: Data(), attempts: 1,
            recipientUserId: "mom", messageId: local))

        // Fast path terminally fails it (marks failed_permanently + deletes
        // pending in one transaction).
        XCTAssertTrue(try store.failPendingPermanentlyIfUnsent(localId: local, pendingId: local))

        // A stale outbox snapshot then completes the same row.
        try store.completePendingSend(pendingId: local, messageLocalId: local, serverId: "srv-late")

        XCTAssertEqual(try store.message(localId: local)?.state, "failed_permanently",
                       "a terminally-failed message must not be resurrected to sent")
        XCTAssertNil(try store.message(localId: local)?.server_id,
                     "no server id may be bound to a message the user was told failed")
    }

    /// Round-26 regression: the delivered-update is conditional in SQL, so a
    /// racing read receipt that lands during an async status reconcile can't
    /// be downgraded by a stale snapshot.
    func test_mark_delivered_if_not_read_never_downgrades() throws {
        let store = try MessageStore.inMemory()
        try store.insert(MessageStore.Message(
            id: "m-read", threadUserId: "mom", outgoing: true,
            plaintext: "a", state: "read", sentAt: Date(), serverId: "srv-read"))
        try store.insert(MessageStore.Message(
            id: "m-sent", threadUserId: "mom", outgoing: true,
            plaintext: "b", state: "sent_to_server", sentAt: Date(), serverId: "srv-sent"))

        try store.markDeliveredIfNotRead(serverId: "srv-read")
        try store.markDeliveredIfNotRead(serverId: "srv-sent")

        XCTAssertEqual(try store.message(serverId: "srv-read")?.state, "read",
                       "a read row must NOT be downgraded to delivered")
        XCTAssertEqual(try store.message(serverId: "srv-sent")?.state, "delivered",
                       "a not-yet-read row advances to delivered")
    }

    /// Round-30 regression: a rejected parent (forged / unparseable /
    /// mis-routed) is tombstoned so reaction catch-up can dead-letter
    /// reactions that target it instead of pinning the cursor forever.
    func test_tombstone_rejected_is_idempotent_and_queryable() throws {
        let store = try MessageStore.inMemory()
        XCTAssertFalse(store.isRejected(serverId: "srv-bad"),
                       "an untombstoned id must not read as rejected")

        try store.tombstoneRejected(serverId: "srv-bad")
        XCTAssertTrue(store.isRejected(serverId: "srv-bad"))

        // INSERT OR IGNORE — a second tombstone of the same id must not throw.
        try store.tombstoneRejected(serverId: "srv-bad")
        XCTAssertTrue(store.isRejected(serverId: "srv-bad"))
        XCTAssertFalse(store.isRejected(serverId: "srv-other"))
    }

    /// Round-19 regression: a legacy DB with NO recorded owner (the owner's
    /// identity was already gone before this build first ran) must FAIL
    /// CLOSED — never auto-claimed by whatever account happens to enroll.
    @MainActor
    func test_legacy_migration_fails_closed_when_owner_unrecorded() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legacy-fc-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let legacy = tmp.appendingPathComponent("messages.sqlite")
        let sentinel = tmp.appendingPathComponent(".legacy-owner")   // never written
        let key = SymmetricKey(size: .bits256)
        do {
            let s = try MessageStore(path: legacy.path, wrapKey: key)
            try s.insert(MessageStore.Message(
                id: "m1", threadUserId: "mom", outgoing: false,
                plaintext: "private", state: "delivered", sentAt: Date(), serverId: "srv1"))
        }
        let dir = tmp.appendingPathComponent("X", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let newX = dir.appendingPathComponent("messages.sqlite")
        try AppState.migrateLegacyDBIfNeeded(
            legacy: legacy, newPath: newX, markerDir: dir,
            currentUserId: "userX", ownerSentinel: sentinel)
        XCTAssertFalse(fm.fileExists(atPath: newX.path),
                       "an unowned legacy DB must not be migrated into an arbitrary account")
    }

    /// Round-57: app-level column encryption. With a wrap key present, a
    /// message body must never touch the disk in cleartext — it lives only
    /// as an AEAD-sealed blob in `ciphertext`, the `plaintext` column is
    /// NULL, and the cleartext appears nowhere in the file set. The correct
    /// key round-trips the body transparently (record path AND the raw-SQL
    /// ThreadSummary path); a different key recovers nothing.
    func test_message_body_is_encrypted_at_rest_with_wrap_key() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("enc.sqlite").path

        let key = SymmetricKey(size: .bits256)
        let secret = "rendezvous at the old pier, 9pm"

        do {
            let store = try MessageStore(path: path, wrapKey: key)
            try store.upsertUser(.init(userId: "mom", displayName: "Mom"))
            try store.insert(MessageStore.Message(
                id: "enc-1", threadUserId: "mom", outgoing: true,
                plaintext: secret, state: "delivered", sentAt: Date(), serverId: "srv-enc-1"))
        } // closing checkpoints WAL → main

        // 1. At rest: plaintext column NULL, body sealed, no cleartext in
        //    any stored column. Read raw columns through a bare queue so the
        //    store's transparent decode does not mask the on-disk shape.
        let raw = try DatabaseQueue(path: path)
        try raw.read { db in
            let row = try XCTUnwrap(
                try Row.fetchOne(db, sql: "SELECT plaintext, ciphertext FROM messages WHERE id = 'enc-1'"))
            XCTAssertNil(row["plaintext"] as String?, "body must not be stored in cleartext")
            let blob = try XCTUnwrap(row["ciphertext"] as Data?, "body must be sealed into ciphertext")
            XCTAssertNil(blob.range(of: Data(secret.utf8)), "sealed blob must not contain the cleartext")
        }

        // 2. The cleartext must not appear in the on-disk file set.
        for sfx in ["", "-wal"] {
            if let data = FileManager.default.contents(atPath: path + sfx) {
                XCTAssertNil(data.range(of: Data(secret.utf8)), "cleartext leaked into \(path + sfx)")
            }
        }

        // 3. Correct key round-trips the body — both the record path and the
        //    raw-SQL ThreadSummary path open the sealed blob transparently.
        do {
            let store = try MessageStore(path: path, wrapKey: key)
            let msg = try XCTUnwrap(store.message(serverId: "srv-enc-1"))
            XCTAssertEqual(msg.plaintext, secret)
            let summaries = try store.dbQueue.read { db in try ThreadSummaryQuery().fetch(db) }
            XCTAssertEqual(summaries.first(where: { $0.threadUserId == "mom" })?.last, secret,
                           "the chat-list preview must decrypt the sealed body")
        }

        // 4. A different wrap key recovers nothing — not the cleartext, not a
        //    partial. The body decodes to nil rather than leaking.
        do {
            let store = try MessageStore(path: path, wrapKey: SymmetricKey(size: .bits256))
            let msg = try XCTUnwrap(store.message(serverId: "srv-enc-1"))
            XCTAssertNil(msg.plaintext, "a different wrap key must not decrypt the body")
        }
    }
}
