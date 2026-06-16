// Package keys serves GET /api/v1/keys/message/{userId}: returns the user's
// active device pubkey plus all historically-enrolled devices, each tagged
// with revoked_at (NULL for active). See spec section "Keys endpoint
// retains device pubkeys indefinitely for verification".
package keys

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/seb0ch/nesttalk/server/internal/storage"
)

// ErrUserNotFound is returned when no users row matches the lookup id.
var ErrUserNotFound = errors.New("user not found")

// Service serves key lookups.
type Service struct {
	DB *storage.DB
}

// New constructs a keys Service.
func New(db *storage.DB) *Service { return &Service{DB: db} }

// DeviceKey is one entry in the response.
type DeviceKey struct {
	DeviceID      string `json:"device_id"`
	PublicKey     []byte `json:"public_key"`
	MessagePubKey []byte `json:"message_pubkey"`
	EnrolledAt    int64  `json:"enrolled_at"`
	RevokedAt     *int64 `json:"revoked_at"`
}

// MessageKeys returns ALL devices for the user. The first entry (revoked_at == nil)
// is the active device; remaining entries are historical (for signature verification).
func (s *Service) MessageKeys(ctx context.Context, userID string) ([]DeviceKey, error) {
	// Confirm user exists.
	var revokedAt sql.NullInt64
	err := s.DB.QueryRowContext(ctx,
		`SELECT revoked_at FROM users WHERE id = ?`, userID,
	).Scan(&revokedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("lookup user: %w", err)
	}

	rows, err := s.DB.QueryContext(ctx,
		`SELECT id, public_key, message_pubkey, enrolled_at, revoked_at
		 FROM devices
		 WHERE user_id = ?
		 ORDER BY (CASE WHEN revoked_at IS NULL THEN 0 ELSE 1 END), enrolled_at ASC`,
		userID,
	)
	if err != nil {
		return nil, fmt.Errorf("query devices: %w", err)
	}
	defer rows.Close()

	out := []DeviceKey{}
	for rows.Next() {
		var (
			dk DeviceKey
			rv sql.NullInt64
		)
		if err := rows.Scan(&dk.DeviceID, &dk.PublicKey, &dk.MessagePubKey, &dk.EnrolledAt, &rv); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		if rv.Valid {
			v := rv.Int64
			dk.RevokedAt = &v
		}
		out = append(out, dk)
	}
	return out, rows.Err()
}
