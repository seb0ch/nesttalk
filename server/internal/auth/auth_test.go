package auth_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/auth"
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

func seedNewUserLink(t *testing.T, db *storage.DB, code, name string) {
	t.Helper()
	now := db.Clock.NowMillis()
	_, err := db.Exec(`INSERT INTO enrollment_links (code, created_for_name, created_at, expires_at)
		VALUES (?, ?, ?, ?)`,
		code, name, now, now+auth.EnrollLinkTTL.Milliseconds())
	require.NoError(t, err)
}

func newKeyMaterial(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey, []byte) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	require.NoError(t, err)
	mpub := make([]byte, auth.MessagePubKeyLen)
	_, err = rand.Read(mpub)
	require.NoError(t, err)
	return pub, priv, mpub
}

func TestEnrollStart_FirstCallStoresChallenge(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	seedNewUserLink(t, db, "code-1", "alice")

	res, err := svc.EnrollStart(context.Background(), "code-1")
	require.NoError(t, err)
	assert.Len(t, res.Challenge, 32)
}

func TestEnrollStart_IsIdempotent(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	seedNewUserLink(t, db, "code-1", "alice")
	first, err := svc.EnrollStart(context.Background(), "code-1")
	require.NoError(t, err)
	second, err := svc.EnrollStart(context.Background(), "code-1")
	require.NoError(t, err)
	assert.Equal(t, first.Challenge, second.Challenge, "second tap must return original challenge")
}

func TestEnrollStart_GoneWhenLinkUnknown(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	_, err := svc.EnrollStart(context.Background(), "missing")
	assert.ErrorIs(t, err, auth.ErrLinkGone)
}

func TestEnrollStart_GoneWhenExpired(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	_, err := db.Exec(`INSERT INTO enrollment_links (code, created_for_name, created_at, expires_at)
		VALUES (?, ?, ?, ?)`,
		"old", "alice", db.Clock.NowMillis()-2, db.Clock.NowMillis()-1)
	require.NoError(t, err)

	_, err = svc.EnrollStart(context.Background(), "old")
	assert.ErrorIs(t, err, auth.ErrLinkGone)
}

func TestEnrollComplete_HappyPathCreatesUserAndDevice(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	seedNewUserLink(t, db, "code-1", "alice")

	pub, priv, mpub := newKeyMaterial(t)
	start, err := svc.EnrollStart(context.Background(), "code-1")
	require.NoError(t, err)
	sig := ed25519.Sign(priv, start.Challenge)

	res, err := svc.EnrollComplete(context.Background(), "code-1", pub, mpub, sig)
	require.NoError(t, err)
	assert.NotEmpty(t, res.UserID)
	assert.NotEmpty(t, res.DeviceID)
	assert.Equal(t, "alice", res.DisplayName)

	// Device row visible.
	var devUser string
	require.NoError(t, db.QueryRow(`SELECT user_id FROM devices WHERE id = ?`, res.DeviceID).Scan(&devUser))
	assert.Equal(t, res.UserID, devUser)
	// Link consumed.
	var used string
	require.NoError(t, db.QueryRow(`SELECT used_by_device_id FROM enrollment_links WHERE code = 'code-1'`).Scan(&used))
	assert.Equal(t, res.DeviceID, used)
}

func TestEnrollComplete_BadAttestationFails(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	seedNewUserLink(t, db, "code-1", "alice")

	pub, _, mpub := newKeyMaterial(t)
	_, err := svc.EnrollStart(context.Background(), "code-1")
	require.NoError(t, err)
	garbage := make([]byte, 64)

	_, err = svc.EnrollComplete(context.Background(), "code-1", pub, mpub, garbage)
	assert.ErrorIs(t, err, auth.ErrInvalidAttestation)
}

func TestEnrollComplete_RejectsConsumedLink(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	seedNewUserLink(t, db, "code-1", "alice")

	pub, priv, mpub := newKeyMaterial(t)
	start, err := svc.EnrollStart(context.Background(), "code-1")
	require.NoError(t, err)
	sig := ed25519.Sign(priv, start.Challenge)
	_, err = svc.EnrollComplete(context.Background(), "code-1", pub, mpub, sig)
	require.NoError(t, err)

	pub2, priv2, mpub2 := newKeyMaterial(t)
	sig2 := ed25519.Sign(priv2, start.Challenge)
	_, err = svc.EnrollComplete(context.Background(), "code-1", pub2, mpub2, sig2)
	assert.ErrorIs(t, err, auth.ErrLinkGone)
}

func TestEnrollComplete_ReEnrollmentRevokesPriorDevice(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	seedNewUserLink(t, db, "code-1", "alice")

	pub, priv, mpub := newKeyMaterial(t)
	start, err := svc.EnrollStart(context.Background(), "code-1")
	require.NoError(t, err)
	first, err := svc.EnrollComplete(context.Background(), "code-1", pub, mpub, ed25519.Sign(priv, start.Challenge))
	require.NoError(t, err)

	// Issue a re-enrollment link for the same user_id.
	now := db.Clock.NowMillis()
	_, err = db.Exec(`INSERT INTO enrollment_links (code, created_for_name, target_user_id, created_at, expires_at)
		VALUES (?, ?, ?, ?, ?)`,
		"code-2", "alice", first.UserID, now, now+auth.EnrollLinkTTL.Milliseconds())
	require.NoError(t, err)

	pub2, priv2, mpub2 := newKeyMaterial(t)
	start2, err := svc.EnrollStart(context.Background(), "code-2")
	require.NoError(t, err)
	second, err := svc.EnrollComplete(context.Background(), "code-2", pub2, mpub2, ed25519.Sign(priv2, start2.Challenge))
	require.NoError(t, err)
	assert.Equal(t, first.UserID, second.UserID, "re-enrollment must reuse user_id")
	assert.NotEqual(t, first.DeviceID, second.DeviceID, "re-enrollment must mint a new device_id")

	// Prior device should be revoked.
	var revokedAt int64
	require.NoError(t, db.QueryRow(`SELECT IFNULL(revoked_at, 0) FROM devices WHERE id = ?`, first.DeviceID).Scan(&revokedAt))
	assert.NotZero(t, revokedAt, "prior device must have revoked_at set after re-enrollment")
}

func TestConnectChallengeAndComplete_ReturnsValidJWT(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	seedNewUserLink(t, db, "code-1", "alice")

	pub, priv, mpub := newKeyMaterial(t)
	start, err := svc.EnrollStart(context.Background(), "code-1")
	require.NoError(t, err)
	enroll, err := svc.EnrollComplete(context.Background(), "code-1", pub, mpub, ed25519.Sign(priv, start.Challenge))
	require.NoError(t, err)

	chRes, err := svc.ConnectChallenge(context.Background(), enroll.DeviceID)
	require.NoError(t, err)
	assert.Len(t, chRes.Nonce, 32)

	conn, err := svc.ConnectComplete(context.Background(), enroll.DeviceID, chRes.Nonce, ed25519.Sign(priv, chRes.Nonce))
	require.NoError(t, err)
	assert.NotEmpty(t, conn.SessionToken)
	assert.Equal(t, enroll.UserID, conn.UserID)

	claims, err := svc.ValidateSession(context.Background(), conn.SessionToken)
	require.NoError(t, err)
	assert.Equal(t, enroll.DeviceID, claims.DeviceID)
	assert.Equal(t, enroll.UserID, claims.UserID)
}

func TestConnectComplete_ReplayedNonceIsRejected(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	seedNewUserLink(t, db, "code-1", "alice")

	pub, priv, mpub := newKeyMaterial(t)
	start, err := svc.EnrollStart(context.Background(), "code-1")
	require.NoError(t, err)
	enroll, err := svc.EnrollComplete(context.Background(), "code-1", pub, mpub, ed25519.Sign(priv, start.Challenge))
	require.NoError(t, err)
	chRes, err := svc.ConnectChallenge(context.Background(), enroll.DeviceID)
	require.NoError(t, err)
	_, err = svc.ConnectComplete(context.Background(), enroll.DeviceID, chRes.Nonce, ed25519.Sign(priv, chRes.Nonce))
	require.NoError(t, err)

	// Replay must be rejected.
	_, err = svc.ConnectComplete(context.Background(), enroll.DeviceID, chRes.Nonce, ed25519.Sign(priv, chRes.Nonce))
	assert.ErrorIs(t, err, auth.ErrNonceInvalid)
}

func TestConnectChallenge_UnknownDevice(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	_, err := svc.ConnectChallenge(context.Background(), "nope")
	assert.ErrorIs(t, err, auth.ErrDeviceNotFound)
}

func TestValidateSession_RejectsTamperedToken(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	seedNewUserLink(t, db, "code-1", "alice")
	pub, priv, mpub := newKeyMaterial(t)
	start, _ := svc.EnrollStart(context.Background(), "code-1")
	enroll, _ := svc.EnrollComplete(context.Background(), "code-1", pub, mpub, ed25519.Sign(priv, start.Challenge))
	ch, _ := svc.ConnectChallenge(context.Background(), enroll.DeviceID)
	conn, _ := svc.ConnectComplete(context.Background(), enroll.DeviceID, ch.Nonce, ed25519.Sign(priv, ch.Nonce))

	tampered := conn.SessionToken[:len(conn.SessionToken)-3] + "xyz"
	_, err := svc.ValidateSession(context.Background(), tampered)
	assert.ErrorIs(t, err, auth.ErrSessionExpired)
}

func TestValidateSession_RejectsRevokedDevice(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	seedNewUserLink(t, db, "code-1", "alice")
	pub, priv, mpub := newKeyMaterial(t)
	start, _ := svc.EnrollStart(context.Background(), "code-1")
	enroll, _ := svc.EnrollComplete(context.Background(), "code-1", pub, mpub, ed25519.Sign(priv, start.Challenge))
	ch, _ := svc.ConnectChallenge(context.Background(), enroll.DeviceID)
	conn, _ := svc.ConnectComplete(context.Background(), enroll.DeviceID, ch.Nonce, ed25519.Sign(priv, ch.Nonce))

	// Token is valid right now.
	_, err := svc.ValidateSession(context.Background(), conn.SessionToken)
	require.NoError(t, err)

	// Revoke the device (what re-enrollment does to the prior device).
	// A previously-issued token must stop working immediately.
	_, err = db.Exec(`UPDATE devices SET revoked_at = ? WHERE id = ?`, db.Clock.NowMillis(), enroll.DeviceID)
	require.NoError(t, err)

	_, err = svc.ValidateSession(context.Background(), conn.SessionToken)
	assert.ErrorIs(t, err, auth.ErrSessionExpired, "revoked device's token must be rejected")
}
