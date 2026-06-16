package control_test

import (
	"encoding/hex"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/calls"
	"github.com/seb0ch/nesttalk/server/internal/control"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

func TestListUsers(t *testing.T) {
	srv, db := newServer(t)
	// A user row is created on enroll *completion*; insert one directly so
	// list_users has something to serialize (revoked + last_seen columns set
	// so both NullInt64 branches run).
	lastSeen := int64(1_700_000_005_000)
	_, err := db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at, revoked_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)`,
		"u-1", "alice", 3, 1_700_000_000_000, 1_700_000_009_000, lastSeen)
	require.NoError(t, err)

	resp := dispatchOK(t, srv, "list_users", map[string]any{}, "c2")
	require.True(t, resp.OK, resp.Error)
	var out struct {
		Users []map[string]any `json:"users"`
	}
	require.NoError(t, json.Unmarshal(resp.Result, &out))
	assert.NotEmpty(t, out.Users)
}

func TestListEnrollmentLinks(t *testing.T) {
	srv, _ := newServer(t)
	require.True(t, dispatchOK(t, srv, "enroll_user", map[string]string{"name": "alice"}, "c1").OK)

	resp := dispatchOK(t, srv, "list_enrollment_links", map[string]any{"include_used": false}, "c2")
	require.True(t, resp.OK, resp.Error)
	var out struct {
		Links []map[string]any `json:"enrollment_links"`
	}
	require.NoError(t, json.Unmarshal(resp.Result, &out))
	assert.NotEmpty(t, out.Links)

	// include_used=true takes the no-WHERE query branch.
	assert.True(t, dispatchOK(t, srv, "list_enrollment_links", map[string]any{"include_used": true}, "c3").OK)
}

func TestReloadConfig_NoReloader(t *testing.T) {
	srv, _ := newServer(t)
	// No Reload hook wired → the handler is a successful no-op.
	assert.True(t, dispatchOK(t, srv, "reload_config", map[string]any{}, "c1").OK)
}

func TestReconcileDevice(t *testing.T) {
	srv, db := newServer(t)
	pubkey := []byte{0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04}
	_, err := db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
		"u-1", "alice", 0, 1_700_000_000_000)
	require.NoError(t, err)
	_, err = db.Exec(`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES (?, ?, ?, ?, ?)`,
		"d-1", "u-1", pubkey, []byte("msgkey"), 1_700_000_000_000)
	require.NoError(t, err)

	// Happy path: pubkey matches.
	resp := dispatchOK(t, srv, "reconcile_device", map[string]string{"pubkey_hex": hex.EncodeToString(pubkey)}, "c1")
	require.True(t, resp.OK, resp.Error)
	var out map[string]any
	require.NoError(t, json.Unmarshal(resp.Result, &out))
	assert.Equal(t, "d-1", out["device_id"])
	assert.Equal(t, "u-1", out["user_id"])

	// Missing pubkey → error.
	assert.False(t, dispatchOK(t, srv, "reconcile_device", map[string]string{}, "c2").OK)
	// Non-hex → error.
	assert.False(t, dispatchOK(t, srv, "reconcile_device", map[string]string{"pubkey_hex": "zzzz"}, "c3").OK)
	// Unknown pubkey → error.
	assert.False(t, dispatchOK(t, srv, "reconcile_device", map[string]string{"pubkey_hex": "00112233"}, "c4").OK)
}

func TestListRecentCalls(t *testing.T) {
	srv, db := newServer(t)

	// Not configured → error.
	assert.False(t, dispatchOK(t, srv, "list_recent_calls", map[string]any{}, "c1").OK)

	// Configured → ok, empty list.
	srv.Calls = control.CallsLister(calls.New(db, ws.NewHub()))
	resp := dispatchOK(t, srv, "list_recent_calls", map[string]any{"limit": 10}, "c2")
	require.True(t, resp.OK, resp.Error)
	var out struct {
		Calls []map[string]any `json:"calls"`
	}
	require.NoError(t, json.Unmarshal(resp.Result, &out))
	assert.Empty(t, out.Calls)
}
