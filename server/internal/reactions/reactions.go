// Package reactions implements the v0.2.0 reaction PUT/GET-since endpoints.
//
// The server treats reaction envelopes as opaque ciphertext blobs, the same
// way it treats message envelopes. It parses only the fixed routing offsets
// (sender_user_id, recipient_user_id) to validate authorization and fan out
// to the recipient — the actual emoji payload is never seen in plaintext.
//
// ParseEnvelope is intentionally re-used from the messages package so that
// the same wire-layout validation logic runs for both message and reaction
// envelopes. This satisfies the spec requirement to validate a signed envelope
// on every state change including removes.
//
// UPSERT invariant: reactions.id (PRIMARY KEY) is set on first PUT and never
// updated. Subsequent PUTs from the same (message_id, sender_user_id) pair
// overwrite only the envelope and sent_at. This allows the client to change
// emoji or un-react without losing the canonical server-assigned id, which
// the recipient uses as an idempotent handle for the reaction row.
//
// Parent-delivered ordering invariant: the reactions FK references messages(id)
// ON DELETE CASCADE, which means the parent message MUST exist at INSERT time.
// The pre-check in Put returns ErrParentPurged (→ 410) if the row is absent,
// so the reaction can never race ahead of its parent in the recipient's view.
package reactions

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/seb0ch/nesttalk/server/internal/messages"
	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// Sentinel errors. The HTTP layer maps these to 400/403/410/500.
var (
	ErrEnvelopeMalformed = errors.New("envelope malformed")
	ErrNotAuthorized     = errors.New("not authorized")
	ErrParentPurged      = errors.New("parent message has been purged")
)

// Service owns the reaction spool operations.
type Service struct {
	DB    *storage.DB
	Hub   *ws.Hub
	Clock storage.Clock
}

// New constructs a Service. Clock defaults to db.Clock.
func New(db *storage.DB, hub *ws.Hub) *Service {
	return &Service{DB: db, Hub: hub, Clock: db.Clock}
}

func (s *Service) now() int64 { return s.Clock.NowMillis() }

// PutRequest is the input to Service.Put.
type PutRequest struct {
	MessageID       string
	EnvelopeBytes   []byte
	SentAt          int64
	SessionUserID   string
	SessionDeviceID string
}

// PutResult is returned from Service.Put on success.
type PutResult struct {
	ID         string
	ReceivedAt int64
}

// Put validates and upserts one reaction envelope.
//
// Pre-check: if no messages row with id=MessageID exists → ErrParentPurged.
// Authorization: session.user_id must equal envelope.sender_user_id.
// UPSERT: INSERT ON CONFLICT(message_id, sender_user_id) DO UPDATE SET
// envelope and sent_at only — id is never changed after first insert.
// On success, fans out a "reaction" WS event to the recipient.
func (s *Service) Put(ctx context.Context, req PutRequest) (*PutResult, error) {
	parsed, err := messages.ParseEnvelope(req.EnvelopeBytes)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrEnvelopeMalformed, err)
	}

	senderUID := uuidBytesToString(parsed.SenderUserID)
	senderDevID := uuidBytesToString(parsed.SenderDeviceID)
	recipientUID := uuidBytesToString(parsed.RecipientUserID)

	// Binding: the SIGNED message id inside the envelope must equal the parent
	// id named on the path. The recipient binds the reaction to its parent by
	// the signed message id and rejects any whose signed id differs from the
	// wrapper id — so without this check a skewed/malformed client gets a 200
	// here while the peer silently drops the reaction, then catch-up advances
	// past it (permanent loss). Reject the inconsistent write outright.
	if uuidBytesToString(parsed.MessageID) != req.MessageID {
		return nil, ErrNotAuthorized
	}

	// Authorization: session must match envelope sender (user AND
	// device — see messages.Post for why the device bind matters).
	if req.SessionUserID != senderUID {
		return nil, ErrNotAuthorized
	}
	if req.SessionDeviceID != "" && req.SessionDeviceID != senderDevID {
		return nil, ErrNotAuthorized
	}

	var result *PutResult

	err = s.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		// Pre-check: parent message must exist (guards FK and provides the
		// parent-delivered ordering invariant documented at the package
		// level) AND the reactor must be a PARTICIPANT of that parent.
		// Without the participant check, any authenticated user who learns
		// a message UUID could inject a signed reaction into someone else's
		// conversation: the session==sender check above only proves the
		// reaction is signed by its own author, not that the author belongs
		// to this thread.
		var parentSender, parentRecipient string
		if err := tx.QueryRow(
			`SELECT sender_user_id, recipient_user_id FROM messages WHERE id = ?`, req.MessageID,
		).Scan(&parentSender, &parentRecipient); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrParentPurged
			}
			return err
		}
		// The reaction's (sender, recipient) must be exactly the parent's
		// participant pair, in either direction — either participant may
		// react, and only to the other.
		fromAToB := senderUID == parentSender && recipientUID == parentRecipient
		fromBToA := senderUID == parentRecipient && recipientUID == parentSender
		if !fromAToB && !fromBToA {
			return ErrNotAuthorized
		}

		// Device check: envelope.recipient_device_id must target the
		// recipient's CURRENT active device — same contract as message
		// sends. Without it, a sender with stale cached keys (recipient
		// re-enrolled) stores ciphertext only the revoked device can
		// decrypt; the new device's decrypt failure would read as "the
		// reaction was cleared". The typed rotation error lets the
		// client re-fetch keys and re-seal.
		recipientDevID := uuidBytesToString(parsed.RecipientDeviceID)
		var activeDevID string
		devErr := tx.QueryRow(
			`SELECT id FROM devices WHERE user_id = ? AND revoked_at IS NULL`, recipientUID,
		).Scan(&activeDevID)
		if errors.Is(devErr, sql.ErrNoRows) {
			return fmt.Errorf("%w: recipient has no active device", ErrNotAuthorized)
		}
		if devErr != nil {
			return devErr
		}
		if activeDevID != recipientDevID {
			return &messages.RecipientDeviceRotatedError{ActiveDeviceID: activeDevID}
		}

		now := s.now()

		// Look up the existing canonical id AND its received_at for this
		// (message, sender) pair. The UPSERT preserves the id on conflict;
		// we need the id to return it, and the prior received_at to keep the
		// catch-up cursor strictly monotonic.
		var existingID string
		var prevReceivedAt int64
		err := tx.QueryRow(
			`SELECT id, received_at FROM reactions WHERE message_id = ? AND sender_user_id = ?`,
			req.MessageID, senderUID,
		).Scan(&existingID, &prevReceivedAt)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}

		// The /reactions/since cursor is (received_at, id), and an update
		// keeps the same canonical id — so received_at MUST strictly advance,
		// or a same-millisecond set/change/clear at the recipient's cursor
		// boundary is excluded (neither received_at>cursor nor id>cursorID)
		// and the offline recipient is left with a stale/uncleared reaction.
		receivedAt := now
		if existingID != "" && prevReceivedAt+1 > receivedAt {
			receivedAt = prevReceivedAt + 1
		}

		var canonicalID string
		if existingID != "" {
			// Row exists: update envelope+sent_at, preserve canonical id.
			canonicalID = existingID
			if _, err := tx.Exec(
				`UPDATE reactions SET envelope = ?, sent_at = ?, received_at = ?
				 WHERE message_id = ? AND sender_user_id = ?`,
				req.EnvelopeBytes, req.SentAt, receivedAt,
				req.MessageID, senderUID,
			); err != nil {
				return err
			}
		} else {
			// New reaction: assign a server-generated canonical UUID.
			canonicalID = uuid.New().String()
			if _, err := tx.Exec(
				`INSERT INTO reactions (id, message_id, sender_user_id, recipient_user_id, envelope, sent_at, received_at)
				 VALUES (?, ?, ?, ?, ?, ?, ?)`,
				canonicalID, req.MessageID, senderUID, recipientUID,
				req.EnvelopeBytes, req.SentAt, receivedAt,
			); err != nil {
				return err
			}
		}

		result = &PutResult{ID: canonicalID, ReceivedAt: receivedAt}
		return nil
	})
	if err != nil {
		return nil, err
	}

	// Fan-out WS "reaction" event to recipient. The parent message_id is used
	// as the wrapper id per spec, so the client can correlate the event with
	// the correct thread without re-fetching.
	if s.Hub != nil {
		ev := ws.ReactionEvent(
			req.MessageID, result.ID, senderUID,
			req.EnvelopeBytes, req.SentAt, result.ReceivedAt,
		)
		s.Hub.SendToUser(recipientUID, ev)
	}

	return result, nil
}

// SinceRequest is the input to Service.Since.
type SinceRequest struct {
	RecipientUserID string
	SinceReceivedAt int64
	SinceID         string
	Limit           int
}

// ReactionRow is one row in the Since response.
type ReactionRow struct {
	ID           string `json:"id"`
	MessageID    string `json:"message_id"`
	SenderUserID string `json:"sender_user_id"`
	Envelope     []byte `json:"-"` // raw bytes; routes.go base64-encodes for JSON
	SentAt       int64  `json:"sent_at"`
	ReceivedAt   int64  `json:"received_at"`
}

// Cursor is the composite pagination cursor (shared with messages package type
// but defined separately to keep packages independent).
type Cursor struct {
	ReceivedAt int64  `json:"received_at"`
	ID         string `json:"id"`
}

// SinceResult is returned from Service.Since.
type SinceResult struct {
	Reactions  []ReactionRow
	NextCursor *Cursor
}

// Since fetches reactions for the recipient using a composite cursor.
// Limit is clamped to [1, 500]; default 100.
func (s *Service) Since(ctx context.Context, req SinceRequest) (*SinceResult, error) {
	limit := req.Limit
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}

	// Composite cursor predicate: (received_at, id) > (sinceReceivedAt, sinceID).
	rows, err := s.DB.QueryContext(ctx,
		`SELECT id, message_id, sender_user_id, envelope, sent_at, received_at
		 FROM reactions
		 WHERE recipient_user_id = ?
		   AND (received_at > ? OR (received_at = ? AND id > ?))
		 ORDER BY received_at ASC, id ASC
		 LIMIT ?`,
		req.RecipientUserID,
		req.SinceReceivedAt, req.SinceReceivedAt, req.SinceID,
		limit,
	)
	if err != nil {
		return nil, fmt.Errorf("query reactions since: %w", err)
	}
	defer rows.Close()

	var rxns []ReactionRow
	for rows.Next() {
		var r ReactionRow
		if err := rows.Scan(&r.ID, &r.MessageID, &r.SenderUserID, &r.Envelope, &r.SentAt, &r.ReceivedAt); err != nil {
			return nil, fmt.Errorf("scan reaction: %w", err)
		}
		rxns = append(rxns, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate reactions: %w", err)
	}

	res := &SinceResult{Reactions: rxns}
	if len(rxns) > 0 {
		last := rxns[len(rxns)-1]
		res.NextCursor = &Cursor{ReceivedAt: last.ReceivedAt, ID: last.ID}
	}
	return res, nil
}

// uuidBytesToString converts 16 raw bytes to a standard UUID string.
// Duplicated from messages package to keep packages independent.
func uuidBytesToString(b []byte) string {
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
