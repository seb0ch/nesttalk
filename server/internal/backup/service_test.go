package backup_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/backup"
	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

func openTestDB(t *testing.T, path string) *storage.DB {
	t.Helper()
	db, err := storage.OpenWithClock(path, &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	return db
}

func TestBackupTo_CreatesValidSqliteCopy(t *testing.T) {
	dir := t.TempDir()
	livePath := filepath.Join(dir, "live.db")
	db := openTestDB(t, livePath)
	t.Cleanup(func() { _ = db.Close() })

	// Insert a row that the backup must contain.
	_, err := db.Exec(
		`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
		"u-backup", "alice", 0, db.Clock.NowMillis(),
	)
	require.NoError(t, err)

	svc := backup.NewWithBroadcastGrace(0)
	dest := filepath.Join(dir, "snap.db")
	require.NoError(t, svc.BackupTo(context.Background(), db, dest))

	info, err := os.Stat(dest)
	require.NoError(t, err)
	assert.Greater(t, info.Size(), int64(0))

	// Re-open the snapshot and verify the row is present.
	snap := openTestDB(t, dest)
	t.Cleanup(func() { _ = snap.Close() })
	var name string
	require.NoError(t, snap.QueryRow(`SELECT display_name FROM users WHERE id = 'u-backup'`).Scan(&name))
	assert.Equal(t, "alice", name)

	// Live DB is still usable.
	_, err = db.Exec(
		`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
		"u-after", "bob", 0, db.Clock.NowMillis(),
	)
	require.NoError(t, err, "BackupTo must not lock the live DB")
}

func TestBackupTo_RefusesExistingDestination(t *testing.T) {
	dir := t.TempDir()
	db := openTestDB(t, filepath.Join(dir, "live.db"))
	t.Cleanup(func() { _ = db.Close() })

	dest := filepath.Join(dir, "exists.db")
	require.NoError(t, os.WriteFile(dest, []byte("placeholder"), 0o600))

	svc := backup.NewWithBroadcastGrace(0)
	err := svc.BackupTo(context.Background(), db, dest)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "already exists")
}

func TestBackupTo_RejectsEmptyPath(t *testing.T) {
	dir := t.TempDir()
	db := openTestDB(t, filepath.Join(dir, "live.db"))
	t.Cleanup(func() { _ = db.Close() })

	svc := backup.NewWithBroadcastGrace(0)
	err := svc.BackupTo(context.Background(), db, "")
	require.Error(t, err)
}

func TestRestoreFrom_BumpsGenerationAndRotatesKid(t *testing.T) {
	dir := t.TempDir()
	livePath := filepath.Join(dir, "live.db")

	live := openTestDB(t, livePath)

	// Capture the genesis generation + kid.
	var gen0 int64
	var kid0 string
	require.NoError(t, live.QueryRow(
		`SELECT generation, jwt_kid FROM server_runtime_state WHERE singleton = 1`,
	).Scan(&gen0, &kid0))

	// Take a snapshot of the (genesis) DB to use as the restore source.
	srcPath := filepath.Join(dir, "snap.db")
	require.NoError(t, backup.New().BackupTo(context.Background(), live, srcPath))

	// Mutate the live DB AFTER the snapshot so we can prove restore was destructive.
	_, err := live.Exec(
		`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
		"u-after-snap", "should-be-erased", 0, live.Clock.NowMillis(),
	)
	require.NoError(t, err)

	// Reopener: closes the old handle and opens the path fresh.
	reopen := backup.ReopenerFunc(func(ctx context.Context) (*storage.DB, error) {
		return openTestDB(t, livePath), nil
	})

	hub := ws.NewHub()

	svc := backup.NewWithBroadcastGrace(0)
	fresh, result, err := svc.RestoreFrom(
		context.Background(), live, livePath, srcPath, reopen, hub,
	)
	require.NoError(t, err)
	require.NotNil(t, fresh)
	t.Cleanup(func() { _ = fresh.Close() })

	// Generation must strictly increase.
	assert.Greater(t, result.Generation, gen0)
	// kid must rotate.
	assert.NotEqual(t, kid0, result.JWTKid)

	// Verify rotation was actually persisted.
	var newGen int64
	var newKid string
	require.NoError(t, fresh.QueryRow(
		`SELECT generation, jwt_kid FROM server_runtime_state WHERE singleton = 1`,
	).Scan(&newGen, &newKid))
	assert.Equal(t, result.Generation, newGen)
	assert.Equal(t, result.JWTKid, newKid)

	// Destructive: the post-snapshot insert must be gone.
	var count int
	require.NoError(t, fresh.QueryRow(
		`SELECT COUNT(*) FROM users WHERE id = 'u-after-snap'`,
	).Scan(&count))
	assert.Equal(t, 0, count)

	// jwt_signing_key must also rotate.
	var key []byte
	require.NoError(t, fresh.QueryRow(
		`SELECT jwt_signing_key FROM server_runtime_state WHERE singleton = 1`,
	).Scan(&key))
	assert.Len(t, key, backup.JWTSigningKeyLen)
}

func TestRestoreFrom_RejectsBadSources(t *testing.T) {
	dir := t.TempDir()
	livePath := filepath.Join(dir, "live.db")
	live := openTestDB(t, livePath)
	t.Cleanup(func() { _ = live.Close() })

	reopen := backup.ReopenerFunc(func(ctx context.Context) (*storage.DB, error) {
		return openTestDB(t, livePath), nil
	})

	svc := backup.NewWithBroadcastGrace(0)

	// Missing file.
	_, _, err := svc.RestoreFrom(context.Background(), live, livePath,
		filepath.Join(dir, "nope.db"), reopen, nil)
	require.Error(t, err)

	// Existing but not a SQLite file.
	notSqlite := filepath.Join(dir, "garbage.db")
	require.NoError(t, os.WriteFile(notSqlite, []byte("hello world not a database"), 0o600))
	_, _, err = svc.RestoreFrom(context.Background(), live, livePath, notSqlite, reopen, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not an SQLite database")
}

func TestRestoreFrom_BroadcastsServerRestoredAndClosesSessions(t *testing.T) {
	dir := t.TempDir()
	livePath := filepath.Join(dir, "live.db")
	live := openTestDB(t, livePath)

	// Snapshot first.
	srcPath := filepath.Join(dir, "snap.db")
	require.NoError(t, backup.New().BackupTo(context.Background(), live, srcPath))

	// Two connected sessions.
	hub := ws.NewHub()
	sessA := &ws.Session{
		UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 4),
	}
	sessB := &ws.Session{
		UserID: "u2", DeviceID: "d2", Out: make(chan []byte, 4),
	}
	hub.Register(sessA)
	hub.Register(sessB)
	require.Equal(t, 2, hub.SessionCount())

	reopen := backup.ReopenerFunc(func(ctx context.Context) (*storage.DB, error) {
		return openTestDB(t, livePath), nil
	})

	svc := backup.NewWithBroadcastGrace(0)
	fresh, result, err := svc.RestoreFrom(
		context.Background(), live, livePath, srcPath, reopen, hub,
	)
	require.NoError(t, err)
	t.Cleanup(func() { _ = fresh.Close() })

	assert.Equal(t, 2, result.BroadcastCount, "must broadcast to every connected session")

	// Both sessions received the event before being closed.
	gotA := <-sessA.Out
	gotB := <-sessB.Out
	assert.Contains(t, string(gotA), `"server_restored"`)
	assert.Contains(t, string(gotB), `"server_restored"`)
	assert.Contains(t, string(gotA), `"jwt_kid"`)

	// Hub must drop the sessions.
	assert.Equal(t, 0, hub.SessionCount(),
		"sessions must be unregistered after restore")
	assert.True(t, sessA.IsClosed(), "session A must be closed")
	assert.True(t, sessB.IsClosed(), "session B must be closed")
}
