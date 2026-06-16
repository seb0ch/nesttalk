// Package messages implements the v0.2.0 message spool, delivery status
// tracking, and typing indicator fan-out. The server never decrypts envelopes;
// it parses only the fixed routing offsets (version, sender/recipient UUIDs,
// message_id, ct_len) to validate wire layout and store opaque ciphertext blobs.
//
// Exported types and sentinel errors are mapped to HTTP status codes by the
// mapMessagesErr helper in routes.go.
package messages

import (
	"context"
	"database/sql"
	"encoding/binary"
	"errors"
	"fmt"
	"time"

	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// Sentinel errors. The HTTP layer maps these to 400/403/404/410.
var (
	ErrEnvelopeMalformed = errors.New("envelope malformed")
	ErrNotAuthorized     = errors.New("not authorized")
	ErrRecipientRevoked  = errors.New("recipient revoked")
	ErrMessageExpired    = errors.New("message envelope expired")
	ErrInvalidAckKind    = errors.New("invalid ack kind")
	ErrNotFound          = errors.New("message not found")
)

// RecipientDeviceRotatedError is returned by Post when the envelope's
// recipient_device_id does not match the user's current active device.
// Callers use errors.As to extract ActiveDeviceID for the spec-mandated
// active_recipient_device_id field in the 403 response body.
type RecipientDeviceRotatedError struct {
	ActiveDeviceID string
}

func (e *RecipientDeviceRotatedError) Error() string {
	return "recipient device rotated"
}

// Envelope wire layout constants.
const (
	MinEnvelopeLen = 1297 // 1 + 16+16+16+16+16 + 32 + 1088 + 12 + 4 + 16 + 64 = 1297
	MaxCTLen       = 65536

	offVersion           = 0
	offSenderUserID      = 1
	offSenderDeviceID    = 17
	offRecipientUserID   = 33
	offRecipientDeviceID = 49
	offMessageID         = 65
	offCTLen             = 1213
	offCT                = 1217

	// defaultSpoolTTLMs is the offline-spool retention window per spec line 310.
	defaultSpoolTTLMs = int64(30 * 24 * 60 * 60 * 1000)

	// noncePurgeGraceMs is the 1-hour clock-skew grace window applied when
	// purging expired auth_nonces, per spec lines 237–239.
	noncePurgeGraceMs = int64(60 * 60 * 1000)
)

// ParsedEnvelope holds the routing fields extracted from the wire envelope.
// The server uses only these fields; the rest is opaque ciphertext.
type ParsedEnvelope struct {
	Version           uint8
	SenderUserID      []byte // 16 bytes raw UUID
	SenderDeviceID    []byte
	RecipientUserID   []byte
	RecipientDeviceID []byte
	MessageID         []byte
	CTLen             uint32
}

// ParseEnvelope validates the wire layout and extracts routing fields.
// It accepts any version byte — unknown versions are valid for routing.
// Rejects: total_len < MinEnvelopeLen, ct_len > MaxCTLen, total_len != 1217+ct_len+64.
func ParseEnvelope(env []byte) (*ParsedEnvelope, error) {
	if len(env) < MinEnvelopeLen {
		return nil, fmt.Errorf("%w: too short (%d bytes, min %d)", ErrEnvelopeMalformed, len(env), MinEnvelopeLen)
	}
	ctLen := binary.BigEndian.Uint32(env[offCTLen : offCTLen+4])
	if ctLen > MaxCTLen {
		return nil, fmt.Errorf("%w: ct_len %d exceeds max %d", ErrEnvelopeMalformed, ctLen, MaxCTLen)
	}
	expectedLen := offCT + int(ctLen) + 64
	if len(env) != expectedLen {
		return nil, fmt.Errorf("%w: total_len %d != expected %d", ErrEnvelopeMalformed, len(env), expectedLen)
	}
	return &ParsedEnvelope{
		Version:           env[offVersion],
		SenderUserID:      env[offSenderUserID : offSenderUserID+16],
		SenderDeviceID:    env[offSenderDeviceID : offSenderDeviceID+16],
		RecipientUserID:   env[offRecipientUserID : offRecipientUserID+16],
		RecipientDeviceID: env[offRecipientDeviceID : offRecipientDeviceID+16],
		MessageID:         env[offMessageID : offMessageID+16],
		CTLen:             ctLen,
	}, nil
}

// uuidBytesToString converts 16 raw bytes to a standard UUID string.
func uuidBytesToString(b []byte) string {
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// Service owns the message spool and delivery status operations.
type Service struct {
	DB  *storage.DB
	Hub *ws.Hub
	// Clock allows tests to override time. Defaults to the DB's clock.
	Clock storage.Clock
}

// New constructs a Service. Clock defaults to db.Clock.
func New(db *storage.DB, hub *ws.Hub) *Service {
	return &Service{DB: db, Hub: hub, Clock: db.Clock}
}

func (s *Service) now() int64 { return s.Clock.NowMillis() }

// PostRequest is the input to Service.Post.
type PostRequest struct {
	EnvelopeBytes   []byte
	SentAt          int64
	ReplyToID       *string
	SessionUserID   string
	SessionDeviceID string
}

// PostResult is returned from Service.Post on success.
type PostResult struct {
	ID         string
	ReceivedAt int64
	SentAt     int64
}

// Post validates and stores one message envelope.
// Idempotent by message_id: existing messages row → 200 echo; existing
// message_acks row → ErrMessageExpired (410).
func (s *Service) Post(ctx context.Context, req PostRequest) (*PostResult, error) {
	parsed, err := ParseEnvelope(req.EnvelopeBytes)
	if err != nil {
		return nil, err
	}

	senderUID := uuidBytesToString(parsed.SenderUserID)
	senderDevID := uuidBytesToString(parsed.SenderDeviceID)
	recipientUID := uuidBytesToString(parsed.RecipientUserID)
	recipientDevID := uuidBytesToString(parsed.RecipientDeviceID)
	msgID := uuidBytesToString(parsed.MessageID)

	// Authorization: session must match envelope sender (user AND
	// device). Binding the device prevents an authenticated user from
	// naming a NONEXISTENT sender device — which a receiving client
	// can't resolve a signing key for, wedging its catch-up cursor
	// forever (the key lookup defers indefinitely). SessionDeviceID
	// empty (older callers) skips the device bind for back-compat.
	if req.SessionUserID != senderUID {
		return nil, ErrNotAuthorized
	}
	if req.SessionDeviceID != "" && req.SessionDeviceID != senderDevID {
		return nil, ErrNotAuthorized
	}

	var result *PostResult
	var isNewlyInserted bool

	err = s.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		// Idempotency check: existing messages row.
		var existingReceivedAt, existingSentAt int64
		var existingSender, existingRecipient string
		err := tx.QueryRow(
			`SELECT sender_user_id, recipient_user_id, received_at, sent_at FROM messages WHERE id = ?`, msgID,
		).Scan(&existingSender, &existingRecipient, &existingReceivedAt, &existingSentAt)
		if err == nil {
			// Row already exists → idempotent echo. A committed message_id is
			// IMMUTABLE: a duplicate POST never rewrites the stored ciphertext.
			// (A recipient who re-enrolls before reading a spooled message
			// cannot decrypt ciphertext sealed for the revoked device — an
			// inherent property of E2EE re-enrollment; the sender resends as a
			// new message if needed. We do not mutate delivered/committed rows.)
			//
			// Bind the echo to the row's OWN sender + recipient first: a
			// message_id is only ever a stable retry key for its own
			// conversation, so a user who learns a foreign message UUID can't
			// reuse it under their own (authorized-sender) envelope to probe
			// another conversation's metadata.
			if existingSender != senderUID || existingRecipient != recipientUID {
				return ErrNotAuthorized
			}
			result = &PostResult{ID: msgID, ReceivedAt: existingReceivedAt, SentAt: existingSentAt}
			return nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return err
		}

		// Idempotency check: existing message_acks row (the messages row was
		// purged after delivery) → 410. Bind it to its OWN sender + recipient
		// first, exactly like the messages-row echo above: a message_id is only
		// a retry key for its own conversation, so a user who learns a purged
		// UUID must not be able to reuse it under their own envelope to
		// distinguish a real historical message (410) from a non-existent id —
		// that would leak cross-conversation metadata.
		var ackSender, ackRecipient string
		ackErr := tx.QueryRow(
			`SELECT sender_user_id, recipient_user_id FROM message_acks WHERE message_id = ?`, msgID,
		).Scan(&ackSender, &ackRecipient)
		if ackErr == nil {
			if ackSender != senderUID || ackRecipient != recipientUID {
				return ErrNotAuthorized
			}
			return ErrMessageExpired
		}
		if !errors.Is(ackErr, sql.ErrNoRows) {
			return ackErr
		}

		// Recipient checks.
		var recipientRevoked sql.NullInt64
		err = tx.QueryRow(
			`SELECT revoked_at FROM users WHERE id = ?`, recipientUID,
		).Scan(&recipientRevoked)
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("%w: recipient user not found", ErrNotAuthorized)
		}
		if err != nil {
			return err
		}
		if recipientRevoked.Valid {
			return ErrRecipientRevoked
		}

		// Device check: envelope.recipient_device_id must match the active device.
		var activeDevID string
		err = tx.QueryRow(
			`SELECT id FROM devices WHERE user_id = ? AND revoked_at IS NULL`, recipientUID,
		).Scan(&activeDevID)
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("%w: recipient has no active device", ErrNotAuthorized)
		}
		if err != nil {
			return err
		}
		if activeDevID != recipientDevID {
			return &RecipientDeviceRotatedError{ActiveDeviceID: activeDevID}
		}

		now := s.now()
		expiresAt := now + defaultSpoolTTLMs

		var replyToID sql.NullString
		if req.ReplyToID != nil {
			replyToID = sql.NullString{String: *req.ReplyToID, Valid: true}
		}

		if _, err := tx.Exec(
			`INSERT INTO messages
			 (id, sender_user_id, recipient_user_id, envelope, reply_to_id, sent_at, received_at, expires_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			msgID, senderUID, recipientUID, req.EnvelopeBytes, replyToID, req.SentAt, now, expiresAt,
		); err != nil {
			return err
		}

		result = &PostResult{ID: msgID, ReceivedAt: now, SentAt: req.SentAt}
		isNewlyInserted = true
		return nil
	})
	if err != nil {
		return nil, err
	}

	// Fan-out WS event to recipient only on fresh inserts. Idempotent re-posts
	// must not trigger a second event — the client already received it.
	if isNewlyInserted && s.Hub != nil {
		ev := ws.MessageEvent(msgID, senderUID, recipientUID, req.EnvelopeBytes, req.SentAt, result.ReceivedAt, req.ReplyToID)
		s.Hub.SendToUser(recipientUID, ev)
	}

	return result, nil
}

// PendingRequest is the input to Service.Pending.
type PendingRequest struct {
	RecipientUserID string
	SinceReceivedAt int64
	SinceID         string
	Limit           int
}

// PendingMessage is one row in the pending response.
type PendingMessage struct {
	ID           string  `json:"id"`
	SenderUserID string  `json:"sender_user_id"`
	Envelope     []byte  `json:"-"` // raw bytes; routes.go base64-encodes for JSON
	ReplyToID    *string `json:"reply_to_id"`
	SentAt       int64   `json:"sent_at"`
	ReceivedAt   int64   `json:"received_at"`
}

// Cursor is the composite pagination cursor.
type Cursor struct {
	ReceivedAt int64  `json:"received_at"`
	ID         string `json:"id"`
}

// PendingResult is returned from Service.Pending.
type PendingResult struct {
	Messages   []PendingMessage
	NextCursor *Cursor
}

// Pending fetches pending messages for the recipient using a composite cursor.
func (s *Service) Pending(ctx context.Context, req PendingRequest) (*PendingResult, error) {
	limit := req.Limit
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}

	// Composite cursor predicate: (received_at, id) > (sinceReceivedAt, sinceID).
	// When sinceReceivedAt==0 and sinceID=="", fetch from the beginning.
	rows, err := s.DB.QueryContext(ctx,
		`SELECT id, sender_user_id, envelope, reply_to_id, sent_at, received_at
		 FROM messages
		 WHERE recipient_user_id = ?
		   AND (received_at > ? OR (received_at = ? AND id > ?))
		 ORDER BY received_at ASC, id ASC
		 LIMIT ?`,
		req.RecipientUserID,
		req.SinceReceivedAt, req.SinceReceivedAt, req.SinceID,
		limit,
	)
	if err != nil {
		return nil, fmt.Errorf("query pending: %w", err)
	}
	defer rows.Close()

	var msgs []PendingMessage
	for rows.Next() {
		var (
			m             PendingMessage
			replyToID     sql.NullString
			envelopeBytes []byte
		)
		if err := rows.Scan(&m.ID, &m.SenderUserID, &envelopeBytes, &replyToID, &m.SentAt, &m.ReceivedAt); err != nil {
			return nil, fmt.Errorf("scan pending: %w", err)
		}
		m.Envelope = envelopeBytes
		if replyToID.Valid {
			v := replyToID.String
			m.ReplyToID = &v
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate pending: %w", err)
	}

	res := &PendingResult{Messages: msgs}
	if len(msgs) > 0 {
		last := msgs[len(msgs)-1]
		res.NextCursor = &Cursor{ReceivedAt: last.ReceivedAt, ID: last.ID}
	}
	return res, nil
}

// AckRequest is the input to Service.Ack.
type AckRequest struct {
	MessageID     string
	Kind          string // "delivered" | "read"
	SessionUserID string
}

// Ack records a delivery or read acknowledgement.
func (s *Service) Ack(ctx context.Context, req AckRequest) error {
	if req.Kind != "delivered" && req.Kind != "read" {
		return ErrInvalidAckKind
	}

	var senderUID string
	err := s.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		now := s.now()

		// Branch A: messages row exists.
		var msgSenderUID, msgRecipientUID string
		err := tx.QueryRow(
			`SELECT sender_user_id, recipient_user_id FROM messages WHERE id = ?`, req.MessageID,
		).Scan(&msgSenderUID, &msgRecipientUID)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if err == nil {
			// Found in messages table.
			if req.SessionUserID != msgRecipientUID {
				return ErrNotAuthorized
			}
			senderUID = msgSenderUID

			var deliveredAt, readAt sql.NullInt64
			if req.Kind == "delivered" {
				deliveredAt = sql.NullInt64{Int64: now, Valid: true}
			} else {
				readAt = sql.NullInt64{Int64: now, Valid: true}
			}
			_, err = tx.Exec(
				`INSERT INTO message_acks (message_id, sender_user_id, recipient_user_id, delivered_at, read_at)
				 VALUES (?, ?, ?, ?, ?)
				 ON CONFLICT(message_id) DO UPDATE SET
				   delivered_at = COALESCE(excluded.delivered_at, message_acks.delivered_at),
				   read_at = COALESCE(excluded.read_at, message_acks.read_at)`,
				req.MessageID, msgSenderUID, msgRecipientUID,
				deliveredAt, readAt,
			)
			return err
		}

		// Branch B: only message_acks row.
		var ackSenderUID, ackRecipientUID string
		err = tx.QueryRow(
			`SELECT sender_user_id, recipient_user_id FROM message_acks WHERE message_id = ?`, req.MessageID,
		).Scan(&ackSenderUID, &ackRecipientUID)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if req.SessionUserID != ackRecipientUID {
			return ErrNotAuthorized
		}
		senderUID = ackSenderUID

		var deliveredArg, readArg sql.NullInt64
		if req.Kind == "delivered" {
			deliveredArg = sql.NullInt64{Int64: now, Valid: true}
		} else {
			readArg = sql.NullInt64{Int64: now, Valid: true}
		}
		_, err = tx.Exec(
			`UPDATE message_acks
			 SET delivered_at = COALESCE(delivered_at, ?),
			     read_at = COALESCE(read_at, ?)
			 WHERE message_id = ? AND recipient_user_id = ?`,
			deliveredArg, readArg, req.MessageID, ackRecipientUID,
		)
		return err
	})
	if err != nil {
		return err
	}

	// Fan-out ack event to sender.
	if s.Hub != nil && senderUID != "" {
		var ev ws.Event
		switch req.Kind {
		case "delivered":
			ev = ws.MessageDelivered(req.MessageID)
		case "read":
			ev = ws.MessageRead(req.MessageID)
		}
		s.Hub.SendToUser(senderUID, ev)
	}
	return nil
}

// StatusRequest is the input to Service.Status.
type StatusRequest struct {
	MessageID     string
	SessionUserID string
}

// Status returns the delivery status string for a message.
// Only the sender may query; non-sender gets ErrNotAuthorized.
// If neither row exists, returns "gone" with no error.
func (s *Service) Status(ctx context.Context, req StatusRequest) (string, error) {
	// Try messages row first (sender check).
	var msgSenderUID string
	err := s.DB.QueryRowContext(ctx,
		`SELECT sender_user_id FROM messages WHERE id = ?`, req.MessageID,
	).Scan(&msgSenderUID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if err == nil {
		if req.SessionUserID != msgSenderUID {
			return "", ErrNotAuthorized
		}
		// Check if there's already an ack row.
		var deliveredAt, readAt sql.NullInt64
		err2 := s.DB.QueryRowContext(ctx,
			`SELECT delivered_at, read_at FROM message_acks WHERE message_id = ?`, req.MessageID,
		).Scan(&deliveredAt, &readAt)
		if errors.Is(err2, sql.ErrNoRows) {
			return "pending", nil
		}
		if err2 != nil {
			return "", err2
		}
		return resolveStatus(deliveredAt, readAt, sql.NullInt64{}), nil
	}

	// Only message_acks row exists.
	var ackSenderUID string
	var deliveredAt, readAt, expiredAt sql.NullInt64
	err = s.DB.QueryRowContext(ctx,
		`SELECT sender_user_id, delivered_at, read_at, expired_at
		 FROM message_acks WHERE message_id = ?`, req.MessageID,
	).Scan(&ackSenderUID, &deliveredAt, &readAt, &expiredAt)
	if errors.Is(err, sql.ErrNoRows) {
		// Per spec: no rows at all → "gone" (sender unverified).
		return "gone", nil
	}
	if err != nil {
		return "", err
	}
	if req.SessionUserID != ackSenderUID {
		return "", ErrNotAuthorized
	}
	return resolveStatus(deliveredAt, readAt, expiredAt), nil
}

// resolveStatus maps ack columns to the status string per spec precedence:
// read > delivered > expired > pending.
func resolveStatus(deliveredAt, readAt, expiredAt sql.NullInt64) string {
	if readAt.Valid {
		return "read"
	}
	if deliveredAt.Valid {
		return "delivered"
	}
	if expiredAt.Valid {
		return "expired"
	}
	return "pending"
}

// RunPurgeOnce purges all messages with expires_at < now(), writing
// tombstone rows into message_acks first. Returns the number of purged rows.
// Called by the background ticker and by tests for deterministic control.
func (s *Service) RunPurgeOnce(ctx context.Context) (int, error) {
	now := s.now()
	var count int

	err := s.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		rows, err := tx.Query(
			`SELECT id, sender_user_id, recipient_user_id FROM messages WHERE expires_at < ?`, now,
		)
		if err != nil {
			return fmt.Errorf("purge query: %w", err)
		}
		type row struct{ id, senderUID, recipientUID string }
		var toDelete []row
		for rows.Next() {
			var r row
			if err := rows.Scan(&r.id, &r.senderUID, &r.recipientUID); err != nil {
				rows.Close()
				return err
			}
			toDelete = append(toDelete, r)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}

		for _, r := range toDelete {
			// Upsert tombstone preserving any earlier delivered/read.
			if _, err := tx.Exec(
				`INSERT INTO message_acks (message_id, sender_user_id, recipient_user_id, expired_at)
				 VALUES (?, ?, ?, ?)
				 ON CONFLICT(message_id) DO UPDATE SET
				   expired_at = COALESCE(message_acks.expired_at, excluded.expired_at)`,
				r.id, r.senderUID, r.recipientUID, now,
			); err != nil {
				return fmt.Errorf("purge upsert ack %s: %w", r.id, err)
			}
		}

		if len(toDelete) > 0 {
			// Batch delete.
			ids := make([]any, len(toDelete))
			for i, r := range toDelete {
				ids[i] = r.id
			}
			placeholders := ""
			for i := range ids {
				if i > 0 {
					placeholders += ","
				}
				placeholders += "?"
			}
			if _, err := tx.Exec(
				`DELETE FROM messages WHERE id IN (`+placeholders+`)`, ids...,
			); err != nil {
				return fmt.Errorf("purge delete: %w", err)
			}
		}

		count = len(toDelete)
		return nil
	})
	if err != nil {
		return count, err
	}

	// Purge expired auth_nonces with 1-hour clock-skew grace (independent of
	// the messages transaction — auth_nonces has no FK to messages).
	if err2 := s.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		_, err := tx.Exec(
			`DELETE FROM auth_nonces WHERE expires_at < ?`,
			now-noncePurgeGraceMs,
		)
		return err
	}); err2 != nil {
		return count, err2
	}

	return count, nil
}

// RunForever runs the purge job on a ticker until ctx is cancelled.
// Called from main.go as a goroutine.
func (s *Service) RunForever(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			_, _ = s.RunPurgeOnce(ctx)
		}
	}
}
