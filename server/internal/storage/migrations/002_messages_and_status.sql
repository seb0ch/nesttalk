-- v0.2.0 message spool and delivery status tables.
-- See spec section "Message pipeline (Slice 2A)".

CREATE TABLE messages (
  id                TEXT PRIMARY KEY,         -- UUID, sender-generated; matches WS-wrapper id
  sender_user_id    TEXT NOT NULL REFERENCES users(id),
  recipient_user_id TEXT NOT NULL REFERENCES users(id),
  envelope          BLOB NOT NULL,            -- E2EE ciphertext, opaque to server
  reply_to_id       TEXT REFERENCES messages(id) ON DELETE SET NULL,
  sent_at           INTEGER NOT NULL,
  received_at       INTEGER NOT NULL,
  -- delivered_at and read_at are v0.2.0-unused here; delivery state lives
  -- exclusively in message_acks. Present to match spec schema (line 279).
  delivered_at      INTEGER,
  read_at           INTEGER,
  expires_at        INTEGER NOT NULL          -- received_at + 30d
);
CREATE INDEX messages_by_expires_at ON messages(expires_at);
CREATE INDEX messages_by_received_at
  ON messages(recipient_user_id, received_at, id);

CREATE TABLE message_acks (
  message_id        TEXT PRIMARY KEY,
  sender_user_id    TEXT NOT NULL REFERENCES users(id),
  recipient_user_id TEXT NOT NULL REFERENCES users(id),
  delivered_at      INTEGER,
  read_at           INTEGER,
  expired_at        INTEGER
);
