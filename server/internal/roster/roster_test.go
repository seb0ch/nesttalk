package roster_test

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/roster"
	"github.com/seb0ch/nesttalk/server/internal/storage"
)

func newDB(t *testing.T) *storage.DB {
	t.Helper()
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func insertUser(t *testing.T, db *storage.DB, id, name string, color int, revokedAt *int64) {
	t.Helper()
	if revokedAt == nil {
		_, err := db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
			id, name, color, db.Clock.NowMillis())
		require.NoError(t, err)
		return
	}
	_, err := db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at, revoked_at) VALUES (?, ?, ?, ?, ?)`,
		id, name, color, db.Clock.NowMillis(), *revokedAt)
	require.NoError(t, err)
}

func TestRoster_ListsAllEnrolledNonRevokedExceptSelf(t *testing.T) {
	db := newDB(t)
	insertUser(t, db, "u-self", "self", 0, nil)
	insertUser(t, db, "u-alice", "alice", 1, nil)
	insertUser(t, db, "u-bob", "bob", 2, nil)
	revoked := db.Clock.NowMillis()
	insertUser(t, db, "u-charlie", "charlie", 3, &revoked)

	svc := roster.New(db)
	out, err := svc.List(context.Background(), "u-self")
	require.NoError(t, err)

	require.Len(t, out, 2)
	assert.Equal(t, "u-alice", out[0].UserID)
	assert.Equal(t, "alice", out[0].DisplayName)
	assert.Equal(t, "u-bob", out[1].UserID)
}

func TestRoster_OmitsSelf(t *testing.T) {
	db := newDB(t)
	insertUser(t, db, "u-self", "self", 0, nil)
	svc := roster.New(db)
	out, err := svc.List(context.Background(), "u-self")
	require.NoError(t, err)
	assert.Empty(t, out)
}

func TestRoster_AdminListingHasNoSelfFilter(t *testing.T) {
	db := newDB(t)
	insertUser(t, db, "u-alice", "alice", 1, nil)
	insertUser(t, db, "u-bob", "bob", 2, nil)
	svc := roster.New(db)
	out, err := svc.List(context.Background(), "")
	require.NoError(t, err)
	assert.Len(t, out, 2)
}
