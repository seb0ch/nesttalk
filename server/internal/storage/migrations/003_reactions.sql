-- v0.2.0 reaction spool table.
-- See spec section "Reactions and Replies (Slice 3)".
--
-- UPSERT invariant: PRIMARY KEY id is set on first PUT and never updated.
-- Server-generated UUID. UNIQUE(message_id, sender_user_id) enforces one
-- reaction per (parent message, sender) pair; subsequent PUTs overwrite the
-- envelope (emoji change or un-react) while the canonical id stays fixed.
--
-- ON DELETE CASCADE on message_id: when the parent message is purged from the
-- spool, all its reactions are automatically removed. This is safe because
-- reactions are ephemeral state attached to the spool window, not archival
-- history. The FK reference must exist at INSERT time (parent-delivered
-- ordering invariant: the message row is always inserted before its reactions
-- because the PUT /reactions endpoint validates the FK with a pre-check).

CREATE TABLE reactions (
  id                TEXT PRIMARY KEY,
  message_id        TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  sender_user_id    TEXT NOT NULL REFERENCES users(id),
  recipient_user_id TEXT NOT NULL REFERENCES users(id),
  envelope          BLOB NOT NULL,
  sent_at           INTEGER NOT NULL,
  received_at       INTEGER NOT NULL,
  UNIQUE (message_id, sender_user_id)
);
CREATE INDEX reactions_by_received_at ON reactions(recipient_user_id, received_at, id);
