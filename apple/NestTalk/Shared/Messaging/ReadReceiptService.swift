import Foundation

/// Marks visible incoming messages as read and pushes the implicit-ack
/// to the server (kind=read). Pauses on background, flushes on
/// foreground. Inbound side: when the server forwards a peer's read /
/// delivered ack, the matching outgoing `messages` row transitions so
/// MessageBubble can render the state.
///
/// **Two id spaces.** Local rows are keyed by a client UUID (`rowId`);
/// the server speaks only its own message id (`serverId`). Local
/// `read_receipts` writes use rowId; every API call and every inbound
/// WS ack uses serverId.
public actor ReadReceiptService {

    private let store: MessageStore
    private let api: APIClient
    private let sessionToken: () -> String?
    private let onAuthFailure: (() async -> Void)?
    private var paused = false

    public init(
        store: MessageStore,
        api: APIClient,
        sessionToken: @escaping () -> String?,
        onAuthFailure: (() async -> Void)? = nil
    ) {
        self.store = store
        self.api = api
        self.sessionToken = sessionToken
        self.onAuthFailure = onAuthFailure
    }

    /// Classification of a read-ack POST so the durable retry can drop dead ids
    /// instead of wedging behind them.
    private enum AckOutcome {
        case acked       // 2xx — confirmed
        case permanent   // 4xx the server will never accept (gone/unauthorized id) — drop it
        case authFailure // 401 — refresh the session and retry later
        case retryable   // 5xx / 429 / transport — stop and retry on the next trigger
    }

    public func setPaused(_ paused: Bool) async {
        self.paused = paused
        // Foreground resume: drain everything the server hasn't confirmed.
        if !paused { await flushPendingReadAcks() }
    }

    /// Mark a message as read locally (by row id, durably `acked = 0`) and
    /// POST `/messages/{serverId}/ack` with kind=read. Rows that never got
    /// a server id (still `sending`) skip the ack. A failed ack — or one
    /// deferred because we're `paused` — stays `acked = 0` in the store and
    /// is retried by `flushPendingReadAcks` on reconnect / foreground /
    /// relaunch, so the peer eventually sees "read".
    public func markRead(rowId: String, serverId: String?, now: Date = Date()) async {
        try? store.markRead(rowId, at: now)
        guard let serverId, !paused else { return }
        switch await postRead(serverId: serverId) {
        case .acked, .permanent:
            // A permanent rejection can never be delivered — mark it acked so
            // it doesn't linger in the durable queue and block later receipts.
            try? store.markReadAcked(serverId: serverId)
        case .authFailure:
            await onAuthFailure?()
        case .retryable:
            break // stays acked=0; flushPendingReadAcks retries it
        }
    }

    /// Retry every read receipt whose server ack never landed (POST
    /// failure, paused-deferred, or surviving a relaunch). Durable: the
    /// pending set is read from `read_receipts.acked = 0`, not in-memory
    /// state, so it survives process death. Called on WS reconnect and on
    /// foreground resume.
    public func flushPendingReadAcks() async {
        guard !paused else { return }
        let pending = (try? store.unackedReadReceipts()) ?? []
        for serverId in pending {
            switch await postRead(serverId: serverId) {
            case .acked, .permanent:
                // Confirmed, or a dead id we drop so it can't wedge the queue
                // and stop unrelated newer receipts from ever flushing.
                try? store.markReadAcked(serverId: serverId)
            case .authFailure:
                await onAuthFailure?()
                return // retry the rest after the session refreshes
            case .retryable:
                return // server unreachable — stop; next trigger retries
            }
        }
    }

    /// Apply a peer-side read receipt arriving over the WS. The event
    /// carries the SERVER id of our outgoing message.
    public func ingestPeerRead(serverId: String) async {
        try? store.updateMessageStateByServerId(serverId, state: "read")
    }

    /// Apply a delivered ack from the WS. Never downgrades a row the
    /// peer has already read.
    public func ingestPeerDelivered(serverId: String) async {
        if let m = try? store.message(serverId: serverId), m.state == "read" { return }
        try? store.updateMessageStateByServerId(serverId, state: "delivered")
    }

    /// Reconcile outgoing delivery receipts that the best-effort WS
    /// broadcast missed (peer acked while we were offline → the event was
    /// never re-sent). Queries the server's authoritative status for every
    /// outgoing row still awaiting a receipt and lifts its local state.
    /// Runs on startup and on every WS reconnect. Never downgrades.
    public func reconcileOutgoingStatuses() async {
        let rows = (try? store.outgoingAwaitingReceipt()) ?? []
        for row in rows {
            guard let serverId = row.server_id else { continue }
            let status: String
            do {
                status = try await api.messageStatus(id: serverId, sessionToken: sessionToken())
            } catch {
                // Transient — next reconnect retries.
                continue
            }
            switch status {
            case "read":
                try? store.updateMessageStateByServerId(serverId, state: "read")
            case "delivered":
                // Never clobber a row the peer has since read. The guard is
                // in SQL (state != 'read'), not on the snapshotted row.state:
                // the actor is re-entrant across the messageStatus await, so
                // a WS read receipt may have advanced this row to "read"
                // while we waited — a snapshot check would downgrade it.
                try? store.markDeliveredIfNotRead(serverId: serverId)
            default:
                // "pending" (not yet delivered), "expired", "gone" — leave
                // the local state untouched.
                break
            }
        }
    }

    private func postRead(serverId: String) async -> AckOutcome {
        do {
            try await api.ackMessage(id: serverId, kind: "read", sessionToken: sessionToken())
            return .acked
        } catch APIClient.SendError.http(let code, _) {
            if code == 401 { return .authFailure }
            // 400/403/404/410 — the server will never accept this id (purged,
            // unauthorized, gone). Drop it so it can't block later receipts.
            if (400..<500).contains(code) { return .permanent }
            return .retryable // 5xx / 429
        } catch {
            return .retryable // transport / unknown
        }
    }

    /// Test introspection — count of read receipts the server hasn't
    /// confirmed (durable, from the store).
    public func _pendingCount() -> Int { (try? store.unackedReadReceipts().count) ?? 0 }
}
