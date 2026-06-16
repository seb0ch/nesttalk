package storage_test

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/storage"
)

func openTxTestDB(t *testing.T) *storage.DB {
	t.Helper()
	db, err := storage.OpenWithClock(filepath.Join(t.TempDir(), "tx.db"), &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func TestTxQueryWrappers_Normal(t *testing.T) {
	db := openTxTestDB(t)
	err := db.WriteTx(context.Background(), func(tx *storage.Tx) error {
		_, e := tx.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
			"u-1", "alice", 0, 1)
		require.NoError(t, e)

		// QueryRow wrapper.
		var name string
		require.NoError(t, tx.QueryRow(`SELECT display_name FROM users WHERE id = ?`, "u-1").Scan(&name))
		assert.Equal(t, "alice", name)

		// Query wrapper.
		rows, e := tx.Query(`SELECT id FROM users`)
		require.NoError(t, e)
		defer rows.Close()
		count := 0
		for rows.Next() {
			count++
		}
		assert.Equal(t, 1, count)

		// CurrentSynchronous → decodeSync; WriteTx uses NORMAL.
		sync, e := tx.CurrentSynchronous()
		require.NoError(t, e)
		assert.Equal(t, "NORMAL", sync)
		return nil
	})
	require.NoError(t, err)
}

func TestWriteTx_RollsBackOnError(t *testing.T) {
	db := openTxTestDB(t)
	sentinel := assert.AnError

	// A fn that inserts then returns an error must roll the insert back.
	err := db.WriteTx(context.Background(), func(tx *storage.Tx) error {
		_, e := tx.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
			"rollback-me", "x", 0, 1)
		require.NoError(t, e)
		return sentinel
	})
	require.ErrorIs(t, err, sentinel)

	// The row must not survive the rollback.
	var n int
	require.NoError(t, db.QueryRowContext(context.Background(),
		`SELECT COUNT(*) FROM users WHERE id = ?`, "rollback-me").Scan(&n))
	assert.Equal(t, 0, n)
}

func TestTxCurrentSynchronous_Durable(t *testing.T) {
	db := openTxTestDB(t)
	err := db.WriteTxDurable(context.Background(), func(tx *storage.Tx) error {
		sync, e := tx.CurrentSynchronous()
		require.NoError(t, e)
		assert.Equal(t, "FULL", sync)
		return nil
	})
	require.NoError(t, err)
}
