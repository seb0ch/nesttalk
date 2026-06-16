// Package roster implements the v0.2.0 auto-connect roster: every enrolled,
// non-revoked user (except self) is visible to every other enrolled user.
package roster

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/seb0ch/nesttalk/server/internal/storage"
)

// Service is the roster service over the storage layer.
type Service struct {
	DB *storage.DB
}

// New constructs a roster Service.
func New(db *storage.DB) *Service { return &Service{DB: db} }

// Entry is one row in the roster response.
type Entry struct {
	UserID      string `json:"user_id"`
	DisplayName string `json:"display_name"`
	ColorHint   int    `json:"color_hint"`
	LastSeenAt  *int64 `json:"last_seen_at"`
}

// List returns every enrolled non-revoked user except the caller, ordered by
// display_name. selfUserID may be empty (admin/CLI listings).
func (s *Service) List(ctx context.Context, selfUserID string) ([]Entry, error) {
	rows, err := s.DB.QueryContext(ctx,
		`SELECT id, display_name, color_hint, last_seen_at
		 FROM users
		 WHERE revoked_at IS NULL AND (? = '' OR id != ?)
		 ORDER BY display_name`,
		selfUserID, selfUserID,
	)
	if err != nil {
		return nil, fmt.Errorf("query roster: %w", err)
	}
	defer rows.Close()

	out := []Entry{}
	for rows.Next() {
		var (
			e          Entry
			lastSeenAt sql.NullInt64
		)
		if err := rows.Scan(&e.UserID, &e.DisplayName, &e.ColorHint, &lastSeenAt); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		if lastSeenAt.Valid {
			v := lastSeenAt.Int64
			e.LastSeenAt = &v
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
