package keys_test

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/keys"
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

func seedUserWithTwoDevices(t *testing.T, db *storage.DB) string {
	t.Helper()
	userID := "u1"
	_, err := db.Exec(`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
		userID, "alice", 0, db.Clock.NowMillis())
	require.NoError(t, err)

	mpub := make([]byte, 32+1184)
	pubA := []byte("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	pubB := []byte("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

	// Revoked first device.
	_, err = db.Exec(`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at, revoked_at)
		VALUES (?, ?, ?, ?, ?, ?)`, "d-old", userID, pubA, mpub, db.Clock.NowMillis()-100, db.Clock.NowMillis()-50)
	require.NoError(t, err)

	// Active second device.
	_, err = db.Exec(`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at)
		VALUES (?, ?, ?, ?, ?)`, "d-new", userID, pubB, mpub, db.Clock.NowMillis())
	require.NoError(t, err)
	return userID
}

func TestMessageKeys_ReturnsActiveAndHistorical(t *testing.T) {
	db := newDB(t)
	userID := seedUserWithTwoDevices(t, db)
	svc := keys.New(db)

	out, err := svc.MessageKeys(context.Background(), userID)
	require.NoError(t, err)
	require.Len(t, out, 2)

	// Active first.
	assert.Equal(t, "d-new", out[0].DeviceID)
	assert.Nil(t, out[0].RevokedAt)
	// Historical second.
	assert.Equal(t, "d-old", out[1].DeviceID)
	require.NotNil(t, out[1].RevokedAt)
}

func TestMessageKeys_UnknownUserReturnsError(t *testing.T) {
	db := newDB(t)
	svc := keys.New(db)
	_, err := svc.MessageKeys(context.Background(), "ghost")
	assert.ErrorIs(t, err, keys.ErrUserNotFound)
}
