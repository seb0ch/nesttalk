package storage_test

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/storage"
)

func newTestDB(t *testing.T) *storage.DB {
	t.Helper()
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func TestMigrations_BaseTablesExist(t *testing.T) {
	db := newTestDB(t)

	expected := []string{
		"users",
		"devices",
		"enrollment_links",
		"auth_nonces",
		"server_runtime_state",
		"server_config",
		"schema_migrations",
		"messages",
		"message_acks",
		"reactions",
		"calls",
	}
	for _, table := range expected {
		var name string
		err := db.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&name)
		require.NoError(t, err, "table %q should exist", table)
		assert.Equal(t, table, name)
	}
}

func TestMigrations_AreIdempotent(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "test.db")

	db1, err := storage.Open(dbPath)
	require.NoError(t, err)
	require.NoError(t, db1.Close())

	db2, err := storage.Open(dbPath)
	require.NoError(t, err)
	defer db2.Close()

	// Count all applied migrations — must equal the number of .sql files
	// in the migrations embed. Idempotency means the count does not grow
	// on re-open; it stays fixed at the number of migration files.
	var count int
	require.NoError(t, db2.QueryRow(`SELECT COUNT(*) FROM schema_migrations`).Scan(&count))
	assert.Equal(t, 5, count, "second open must not re-apply any migration (idempotency check)")
}

func TestMigrations_ServerRuntimeStateSeed(t *testing.T) {
	db := newTestDB(t)

	var (
		generation int64
		kid        string
		key        []byte
	)
	require.NoError(t, db.QueryRow(
		`SELECT generation, jwt_kid, jwt_signing_key FROM server_runtime_state WHERE singleton = 1`,
	).Scan(&generation, &kid, &key))

	assert.Equal(t, int64(1), generation)
	assert.Equal(t, "kid-genesis", kid)
	assert.Len(t, key, 32, "jwt_signing_key must be 32 random bytes (HMAC-SHA256 size)")
}

func TestDevices_OneActivePerUser(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()

	_, err := db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
		"u1", "alice", 0, db.Clock.NowMillis())
	require.NoError(t, err)

	pub := make([]byte, 32)
	mpub := make([]byte, 32+1184)
	for i := range mpub {
		mpub[i] = byte(i & 0xff)
	}

	_, err = db.Exec(`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES (?, ?, ?, ?, ?)`,
		"d1", "u1", pub, mpub, db.Clock.NowMillis())
	require.NoError(t, err)

	// Second non-revoked device for the same user must violate the unique index.
	_, err = db.Exec(`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES (?, ?, ?, ?, ?)`,
		"d2", "u1", pub, mpub, db.Clock.NowMillis())
	require.Error(t, err, "second active device should violate devices_one_active_per_user")

	// After revoking d1, d2 inserts cleanly.
	_, err = db.Exec(`UPDATE devices SET revoked_at = ? WHERE id = ?`, db.Clock.NowMillis(), "d1")
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES (?, ?, ?, ?, ?)`,
		"d2", "u1", pub, mpub, db.Clock.NowMillis())
	require.NoError(t, err)
	_ = ctx
}

func TestWriteTxDurable_RaisesSynchronousFull(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()

	var seen string
	err := db.WriteTxDurable(ctx, func(tx *storage.Tx) error {
		s, err := tx.CurrentSynchronous()
		if err != nil {
			return err
		}
		seen = s
		return nil
	})
	require.NoError(t, err)
	assert.Equal(t, "FULL", seen, "WriteTxDurable must run with PRAGMA synchronous=FULL")
}

func TestWriteTx_DefaultsToNormal(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()

	var seen string
	err := db.WriteTx(ctx, func(tx *storage.Tx) error {
		s, err := tx.CurrentSynchronous()
		if err != nil {
			return err
		}
		seen = s
		return nil
	})
	require.NoError(t, err)
	assert.Equal(t, "NORMAL", seen, "WriteTx must run with PRAGMA synchronous=NORMAL")
}

func TestWriteTx_RollbackOnError(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()

	wantErr := assertedRollbackError("boom")
	err := db.WriteTx(ctx, func(tx *storage.Tx) error {
		_, err := tx.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
			"abort-user", "ghost", 0, db.Clock.NowMillis())
		require.NoError(t, err)
		return wantErr
	})
	assert.ErrorIs(t, err, wantErr)

	var count int
	require.NoError(t, db.QueryRow(`SELECT COUNT(*) FROM users WHERE id = 'abort-user'`).Scan(&count))
	assert.Equal(t, 0, count, "rollback must discard the row")
}

type rollbackError string

func (e rollbackError) Error() string { return string(e) }

func assertedRollbackError(msg string) error { return rollbackError(msg) }

func TestWriteTxDurable_PanicTriggersRollback(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()

	// fn(tx) panics -- ensure the panic propagates AND the next
	// WriteTx succeeds (i.e. no leaked open transaction on the pinned
	// connection).
	assert.PanicsWithValue(t, "boom", func() {
		_ = db.WriteTxDurable(ctx, func(tx *storage.Tx) error {
			panic("boom")
		})
	})

	// If the previous transaction had been left open we'd see
	// "cannot start a transaction within a transaction" here.
	err := db.WriteTx(ctx, func(tx *storage.Tx) error {
		_, err := tx.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
			"after-panic", "alice", 0, db.Clock.NowMillis())
		return err
	})
	require.NoError(t, err, "next writeTx must not see leftover transaction")
}

func TestWriteTxDurable_ResetsSynchronousAfterCommit(t *testing.T) {
	db := newTestDB(t)
	ctx := context.Background()

	// Run a no-op durable write.
	err := db.WriteTxDurable(ctx, func(tx *storage.Tx) error {
		return nil
	})
	require.NoError(t, err)

	// Subsequent reads on the pinned connection must see synchronous=NORMAL.
	var raw string
	require.NoError(t, db.QueryRow("PRAGMA synchronous").Scan(&raw))
	assert.Equal(t, "1", raw, "PRAGMA synchronous should be NORMAL (1) after WriteTxDurable returns")
}

// TestVacuum verifies the storage.Vacuum helper runs successfully against a
// real database and that the file remains a valid SQLite database afterward.
// The caller (daemonBackupRunner) is expected to close the existing handle and
// reopen it; here we mimic that pattern: close, vacuum, reopen.
func TestVacuum_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "vacuum_test.db")

	// Open, populate, close — then vacuum, then reopen.
	db, err := storage.Open(dbPath)
	require.NoError(t, err)

	// Insert a row so there is real data to vacuum.
	_, err = db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
		"u-vac", "Vacuumee", 0, 1_700_000_000_000)
	require.NoError(t, err)
	require.NoError(t, db.Close())

	// VACUUM must succeed on a closed handle (autocommit mode, fresh connection).
	ctx := context.Background()
	require.NoError(t, storage.Vacuum(ctx, dbPath))

	// Reopen must succeed and the row must still be present.
	db2, err := storage.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { _ = db2.Close() })

	var name string
	require.NoError(t, db2.QueryRow(`SELECT display_name FROM users WHERE id = 'u-vac'`).Scan(&name))
	assert.Equal(t, "Vacuumee", name, "data must survive a vacuum+reopen cycle")
}
