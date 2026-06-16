package control_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/auth"
	"github.com/seb0ch/nesttalk/server/internal/control"
	"github.com/seb0ch/nesttalk/server/internal/storage"
)

// osMkdirTempShort returns a short-path temp dir suitable for unix sockets
// on macOS (sun_path ~104 chars; t.TempDir on Darwin can blow that limit).
func osMkdirTempShort(t *testing.T) (string, error) {
	t.Helper()
	dir, err := os.MkdirTemp("", "ctl-")
	if err != nil {
		return "", err
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir, nil
}

func contextWithCancel() (context.Context, context.CancelFunc) {
	return context.WithCancel(context.Background())
}

func dialUnix(path string) (net.Conn, error) {
	deadline := time.Now().Add(2 * time.Second)
	for {
		conn, err := net.Dial("unix", path)
		if err == nil {
			return conn, nil
		}
		if time.Now().After(deadline) {
			return nil, err
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func newServer(t *testing.T) (*control.Server, *storage.DB) {
	t.Helper()
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	srv := control.New(db, auth.New(db))
	return srv, db
}

func dispatchOK(t *testing.T, srv *control.Server, cmd string, args any, cmdID string) control.Response {
	t.Helper()
	body, err := json.Marshal(args)
	require.NoError(t, err)
	resp := srv.Dispatch(context.Background(), control.Request{
		ID:    1,
		CmdID: cmdID,
		Cmd:   cmd,
		Args:  body,
	})
	return resp
}

func TestEnrollUser_CreatesLink(t *testing.T) {
	srv, db := newServer(t)
	resp := dispatchOK(t, srv, "enroll_user", map[string]string{"name": "alice"}, "cmd-1")
	require.True(t, resp.OK, "expected ok, got %s", resp.Error)

	var out struct {
		Code      string `json:"code"`
		ExpiresAt int64  `json:"expires_at"`
	}
	require.NoError(t, json.Unmarshal(resp.Result, &out))
	assert.NotEmpty(t, out.Code)

	var name string
	require.NoError(t, db.QueryRow(`SELECT created_for_name FROM enrollment_links WHERE code = ?`, out.Code).Scan(&name))
	assert.Equal(t, "alice", name)
}

func TestDispatch_CmdIdReplayReturnsCachedResponse(t *testing.T) {
	srv, _ := newServer(t)
	first := dispatchOK(t, srv, "enroll_user", map[string]string{"name": "alice"}, "shared-cmd")
	require.True(t, first.OK)
	second := dispatchOK(t, srv, "enroll_user", map[string]string{"name": "different-name"}, "shared-cmd")
	require.True(t, second.OK)
	assert.JSONEq(t, string(first.Result), string(second.Result),
		"replay must return cached body, NOT issue a second link")
}

func TestDispatch_RequiresCmdID(t *testing.T) {
	srv, _ := newServer(t)
	resp := srv.Dispatch(context.Background(), control.Request{
		ID:  1,
		Cmd: "enroll_user",
	})
	assert.False(t, resp.OK)
}

func TestEnrollExistingUser_RejectsRevokedTarget(t *testing.T) {
	srv, db := newServer(t)
	now := db.Clock.NowMillis()
	_, err := db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at, revoked_at) VALUES (?, ?, ?, ?, ?)`,
		"u-rev", "ghost", 0, now, now)
	require.NoError(t, err)

	resp := dispatchOK(t, srv, "enroll_existing_user", map[string]string{"user_id": "u-rev"}, "cmd-2")
	assert.False(t, resp.OK)
}

func TestRevokeUser_MarksUserAndDevice(t *testing.T) {
	srv, db := newServer(t)
	now := db.Clock.NowMillis()
	_, err := db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
		"u1", "alice", 0, now)
	require.NoError(t, err)
	mpub := make([]byte, 32+1184)
	_, err = db.Exec(`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES (?, ?, ?, ?, ?)`,
		"d1", "u1", []byte("12345678901234567890123456789012"), mpub, now)
	require.NoError(t, err)

	resp := dispatchOK(t, srv, "revoke_user", map[string]string{"user_id": "u1"}, "cmd-3")
	require.True(t, resp.OK, resp.Error)

	var revokedUser, revokedDevice int64
	require.NoError(t, db.QueryRow(`SELECT IFNULL(revoked_at,0) FROM users WHERE id = 'u1'`).Scan(&revokedUser))
	require.NoError(t, db.QueryRow(`SELECT IFNULL(revoked_at,0) FROM devices WHERE id = 'd1'`).Scan(&revokedDevice))
	assert.NotZero(t, revokedUser)
	assert.NotZero(t, revokedDevice)
}

func TestListEnrollmentLinks_OmitsConsumedByDefault(t *testing.T) {
	srv, db := newServer(t)
	now := db.Clock.NowMillis()
	_, err := db.Exec(`INSERT INTO enrollment_links (code, created_for_name, created_at, expires_at) VALUES (?, ?, ?, ?)`,
		"open-1", "alice", now, now+3600_000)
	require.NoError(t, err)
	mpub := make([]byte, 32+1184)
	_, err = db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
		"u1", "bob", 0, now)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES (?, ?, ?, ?, ?)`,
		"d1", "u1", []byte("12345678901234567890123456789012"), mpub, now)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO enrollment_links (code, created_for_name, created_at, expires_at, used_by_device_id) VALUES (?, ?, ?, ?, ?)`,
		"used-1", "bob", now, now+3600_000, "d1")
	require.NoError(t, err)

	resp := dispatchOK(t, srv, "list_enrollment_links", map[string]any{}, "cmd-4")
	require.True(t, resp.OK)
	var out struct {
		Links []map[string]any `json:"enrollment_links"`
	}
	require.NoError(t, json.Unmarshal(resp.Result, &out))
	assert.Len(t, out.Links, 1)
	assert.Equal(t, "open-1", out.Links[0]["code"])

	resp2 := dispatchOK(t, srv, "list_enrollment_links", map[string]any{"include_used": true}, "cmd-5")
	require.True(t, resp2.OK)
	var out2 struct {
		Links []map[string]any `json:"enrollment_links"`
	}
	require.NoError(t, json.Unmarshal(resp2.Result, &out2))
	assert.Len(t, out2.Links, 2)
}

func TestControlSocket_RoundTripsOverUnixSocket(t *testing.T) {
	srv, _ := newServer(t)

	// macOS sun_path is ~104 bytes; t.TempDir() can blow that limit.
	// Use os.MkdirTemp("", ...) which gives a short /var/folders path.
	tmp, err := osMkdirTempShort(t)
	require.NoError(t, err)
	sockPath := tmp + "/ctl.sock"
	require.NoError(t, srv.Listen(sockPath))
	defer srv.Close()

	ctx, cancel := contextWithCancel()
	defer cancel()
	go func() { _ = srv.ServeAccept(ctx) }()

	conn, err := dialUnix(sockPath)
	require.NoError(t, err)
	defer conn.Close()

	req := control.Request{ID: 1, CmdID: "wire-1", Cmd: "list_users"}
	body, _ := json.Marshal(req)
	_, err = conn.Write(append(body, '\n'))
	require.NoError(t, err)

	respBuf := make([]byte, 4096)
	n, err := conn.Read(respBuf)
	require.NoError(t, err)
	var resp control.Response
	require.NoError(t, json.Unmarshal(respBuf[:n], &resp))
	assert.True(t, resp.OK, resp.Error)
}

func TestReplayCache_BoundsSize(t *testing.T) {
	srv, _ := newServer(t)
	// Issue 8500 successful enroll_user commands with distinct cmd_ids.
	// Cap is 8192; cache must never exceed that.
	for i := 0; i < 8500; i++ {
		resp := dispatchOK(t, srv,
			"enroll_user",
			map[string]string{"name": "user-" + uuidName(i)},
			"bound-cmd-"+uuidName(i),
		)
		require.True(t, resp.OK, resp.Error)
	}
	assert.LessOrEqual(t, srv.CacheSize(), 8192,
		"replay cache size must respect the bounded cap even when nothing has expired")
}

func TestDispatch_DoesNotCacheFailedResponses(t *testing.T) {
	srv, db := newServer(t)

	// First call: revoke a user that doesn't exist -> failure.
	first := dispatchOK(t, srv, "revoke_user", map[string]string{"user_id": "u-late"}, "fail-cmd-2")
	require.False(t, first.OK, "revoke of nonexistent user should fail")

	// Now create the user. If failed responses were cached, the next call
	// with the same cmd_id would replay the error instead of re-executing
	// against the now-present row.
	now := db.Clock.NowMillis()
	_, err := db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
		"u-late", "alice", 0, now)
	require.NoError(t, err)

	retry := dispatchOK(t, srv, "revoke_user", map[string]string{"user_id": "u-late"}, "fail-cmd-2")
	assert.True(t, retry.OK, "second call with same cmd_id must re-execute (failed responses are not cached)")
}

func uuidName(i int) string {
	return strconv.Itoa(i)
}

func TestReloadConfig_CallsHook(t *testing.T) {
	srv, _ := newServer(t)
	called := false
	srv.Reload = func() error { called = true; return nil }
	resp := dispatchOK(t, srv, "reload_config", map[string]any{}, "cmd-6")
	require.True(t, resp.OK)
	assert.True(t, called)
}

// fakeBackupRunner records calls so we can assert dispatch-routing.
type fakeBackupRunner struct {
	backupCalled  string
	backupErr     error
	restoreCalled string
	restoreErr    error
	gen           int64
	kid           string
	broadcast     int
	vacuumCalled  bool
	vacuumErr     error
}

func (f *fakeBackupRunner) BackupTo(ctx context.Context, dest string) error {
	f.backupCalled = dest
	return f.backupErr
}

func (f *fakeBackupRunner) RestoreFrom(ctx context.Context, src string) (int64, string, int, error) {
	f.restoreCalled = src
	if f.restoreErr != nil {
		return 0, "", 0, f.restoreErr
	}
	return f.gen, f.kid, f.broadcast, nil
}

func (f *fakeBackupRunner) Vacuum(ctx context.Context) error {
	f.vacuumCalled = true
	return f.vacuumErr
}

func TestBackupTo_DispatchesToRunner(t *testing.T) {
	srv, _ := newServer(t)
	runner := &fakeBackupRunner{}
	srv.Backup = runner

	resp := dispatchOK(t, srv, "backup_to", map[string]string{"path": "/var/backup/snap.db"}, "cmd-bk-1")
	require.True(t, resp.OK, resp.Error)
	assert.Equal(t, "/var/backup/snap.db", runner.backupCalled)
}

func TestBackupTo_RequiresPath(t *testing.T) {
	srv, _ := newServer(t)
	srv.Backup = &fakeBackupRunner{}
	resp := dispatchOK(t, srv, "backup_to", map[string]string{}, "cmd-bk-2")
	assert.False(t, resp.OK)
}

func TestBackupTo_FailsWhenRunnerMissing(t *testing.T) {
	srv, _ := newServer(t)
	resp := dispatchOK(t, srv, "backup_to", map[string]string{"path": "/x"}, "cmd-bk-3")
	assert.False(t, resp.OK)
	assert.Contains(t, resp.Error, "not configured")
}

func TestRestoreFrom_DispatchesAndReturnsRotation(t *testing.T) {
	srv, _ := newServer(t)
	runner := &fakeBackupRunner{
		gen:       42,
		kid:       "kid-rotated",
		broadcast: 3,
	}
	srv.Backup = runner

	resp := dispatchOK(t, srv, "restore_from", map[string]string{"path": "/var/backup/snap.db"}, "cmd-rs-1")
	require.True(t, resp.OK, resp.Error)
	assert.Equal(t, "/var/backup/snap.db", runner.restoreCalled)

	var out struct {
		Generation     int64  `json:"generation"`
		JWTKid         string `json:"jwt_kid"`
		BroadcastCount int    `json:"broadcast_count"`
	}
	require.NoError(t, json.Unmarshal(resp.Result, &out))
	assert.Equal(t, int64(42), out.Generation)
	assert.Equal(t, "kid-rotated", out.JWTKid)
	assert.Equal(t, 3, out.BroadcastCount)
}

func TestRestoreFrom_RequiresPath(t *testing.T) {
	srv, _ := newServer(t)
	srv.Backup = &fakeBackupRunner{}
	resp := dispatchOK(t, srv, "restore_from", map[string]string{}, "cmd-rs-2")
	assert.False(t, resp.OK)
}

func TestVacuum_DispatchesToRunner(t *testing.T) {
	srv, _ := newServer(t)
	runner := &fakeBackupRunner{}
	srv.Backup = runner

	resp := dispatchOK(t, srv, "vacuum", map[string]any{}, "cmd-vac-1")
	require.True(t, resp.OK, resp.Error)
	assert.True(t, runner.vacuumCalled, "expected Vacuum to be called on backup runner")

	var out struct {
		VacuumedAt int64 `json:"vacuumed_at"`
	}
	require.NoError(t, json.Unmarshal(resp.Result, &out))
	assert.NotZero(t, out.VacuumedAt)
}

func TestVacuum_FailsWhenRunnerMissing(t *testing.T) {
	srv, _ := newServer(t)
	// Backup not wired — should return an error.
	resp := dispatchOK(t, srv, "vacuum", map[string]any{}, "cmd-vac-2")
	assert.False(t, resp.OK)
	assert.Contains(t, resp.Error, "not configured")
}

func TestVacuum_PropagatesRunnerError(t *testing.T) {
	srv, _ := newServer(t)
	runner := &fakeBackupRunner{vacuumErr: fmt.Errorf("disk full")}
	srv.Backup = runner

	resp := dispatchOK(t, srv, "vacuum", map[string]any{}, "cmd-vac-3")
	assert.False(t, resp.OK)
	assert.Contains(t, resp.Error, "disk full")
}

// fakeSessionCloser records DisconnectUser/Device calls for revoke tests.
type fakeSessionCloser struct {
	users   []string
	devices []string
}

func (f *fakeSessionCloser) DisconnectUser(userID string) int   { f.users = append(f.users, userID); return 1 }
func (f *fakeSessionCloser) DisconnectDevice(devID string) int  { f.devices = append(f.devices, devID); return 1 }

func TestRevokeUser_DisconnectsLiveSession(t *testing.T) {
	srv, db := newServer(t)
	closer := &fakeSessionCloser{}
	srv.Sessions = closer
	now := db.Clock.NowMillis()
	_, err := db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES ('u-x','U',0,?)`, now)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES ('d-x','u-x',randomblob(32),randomblob(1216),?)`, now)
	require.NoError(t, err)

	resp := dispatchOK(t, srv, "revoke_user", map[string]string{"user_id": "u-x"}, "rev-1")
	require.True(t, resp.OK)
	assert.Equal(t, []string{"u-x"}, closer.users, "revoke_user must disconnect the live session")
}

func TestRevokeDevice_DisconnectsLiveSession(t *testing.T) {
	srv, db := newServer(t)
	closer := &fakeSessionCloser{}
	srv.Sessions = closer
	now := db.Clock.NowMillis()
	_, err := db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES ('u-y','U',0,?)`, now)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES ('d-y','u-y',randomblob(32),randomblob(1216),?)`, now)
	require.NoError(t, err)

	resp := dispatchOK(t, srv, "revoke_device", map[string]string{"device_id": "d-y"}, "rev-d-1")
	require.True(t, resp.OK)
	assert.Equal(t, []string{"d-y"}, closer.devices)
}
