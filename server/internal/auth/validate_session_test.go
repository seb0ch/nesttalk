package auth_test

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/auth"
	"github.com/seb0ch/nesttalk/server/internal/storage"
)

// fullSession runs the full enroll+connect flow and returns the issued token
// plus the user id, so revocation/generation branches of ValidateSession can
// be driven from a structurally valid, correctly signed token.
func fullSession(t *testing.T, code string) (*auth.Service, *storage.DB, string, string) {
	t.Helper()
	db := newTestDB(t)
	svc := auth.New(db)
	seedNewUserLink(t, db, code, "alice")
	pub, priv, mpub := newKeyMaterial(t)
	ctx := context.Background()
	start, err := svc.EnrollStart(ctx, code)
	require.NoError(t, err)
	enroll, err := svc.EnrollComplete(ctx, code, pub, mpub, ed25519.Sign(priv, start.Challenge))
	require.NoError(t, err)
	ch, err := svc.ConnectChallenge(ctx, enroll.DeviceID)
	require.NoError(t, err)
	conn, err := svc.ConnectComplete(ctx, enroll.DeviceID, ch.Nonce, ed25519.Sign(priv, ch.Nonce))
	require.NoError(t, err)
	return svc, db, conn.SessionToken, enroll.UserID
}

func TestValidateSession_MalformedTokens(t *testing.T) {
	db := newTestDB(t)
	svc := auth.New(db)
	ctx := context.Background()

	wrongAlg := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","kid":"x"}`)) + ".e30.sig"

	for name, token := range map[string]string{
		"one segment":   "onlyonepart",
		"two segments":  "two.parts",
		"bad b64 header": "!!!.e30.sig",
		"wrong alg":      wrongAlg,
	} {
		t.Run(name, func(t *testing.T) {
			_, err := svc.ValidateSession(ctx, token)
			assert.ErrorIs(t, err, auth.ErrSessionExpired)
		})
	}
}

func TestValidateSession_WrongKid(t *testing.T) {
	svc, db, token, _ := fullSession(t, "code-kid")
	_, err := db.Exec(`UPDATE server_runtime_state SET jwt_kid = 'rotated-kid' WHERE singleton = 1`)
	require.NoError(t, err)
	_, err = svc.ValidateSession(context.Background(), token)
	assert.ErrorIs(t, err, auth.ErrSessionExpired)
}

func TestValidateSession_GenerationMismatch(t *testing.T) {
	svc, db, token, _ := fullSession(t, "code-gen")
	_, err := db.Exec(`UPDATE server_runtime_state SET generation = generation + 1 WHERE singleton = 1`)
	require.NoError(t, err)
	_, err = svc.ValidateSession(context.Background(), token)
	assert.ErrorIs(t, err, auth.ErrSessionExpired)
}

func TestValidateSession_UserRevoked(t *testing.T) {
	svc, db, token, userID := fullSession(t, "code-rev")
	_, err := db.Exec(`UPDATE users SET revoked_at = ? WHERE id = ?`, db.Clock.NowMillis(), userID)
	require.NoError(t, err)
	_, err = svc.ValidateSession(context.Background(), token)
	assert.ErrorIs(t, err, auth.ErrSessionExpired)
}
