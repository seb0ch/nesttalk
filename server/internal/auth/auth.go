// Package auth implements the v0.2.0 enrollment and connect handshakes
// against the storage layer. See spec sections "Enrollment handshake" and
// "Connect handshake (per session)".
package auth

import (
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/seb0ch/nesttalk/server/internal/storage"
)

// Sentinel errors. The HTTP layer translates these into the spec's
// 400/410/401/403 status codes.
var (
	ErrLinkGone           = errors.New("enrollment link gone")
	ErrInvalidAttestation = errors.New("invalid attestation")
	ErrLinkConsumed       = errors.New("enrollment link already consumed")
	ErrUserRevoked        = errors.New("user revoked")
	ErrNonceInvalid       = errors.New("nonce invalid or replayed")
	ErrDeviceNotFound     = errors.New("device not found")
	ErrSessionExpired     = errors.New("session expired or invalid")
)

const (
	// EnrollLinkTTL is the spec's 1-hour invite TTL.
	EnrollLinkTTL = time.Hour
	// AuthNonceTTL is the spec's 60-second connect-challenge nonce TTL.
	AuthNonceTTL = 60 * time.Second
	// SessionTTL is the spec's 1-hour JWT lifetime.
	SessionTTL = time.Hour

	// Ed25519PubKeyLen is the wire size for an Ed25519 public key.
	Ed25519PubKeyLen = 32
	// MessagePubKeyLen is X25519(32) + ML-KEM-768(1184).
	MessagePubKeyLen = 32 + 1184
)

// Service is the auth service over the storage layer.
type Service struct {
	DB *storage.DB
}

// New constructs a Service.
func New(db *storage.DB) *Service { return &Service{DB: db} }

// EnrollStartResult is returned from EnrollStart.
type EnrollStartResult struct {
	Challenge []byte
}

// EnrollStart implements the spec's BEGIN IMMEDIATE handler for
// /api/v1/auth/enroll/start. Idempotent on transport failure: a second tap
// returns the original challenge unchanged.
func (s *Service) EnrollStart(ctx context.Context, code string) (*EnrollStartResult, error) {
	var (
		challenge      []byte
		expiresAt      int64
		usedByDeviceID sql.NullString
	)

	err := s.DB.WriteTxDurable(ctx, func(tx *storage.Tx) error {
		var existing []byte
		err := tx.QueryRow(
			`SELECT challenge, expires_at, used_by_device_id FROM enrollment_links WHERE code = ?`,
			code,
		).Scan(&existing, &expiresAt, &usedByDeviceID)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrLinkGone
		}
		if err != nil {
			return err
		}
		if usedByDeviceID.Valid {
			return ErrLinkGone
		}
		now := s.DB.Clock.NowMillis()
		if now > expiresAt {
			return ErrLinkGone
		}
		if len(existing) > 0 {
			// Idempotent retry: return the original challenge unchanged.
			challenge = append(challenge, existing...)
			return nil
		}
		// First call: generate, persist under FULL durability.
		ch := make([]byte, 32)
		if _, err := rand.Read(ch); err != nil {
			return err
		}
		if _, err := tx.Exec(
			`UPDATE enrollment_links SET challenge = ? WHERE code = ?`,
			ch, code,
		); err != nil {
			return err
		}
		challenge = ch
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &EnrollStartResult{Challenge: challenge}, nil
}

// EnrollCompleteResult is returned from EnrollComplete.
type EnrollCompleteResult struct {
	UserID      string
	DeviceID    string
	DisplayName string
	ColorHint   int
	// RevokedDeviceIDs are the prior devices this (re-)enroll revoked. The
	// caller closes their live WS sessions synchronously so a replaced
	// device loses access immediately, not at the next revalidation tick.
	RevokedDeviceIDs []string
}

// EnrollComplete is the spec's atomic transaction for /auth/enroll/complete.
func (s *Service) EnrollComplete(
	ctx context.Context,
	code string,
	devicePubkey []byte,
	messagePubkey []byte,
	attestation []byte,
) (*EnrollCompleteResult, error) {
	if len(devicePubkey) != Ed25519PubKeyLen {
		return nil, fmt.Errorf("%w: device pubkey size", ErrInvalidAttestation)
	}
	if len(messagePubkey) != MessagePubKeyLen {
		return nil, fmt.Errorf("%w: message pubkey size", ErrInvalidAttestation)
	}

	var result EnrollCompleteResult
	err := s.DB.WriteTxDurable(ctx, func(tx *storage.Tx) error {
		var (
			challenge      []byte
			expiresAt      int64
			usedByDeviceID sql.NullString
			targetUserID   sql.NullString
			createdForName string
		)
		err := tx.QueryRow(
			`SELECT challenge, expires_at, used_by_device_id, target_user_id, created_for_name
			 FROM enrollment_links WHERE code = ?`,
			code,
		).Scan(&challenge, &expiresAt, &usedByDeviceID, &targetUserID, &createdForName)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrLinkGone
		}
		if err != nil {
			return err
		}
		if usedByDeviceID.Valid {
			return ErrLinkGone
		}
		now := s.DB.Clock.NowMillis()
		if now > expiresAt {
			return ErrLinkGone
		}
		if len(challenge) == 0 {
			return ErrInvalidAttestation
		}
		if !ed25519.Verify(ed25519.PublicKey(devicePubkey), challenge, attestation) {
			return ErrInvalidAttestation
		}

		// Resolve user.
		var (
			resolvedUserID string
			displayName    string
			colorHint      int
		)
		if targetUserID.Valid {
			// Re-enroll: confirm not revoked.
			var revokedAt sql.NullInt64
			err := tx.QueryRow(
				`SELECT display_name, color_hint, revoked_at FROM users WHERE id = ?`,
				targetUserID.String,
			).Scan(&displayName, &colorHint, &revokedAt)
			if errors.Is(err, sql.ErrNoRows) {
				return ErrLinkGone
			}
			if err != nil {
				return err
			}
			if revokedAt.Valid {
				return ErrUserRevoked
			}
			resolvedUserID = targetUserID.String
		} else {
			// New user.
			resolvedUserID = uuid.NewString()
			displayName = createdForName
			colorHint = colorHintFor(resolvedUserID)
			if _, err := tx.Exec(
				`INSERT INTO users (id, display_name, color_hint, enrolled_at)
				 VALUES (?, ?, ?, ?)`,
				resolvedUserID, displayName, colorHint, now,
			); err != nil {
				return err
			}
		}

		// Capture the prior active device(s) BEFORE revoking, so the caller
		// can close their live WS sessions synchronously.
		var priorDeviceIDs []string
		priorRows, err := tx.Query(
			`SELECT id FROM devices WHERE user_id = ? AND revoked_at IS NULL`,
			resolvedUserID,
		)
		if err != nil {
			return err
		}
		for priorRows.Next() {
			var id string
			if err := priorRows.Scan(&id); err != nil {
				priorRows.Close()
				return err
			}
			priorDeviceIDs = append(priorDeviceIDs, id)
		}
		priorRows.Close()
		if err := priorRows.Err(); err != nil {
			return err
		}

		// Revoke prior device for this user, if any.
		if _, err := tx.Exec(
			`UPDATE devices SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL`,
			now, resolvedUserID,
		); err != nil {
			return err
		}

		// Insert new device.
		newDeviceID := uuid.NewString()
		if _, err := tx.Exec(
			`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at)
			 VALUES (?, ?, ?, ?, ?)`,
			newDeviceID, resolvedUserID, devicePubkey, messagePubkey, now,
		); err != nil {
			return err
		}

		// Mark link consumed.
		if _, err := tx.Exec(
			`UPDATE enrollment_links SET used_by_device_id = ? WHERE code = ?`,
			newDeviceID, code,
		); err != nil {
			return err
		}

		result = EnrollCompleteResult{
			UserID:           resolvedUserID,
			DeviceID:         newDeviceID,
			DisplayName:      displayName,
			ColorHint:        colorHint,
			RevokedDeviceIDs: priorDeviceIDs,
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

// colorHintFor derives a stable 0..7 palette index from a user_id.
func colorHintFor(userID string) int {
	h := sha256.Sum256([]byte(userID))
	return int(h[0]) % 8
}

// ConnectChallengeResult is returned from ConnectChallenge.
type ConnectChallengeResult struct {
	Nonce []byte
}

// ConnectChallenge issues a 60-second auth nonce for the device, durable.
func (s *Service) ConnectChallenge(ctx context.Context, deviceID string) (*ConnectChallengeResult, error) {
	var nonce []byte
	err := s.DB.WriteTxDurable(ctx, func(tx *storage.Tx) error {
		var revokedAt sql.NullInt64
		err := tx.QueryRow(
			`SELECT revoked_at FROM devices WHERE id = ?`, deviceID,
		).Scan(&revokedAt)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrDeviceNotFound
		}
		if err != nil {
			return err
		}
		if revokedAt.Valid {
			return ErrDeviceNotFound
		}

		now := s.DB.Clock.NowMillis()
		nonceBytes := make([]byte, 32)
		if _, err := rand.Read(nonceBytes); err != nil {
			return err
		}
		if _, err := tx.Exec(
			`INSERT INTO auth_nonces (nonce, device_id, issued_at, expires_at)
			 VALUES (?, ?, ?, ?)`,
			nonceBytes, deviceID, now, now+AuthNonceTTL.Milliseconds(),
		); err != nil {
			return err
		}
		nonce = nonceBytes
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &ConnectChallengeResult{Nonce: nonce}, nil
}

// ConnectCompleteResult is returned from ConnectComplete.
type ConnectCompleteResult struct {
	SessionToken string
	ExpiresAt    int64
	UserID       string
}

// ConnectComplete consumes the nonce and issues a JWT session token.
func (s *Service) ConnectComplete(
	ctx context.Context,
	deviceID string,
	nonce []byte,
	attestation []byte,
) (*ConnectCompleteResult, error) {
	var result ConnectCompleteResult
	err := s.DB.WriteTxDurable(ctx, func(tx *storage.Tx) error {
		var (
			expiresAt   int64
			consumedAt  sql.NullInt64
			devUserID   string
			devPubkey   []byte
			devRevoked  sql.NullInt64
			userRevoked sql.NullInt64
		)
		err := tx.QueryRow(
			`SELECT a.expires_at, a.consumed_at, d.user_id, d.public_key, d.revoked_at, u.revoked_at
			 FROM auth_nonces a
			 JOIN devices d ON d.id = a.device_id
			 JOIN users u ON u.id = d.user_id
			 WHERE a.nonce = ? AND a.device_id = ?`,
			nonce, deviceID,
		).Scan(&expiresAt, &consumedAt, &devUserID, &devPubkey, &devRevoked, &userRevoked)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNonceInvalid
		}
		if err != nil {
			return err
		}
		now := s.DB.Clock.NowMillis()
		if now > expiresAt {
			return ErrNonceInvalid
		}
		if consumedAt.Valid {
			return ErrNonceInvalid
		}
		if devRevoked.Valid || userRevoked.Valid {
			return ErrDeviceNotFound
		}
		if !ed25519.Verify(ed25519.PublicKey(devPubkey), nonce, attestation) {
			return ErrInvalidAttestation
		}

		if _, err := tx.Exec(
			`UPDATE auth_nonces SET consumed_at = ? WHERE nonce = ?`,
			now, nonce,
		); err != nil {
			return err
		}
		if _, err := tx.Exec(
			`UPDATE users SET last_seen_at = ? WHERE id = ?`,
			now, devUserID,
		); err != nil {
			return err
		}

		// Sign session token.
		var (
			generation int64
			kid        string
			signKey    []byte
		)
		if err := tx.QueryRow(
			`SELECT generation, jwt_kid, jwt_signing_key FROM server_runtime_state WHERE singleton = 1`,
		).Scan(&generation, &kid, &signKey); err != nil {
			return err
		}

		expiry := now + SessionTTL.Milliseconds()
		token, err := signSessionToken(kid, signKey, deviceID, devUserID, generation, expiry)
		if err != nil {
			return err
		}
		result = ConnectCompleteResult{
			SessionToken: token,
			ExpiresAt:    expiry,
			UserID:       devUserID,
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &result, nil
}

// SessionClaims is the parsed JWT body. Validated by ValidateSession.
type SessionClaims struct {
	DeviceID   string `json:"device_id"`
	UserID     string `json:"user_id"`
	Generation int64  `json:"gen"`
	Exp        int64  `json:"exp"`
}

func signSessionToken(kid string, key []byte, deviceID, userID string, generation, exp int64) (string, error) {
	header := map[string]any{"alg": "HS256", "typ": "JWT", "kid": kid}
	claims := SessionClaims{DeviceID: deviceID, UserID: userID, Generation: generation, Exp: exp}
	hb, err := json.Marshal(header)
	if err != nil {
		return "", err
	}
	cb, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	enc := base64.RawURLEncoding.EncodeToString
	signingInput := enc(hb) + "." + enc(cb)
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(signingInput))
	return signingInput + "." + enc(mac.Sum(nil)), nil
}

// ValidateSession checks the JWT against the server_runtime_state row.
// Returns the parsed claims on success, or ErrSessionExpired on any failure.
// The caller is responsible for re-querying user/device revocation if needed.
func (s *Service) ValidateSession(ctx context.Context, token string) (*SessionClaims, error) {
	parts := splitJWT(token)
	if len(parts) != 3 {
		return nil, ErrSessionExpired
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, ErrSessionExpired
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if err := json.Unmarshal(headerBytes, &header); err != nil || header.Alg != "HS256" {
		return nil, ErrSessionExpired
	}

	var (
		generation int64
		kid        string
		signKey    []byte
	)
	if err := s.DB.QueryRowContext(
		ctx,
		`SELECT generation, jwt_kid, jwt_signing_key FROM server_runtime_state WHERE singleton = 1`,
	).Scan(&generation, &kid, &signKey); err != nil {
		return nil, err
	}
	if header.Kid != kid {
		return nil, ErrSessionExpired
	}
	mac := hmac.New(sha256.New, signKey)
	mac.Write([]byte(parts[0] + "." + parts[1]))
	expected := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(expected), []byte(parts[2])) {
		return nil, ErrSessionExpired
	}
	cb, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, ErrSessionExpired
	}
	var claims SessionClaims
	if err := json.Unmarshal(cb, &claims); err != nil {
		return nil, ErrSessionExpired
	}
	if s.DB.Clock.NowMillis() > claims.Exp {
		return nil, ErrSessionExpired
	}
	if claims.Generation != generation {
		return nil, ErrSessionExpired
	}
	// Device/user revocation: a token issued before re-enrollment must
	// stop working the instant the device row is revoked — otherwise a
	// copied bearer retains full API + WS access until expiry despite
	// the device being revoked. JWT signature/exp/generation alone
	// don't capture this (the token is structurally valid), so check
	// the live device + user state.
	var (
		devRevoked  sql.NullInt64
		userRevoked sql.NullInt64
	)
	err = s.DB.QueryRowContext(ctx,
		`SELECT d.revoked_at, u.revoked_at
		   FROM devices d JOIN users u ON u.id = d.user_id
		  WHERE d.id = ?`,
		claims.DeviceID,
	).Scan(&devRevoked, &userRevoked)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSessionExpired
	}
	if err != nil {
		return nil, err
	}
	if devRevoked.Valid || userRevoked.Valid {
		return nil, ErrSessionExpired
	}
	return &claims, nil
}

func splitJWT(token string) []string {
	out := make([]string, 0, 3)
	start := 0
	for i := 0; i < len(token); i++ {
		if token[i] == '.' {
			out = append(out, token[start:i])
			start = i + 1
		}
	}
	out = append(out, token[start:])
	return out
}
