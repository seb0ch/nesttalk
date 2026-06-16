-- v0.2.0 base schema. Single migration, fresh start (no upgrade path from v0.1).
-- See docs/superpowers/specs/2026-04-16-v0.2.0-whatsapp-style-redesign-design.md
-- "Database schema (v0.2.0, fresh start)".

CREATE TABLE users (
  id              TEXT PRIMARY KEY,
  display_name    TEXT NOT NULL,
  color_hint      INTEGER NOT NULL,
  enrolled_at     INTEGER NOT NULL,
  revoked_at      INTEGER,
  last_seen_at    INTEGER
);

CREATE TABLE devices (
  id              TEXT PRIMARY KEY,
  user_id         TEXT NOT NULL REFERENCES users(id),
  public_key      BLOB NOT NULL,
  message_pubkey  BLOB NOT NULL,
  enrolled_at     INTEGER NOT NULL,
  revoked_at      INTEGER
);
CREATE UNIQUE INDEX devices_one_active_per_user
  ON devices(user_id) WHERE revoked_at IS NULL;

CREATE TABLE enrollment_links (
  code              TEXT PRIMARY KEY,
  created_for_name  TEXT NOT NULL,
  target_user_id    TEXT REFERENCES users(id),
  created_at        INTEGER NOT NULL,
  expires_at        INTEGER NOT NULL,
  challenge         BLOB,
  used_by_device_id TEXT REFERENCES devices(id)
);

CREATE TABLE auth_nonces (
  nonce           BLOB PRIMARY KEY,
  device_id       TEXT NOT NULL REFERENCES devices(id),
  issued_at       INTEGER NOT NULL,
  expires_at      INTEGER NOT NULL,
  consumed_at     INTEGER
);
CREATE INDEX auth_nonces_expiry ON auth_nonces(expires_at);

CREATE TABLE server_runtime_state (
  singleton           INTEGER PRIMARY KEY CHECK (singleton = 1),
  generation          INTEGER NOT NULL,
  jwt_kid             TEXT NOT NULL,
  jwt_signing_key     BLOB NOT NULL
);
INSERT INTO server_runtime_state (singleton, generation, jwt_kid, jwt_signing_key)
  VALUES (1, 1, 'kid-genesis', randomblob(32));

-- Server config (carried over from v0.1; key/value table for things like offline_ttl_days).
CREATE TABLE server_config (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL,
  updated_at  INTEGER NOT NULL
);
