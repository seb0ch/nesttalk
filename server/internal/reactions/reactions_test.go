package reactions_test

import (
	"context"
	"encoding/binary"
	"errors"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/messages"
	"github.com/seb0ch/nesttalk/server/internal/reactions"
	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// ----- test helpers -----

type fixedClock struct{ t int64 }

func (c *fixedClock) NowMillis() int64 { return c.t }

func openDB(t *testing.T, clk storage.Clock) *storage.DB {
	t.Helper()
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), clk)
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func insertUser(t *testing.T, db *storage.DB, userID, deviceID string, now int64) {
	t.Helper()
	_, err := db.Exec(
		`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, 0, ?)`,
		userID, "u-"+userID, now,
	)
	require.NoError(t, err)
	_, err = db.Exec(
		`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at)
		 VALUES (?, ?, randomblob(32), randomblob(1216), ?)`,
		deviceID, userID, now,
	)
	require.NoError(t, err)
}

// insertMessage inserts a minimal message row for FK tests.
func insertMessage(t *testing.T, db *storage.DB, msgID, senderUID, recipientUID string, now int64) {
	t.Helper()
	_, err := db.Exec(
		`INSERT INTO messages (id, sender_user_id, recipient_user_id, envelope, sent_at, received_at, expires_at)
		 VALUES (?, ?, ?, randomblob(1297), ?, ?, ?)`,
		msgID, senderUID, recipientUID, now, now, now+100000,
	)
	require.NoError(t, err)
}

const (
	// Envelope constants — matches messages.MinEnvelopeLen / wire layout.
	offSenderUserID      = 1
	offRecipientUserID   = 33
	offRecipientDeviceID = 49
	offCTLen             = 1213
	offCT                = 1217
)

func uuidRaw(s string) [16]byte {
	var b [16]byte
	hex := make([]byte, 0, 32)
	for _, c := range s {
		if c == '-' {
			continue
		}
		hex = append(hex, byte(c))
	}
	for i := 0; i < 16 && i*2+1 < len(hex); i++ {
		b[i] = hexByte(hex[i*2], hex[i*2+1])
	}
	return b
}

func hexByte(hi, lo byte) byte { return (hexNibble(hi) << 4) | hexNibble(lo) }
func hexNibble(c byte) byte {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10
	}
	return 0
}

// buildReactionEnvelope builds a minimal spec-conformant envelope with
// the given sender and recipient routing fields.
func buildReactionEnvelope(senderUserID, senderDeviceID, recipientUserID, recipientDeviceID, messageID string, ct []byte) []byte {
	sUID := uuidRaw(senderUserID)
	sDID := uuidRaw(senderDeviceID)
	rUID := uuidRaw(recipientUserID)
	rDID := uuidRaw(recipientDeviceID)
	// The SIGNED message id must equal the parent id named on the request path
	// (the server now enforces this binding); tests pass the parent id.
	mID := uuidRaw(messageID)

	buf := make([]byte, 0, 1217+len(ct)+64)
	buf = append(buf, 0x01) // version
	buf = append(buf, sUID[:]...)
	buf = append(buf, sDID[:]...)
	buf = append(buf, rUID[:]...)
	buf = append(buf, rDID[:]...)
	buf = append(buf, mID[:]...)
	buf = append(buf, make([]byte, 32)...)   // eph_x25519_pub
	buf = append(buf, make([]byte, 1088)...) // ml_kem_ct
	buf = append(buf, make([]byte, 12)...)   // nonce
	ctLen := uint32(len(ct))
	buf = append(buf, byte(ctLen>>24), byte(ctLen>>16), byte(ctLen>>8), byte(ctLen))
	buf = append(buf, ct...)
	buf = append(buf, make([]byte, 64)...) // sender_sig
	return buf
}

// ----- constants for test UUIDs -----

const (
	aliceUID    = "aaaaaaaa-aaaa-aaaa-aaaa-000000000001"
	aliceDID    = "aaaaaaaa-aaaa-aaaa-aaaa-000000000002"
	bobUID      = "bbbbbbbb-bbbb-bbbb-bbbb-000000000001"
	bobDID      = "bbbbbbbb-bbbb-bbbb-bbbb-000000000002"
	parentMsgID = "cccccccc-cccc-cccc-cccc-000000000001"
)

// ----- tests -----

func TestReactions_SetAndGet(t *testing.T) {
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	insertMessage(t, db, parentMsgID, aliceUID, bobUID, clk.t)

	env := buildReactionEnvelope(aliceUID, aliceDID, bobUID, bobDID, parentMsgID, make([]byte, 32))

	res, err := svc.Put(ctx, reactions.PutRequest{
		MessageID:     parentMsgID,
		EnvelopeBytes: env,
		SentAt:        clk.t - 50,
		SessionUserID: aliceUID,
	})
	require.NoError(t, err)
	assert.NotEmpty(t, res.ID, "canonical reaction UUID must be non-empty")
	assert.Equal(t, clk.t, res.ReceivedAt)
}

func TestReactions_Idempotent_SameID(t *testing.T) {
	// Two PUT calls from the same sender to the same message must return the
	// same canonical id (UPSERT overwrites envelope, pk stays fixed).
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	insertMessage(t, db, parentMsgID, aliceUID, bobUID, clk.t)

	env := buildReactionEnvelope(aliceUID, aliceDID, bobUID, bobDID, parentMsgID, make([]byte, 32))

	res1, err := svc.Put(ctx, reactions.PutRequest{
		MessageID:     parentMsgID,
		EnvelopeBytes: env,
		SentAt:        clk.t - 50,
		SessionUserID: aliceUID,
	})
	require.NoError(t, err)

	// Second PUT (e.g. emoji change) — same sender / same message.
	res2, err := svc.Put(ctx, reactions.PutRequest{
		MessageID:     parentMsgID,
		EnvelopeBytes: env,
		SentAt:        clk.t - 10,
		SessionUserID: aliceUID,
	})
	require.NoError(t, err)
	assert.Equal(t, res1.ID, res2.ID, "canonical id must not change on UPSERT")
}

func TestReactions_ParentPurged_ErrGone(t *testing.T) {
	// PUT against a non-existent message_id → ErrParentPurged.
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	// Intentionally do NOT insert a messages row.

	env := buildReactionEnvelope(aliceUID, aliceDID, bobUID, bobDID, parentMsgID, make([]byte, 32))

	_, err := svc.Put(ctx, reactions.PutRequest{
		MessageID:     parentMsgID,
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: aliceUID,
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, reactions.ErrParentPurged)
}

func TestReactions_MessageIDBindingMismatch_Rejected(t *testing.T) {
	// Round-48: the SIGNED message id in the envelope must equal the parent id
	// on the path. A mismatch must be rejected — otherwise the sender gets 200
	// while the recipient (which binds on the signed id) silently drops it.
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	insertMessage(t, db, parentMsgID, aliceUID, bobUID, clk.t)

	// Envelope signed for a DIFFERENT message id than the path names.
	env := buildReactionEnvelope(aliceUID, aliceDID, bobUID, bobDID,
		"dddddddd-dddd-dddd-dddd-000000000099", make([]byte, 32))

	_, err := svc.Put(ctx, reactions.PutRequest{
		MessageID:     parentMsgID, // path id ≠ envelope's signed id
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: aliceUID,
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, reactions.ErrNotAuthorized)

	// And nothing was stored.
	since, err := svc.Since(ctx, reactions.SinceRequest{
		RecipientUserID: bobUID, SinceReceivedAt: 0, Limit: 100,
	})
	require.NoError(t, err)
	assert.Empty(t, since.Reactions, "a mismatched-binding reaction must not be stored")
}

func TestReactions_NotAuthorized(t *testing.T) {
	// Session user must match envelope.sender_user_id.
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	insertMessage(t, db, parentMsgID, aliceUID, bobUID, clk.t)

	// Envelope claims alice as sender but bob's session token is used.
	env := buildReactionEnvelope(aliceUID, aliceDID, bobUID, bobDID, parentMsgID, make([]byte, 32))

	_, err := svc.Put(ctx, reactions.PutRequest{
		MessageID:     parentMsgID,
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: bobUID, // mismatch
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, reactions.ErrNotAuthorized)
}

func TestReactions_Outsider_CannotReactToOthersConversation(t *testing.T) {
	// Round-16: an authenticated NON-participant who learns a message UUID
	// must not be able to inject a reaction into that conversation, even
	// though the envelope is validly signed by its own author.
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	const eveUID = "eeeeeeee-eeee-eeee-eeee-000000000001"
	const eveDID = "eeeeeeee-eeee-eeee-eeee-000000000002"
	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	insertUser(t, db, eveUID, eveDID, clk.t)
	insertMessage(t, db, parentMsgID, aliceUID, bobUID, clk.t) // alice <-> bob

	// Eve signs her own reaction (sender=eve) to bob on alice&bob's message.
	env := buildReactionEnvelope(eveUID, eveDID, bobUID, bobDID, parentMsgID, make([]byte, 32))

	_, err := svc.Put(ctx, reactions.PutRequest{
		MessageID:       parentMsgID,
		EnvelopeBytes:   env,
		SentAt:          clk.t,
		SessionUserID:   eveUID,
		SessionDeviceID: eveDID,
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, reactions.ErrNotAuthorized)
}

func TestReactions_MismatchedRecipient_Rejected(t *testing.T) {
	// A participant (alice) reacting but naming a recipient who is NOT the
	// other participant must be rejected.
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	const eveUID = "eeeeeeee-eeee-eeee-eeee-000000000001"
	const eveDID = "eeeeeeee-eeee-eeee-eeee-000000000002"
	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	insertUser(t, db, eveUID, eveDID, clk.t)
	insertMessage(t, db, parentMsgID, aliceUID, bobUID, clk.t)

	// sender=alice (a participant) but recipient=eve (not the other party).
	env := buildReactionEnvelope(aliceUID, aliceDID, eveUID, eveDID, parentMsgID, make([]byte, 32))

	_, err := svc.Put(ctx, reactions.PutRequest{
		MessageID:       parentMsgID,
		EnvelopeBytes:   env,
		SentAt:          clk.t,
		SessionUserID:   aliceUID,
		SessionDeviceID: aliceDID,
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, reactions.ErrNotAuthorized)
}

// TestReactions_SameMillisecondUpdate_AdvancesCursor guards the round-28
// finding: an update keeps the same canonical id, so its received_at MUST
// strictly advance — otherwise a same-millisecond change/clear at the
// recipient's cursor boundary is excluded by /reactions/since and the
// offline recipient keeps a stale reaction.
func TestReactions_SameMillisecondUpdate_AdvancesCursor(t *testing.T) {
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	insertMessage(t, db, parentMsgID, aliceUID, bobUID, clk.t)
	env := buildReactionEnvelope(aliceUID, aliceDID, bobUID, bobDID, parentMsgID, make([]byte, 32))

	// First set at T — the recipient's cursor advances to (T, id).
	res1, err := svc.Put(ctx, reactions.PutRequest{
		MessageID: parentMsgID, EnvelopeBytes: env, SentAt: clk.t,
		SessionUserID: aliceUID, SessionDeviceID: aliceDID,
	})
	require.NoError(t, err)
	require.Equal(t, clk.t, res1.ReceivedAt)

	// Update at the SAME millisecond (clock unchanged). received_at must
	// strictly advance past the prior row.
	res2, err := svc.Put(ctx, reactions.PutRequest{
		MessageID: parentMsgID, EnvelopeBytes: env, SentAt: clk.t,
		SessionUserID: aliceUID, SessionDeviceID: aliceDID,
	})
	require.NoError(t, err)
	assert.Equal(t, res1.ID, res2.ID, "update preserves canonical id")
	assert.Equal(t, clk.t+1, res2.ReceivedAt, "same-ms update must advance received_at")

	// Catch-up from the recipient's prior cursor must return the update.
	page, err := svc.Since(ctx, reactions.SinceRequest{
		RecipientUserID: bobUID, SinceReceivedAt: clk.t, SinceID: res1.ID, Limit: 10,
	})
	require.NoError(t, err)
	require.Len(t, page.Reactions, 1, "same-ms update must not be skipped by the cursor")
	assert.Equal(t, res1.ID, page.Reactions[0].ID)
}

func TestReactions_EnvelopeMalformed(t *testing.T) {
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	insertMessage(t, db, parentMsgID, aliceUID, bobUID, clk.t)

	_, err := svc.Put(ctx, reactions.PutRequest{
		MessageID:     parentMsgID,
		EnvelopeBytes: []byte("too short"),
		SentAt:        clk.t,
		SessionUserID: aliceUID,
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, reactions.ErrEnvelopeMalformed)
}

func TestReactions_Since(t *testing.T) {
	// Insert 3 reactions and verify pagination cursor works.
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	insertMessage(t, db, parentMsgID, aliceUID, bobUID, clk.t)

	env := buildReactionEnvelope(aliceUID, aliceDID, bobUID, bobDID, parentMsgID, make([]byte, 32))

	for i := 0; i < 3; i++ {
		clk.t += 1
		_, err := svc.Put(ctx, reactions.PutRequest{
			MessageID:     parentMsgID,
			EnvelopeBytes: env,
			SentAt:        clk.t,
			SessionUserID: aliceUID,
		})
		require.NoError(t, err, "put reaction %d", i)
	}

	// Should return 1 item per page when limit=1.
	res1, err := svc.Since(ctx, reactions.SinceRequest{
		RecipientUserID: bobUID,
		SinceReceivedAt: 0,
		SinceID:         "00000000-0000-0000-0000-000000000000",
		Limit:           1,
	})
	require.NoError(t, err)
	require.Len(t, res1.Reactions, 1)
	require.NotNil(t, res1.NextCursor)

	// Advance cursor; should get 0 results (all 3 are the same sender/message,
	// so only 1 canonical row remains after UPSERT).
	res2, err := svc.Since(ctx, reactions.SinceRequest{
		RecipientUserID: bobUID,
		SinceReceivedAt: res1.NextCursor.ReceivedAt,
		SinceID:         res1.NextCursor.ID,
		Limit:           10,
	})
	require.NoError(t, err)
	assert.Empty(t, res2.Reactions, "no more reactions after cursor")
}

func TestReactions_Since_LimitCap(t *testing.T) {
	// Limit > 500 must be clamped to 500 without error.
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)

	res, err := svc.Since(ctx, reactions.SinceRequest{
		RecipientUserID: bobUID,
		SinceReceivedAt: 0,
		SinceID:         "00000000-0000-0000-0000-000000000000",
		Limit:           9999, // should be clamped
	})
	require.NoError(t, err)
	assert.Empty(t, res.Reactions)
}

// TestReactions_EnvelopeMalformedCTLen verifies that a reaction envelope with
// a ct_len field that makes total_len inconsistent is rejected.
func TestReactions_EnvelopeMalformedCTLen(t *testing.T) {
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	insertMessage(t, db, parentMsgID, aliceUID, bobUID, clk.t)

	// Build an otherwise-valid envelope but corrupt ct_len to lie about the
	// ciphertext size — total_len won't match 1217 + ct_len + 64.
	env := buildReactionEnvelope(aliceUID, aliceDID, bobUID, bobDID, parentMsgID, make([]byte, 32))
	// Set ct_len to a value that produces a total_len mismatch.
	binary.BigEndian.PutUint32(env[offCTLen:], 9999)

	_, err := svc.Put(ctx, reactions.PutRequest{
		MessageID:     parentMsgID,
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: aliceUID,
	})
	require.Error(t, err)
	assert.ErrorIs(t, err, reactions.ErrEnvelopeMalformed)
}

func TestReactions_Put_RotatedRecipientDevice_Returns403Typed(t *testing.T) {
	clk := &fixedClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := reactions.New(db, hub)
	ctx := context.Background()

	insertUser(t, db, aliceUID, aliceDID, clk.t)
	insertUser(t, db, bobUID, bobDID, clk.t)
	insertMessage(t, db, parentMsgID, bobUID, aliceUID, clk.t)

	// Bob re-enrolled: revoke the old device, register a new one.
	_, err := db.Exec(`UPDATE devices SET revoked_at = ? WHERE id = ?`, clk.t, bobDID)
	require.NoError(t, err)
	newBobDID := "bbbbbbbb-bbbb-bbbb-bbbb-000000000003"
	_, err = db.Exec(
		`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at)
		 VALUES (?, ?, randomblob(32), randomblob(1216), ?)`,
		newBobDID, bobUID, clk.t,
	)
	require.NoError(t, err)

	// Alice reacts with a stale envelope sealed for the OLD device.
	env := buildReactionEnvelope(aliceUID, aliceDID, bobUID, bobDID, parentMsgID, make([]byte, 32))
	_, err = svc.Put(ctx, reactions.PutRequest{
		MessageID:     parentMsgID,
		SessionUserID: aliceUID,
		EnvelopeBytes: env,
		SentAt:        clk.t,
	})
	require.Error(t, err)
	var rotated *messages.RecipientDeviceRotatedError
	require.True(t, errors.As(err, &rotated), "expected RecipientDeviceRotatedError, got %T: %v", err, err)
	assert.Equal(t, newBobDID, rotated.ActiveDeviceID)
}
