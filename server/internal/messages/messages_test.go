package messages_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/messages"
	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// advanceClock is a mutable test clock so we can advance time across calls.
type advanceClock struct{ t int64 }

func (c *advanceClock) NowMillis() int64 { return c.t }

func openDB(t *testing.T, clk storage.Clock) *storage.DB {
	t.Helper()
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), clk)
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// insertUser inserts a bare user row and one active device directly.
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

// uuidRaw parses a standard UUID string into a [16]byte.
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

func hexByte(hi, lo byte) byte {
	return (hexNibble(hi) << 4) | hexNibble(lo)
}

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

// buildEnvelopeFromRaw constructs a spec-compliant envelope from raw UUID bytes.
func buildEnvelopeFromRaw(
	version byte,
	senderUserID, senderDeviceID, recipientUserID, recipientDeviceID, messageID [16]byte,
	ct []byte,
) []byte {
	buf := make([]byte, 0, 1217+len(ct)+64)
	buf = append(buf, version)
	buf = append(buf, senderUserID[:]...)
	buf = append(buf, senderDeviceID[:]...)
	buf = append(buf, recipientUserID[:]...)
	buf = append(buf, recipientDeviceID[:]...)
	buf = append(buf, messageID[:]...)
	buf = append(buf, make([]byte, 32)...)   // eph_x25519_pub
	buf = append(buf, make([]byte, 1088)...) // ml_kem_ct
	buf = append(buf, make([]byte, 12)...)   // nonce
	ctLen := uint32(len(ct))
	buf = append(buf, byte(ctLen>>24), byte(ctLen>>16), byte(ctLen>>8), byte(ctLen))
	buf = append(buf, ct...)
	buf = append(buf, make([]byte, 64)...) // sender_sig
	return buf
}

// ----- ParseEnvelope tests -----

func TestParseEnvelope_HappyPath(t *testing.T) {
	sUID := uuidRaw("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
	sDID := uuidRaw("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
	rUID := uuidRaw("cccccccc-cccc-cccc-cccc-cccccccccccc")
	rDID := uuidRaw("dddddddd-dddd-dddd-dddd-dddddddddddd")
	mID := uuidRaw("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")

	env := buildEnvelopeFromRaw(0x01, sUID, sDID, rUID, rDID, mID, make([]byte, 64))
	parsed, err := messages.ParseEnvelope(env)
	require.NoError(t, err)
	assert.Equal(t, uint8(0x01), parsed.Version)
	assert.Equal(t, sUID[:], parsed.SenderUserID)
	assert.Equal(t, sDID[:], parsed.SenderDeviceID)
	assert.Equal(t, rUID[:], parsed.RecipientUserID)
	assert.Equal(t, rDID[:], parsed.RecipientDeviceID)
	assert.Equal(t, mID[:], parsed.MessageID)
}

func TestParseEnvelope_TooShort(t *testing.T) {
	_, err := messages.ParseEnvelope(make([]byte, 100))
	require.ErrorIs(t, err, messages.ErrEnvelopeMalformed)
}

func TestParseEnvelope_CTLenTooLarge(t *testing.T) {
	env := buildEnvelopeFromRaw(0x01,
		uuidRaw("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
		uuidRaw("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
		uuidRaw("cccccccc-cccc-cccc-cccc-cccccccccccc"),
		uuidRaw("dddddddd-dddd-dddd-dddd-dddddddddddd"),
		uuidRaw("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"),
		make([]byte, 64),
	)
	// ct_len = 65537 (MAX_CT_LEN+1)
	env[1213] = 0x00
	env[1214] = 0x01
	env[1215] = 0x00
	env[1216] = 0x01
	_, err := messages.ParseEnvelope(env)
	require.ErrorIs(t, err, messages.ErrEnvelopeMalformed)
}

func TestParseEnvelope_TotalLenMismatch(t *testing.T) {
	env := buildEnvelopeFromRaw(0x01,
		uuidRaw("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
		uuidRaw("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
		uuidRaw("cccccccc-cccc-cccc-cccc-cccccccccccc"),
		uuidRaw("dddddddd-dddd-dddd-dddd-dddddddddddd"),
		uuidRaw("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"),
		make([]byte, 64),
	)
	env = env[:len(env)-1] // trim one byte → total_len mismatch
	_, err := messages.ParseEnvelope(env)
	require.ErrorIs(t, err, messages.ErrEnvelopeMalformed)
}

func TestParseEnvelope_UnknownVersionAccepted(t *testing.T) {
	// version=0x02 must be accepted; routing offsets are version-stable.
	env := buildEnvelopeFromRaw(0x02,
		uuidRaw("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
		uuidRaw("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
		uuidRaw("cccccccc-cccc-cccc-cccc-cccccccccccc"),
		uuidRaw("dddddddd-dddd-dddd-dddd-dddddddddddd"),
		uuidRaw("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"),
		make([]byte, 32),
	)
	parsed, err := messages.ParseEnvelope(env)
	require.NoError(t, err)
	assert.Equal(t, uint8(0x02), parsed.Version)
}

// ----- Service.Post tests -----

func TestService_PostAndPendingRoundtrip(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))

	ctx := context.Background()
	res, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t - 100,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)
	assert.Equal(t, msgID, res.ID)
	assert.Equal(t, clk.t, res.ReceivedAt)
	assert.Equal(t, clk.t-100, res.SentAt)

	pending, err := svc.Pending(ctx, messages.PendingRequest{
		RecipientUserID: rUserID,
		Limit:           100,
	})
	require.NoError(t, err)
	require.Len(t, pending.Messages, 1)
	assert.Equal(t, msgID, pending.Messages[0].ID)
	assert.Equal(t, sUserID, pending.Messages[0].SenderUserID)
	require.NotNil(t, pending.NextCursor)
	assert.Equal(t, msgID, pending.NextCursor.ID)
}

func TestService_PostIdempotent(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	req := messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t - 100,
		SessionUserID: sUserID,
	}
	res1, err := svc.Post(ctx, req)
	require.NoError(t, err)

	res2, err := svc.Post(ctx, req)
	require.NoError(t, err)
	assert.Equal(t, res1.ID, res2.ID)
	assert.Equal(t, res1.ReceivedAt, res2.ReceivedAt)
}

func TestService_PostAfterPurge_Returns410(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	req := messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t - 100,
		SessionUserID: sUserID,
	}
	_, err := svc.Post(ctx, req)
	require.NoError(t, err)

	// Advance past expiry and purge.
	clk.t += 31 * 24 * 60 * 60 * 1000
	n, err := svc.RunPurgeOnce(ctx)
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	// Resend same message_id → 410.
	_, err = svc.Post(ctx, req)
	require.ErrorIs(t, err, messages.ErrMessageExpired)
}

// TestService_PostAfterPurge_ForeignSenderNotAuthorized covers the round-45
// finding: the message_acks (410) path must be participant-bound. A user who
// learns a PURGED message UUID must not be able to distinguish a real historical
// message (410) from a non-existent id by re-posting it under their own envelope
// — that would leak cross-conversation metadata.
func TestService_PostAfterPurge_ForeignSenderNotAuthorized(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		// Attacker who learned the purged message UUID.
		aUserID = "ffffffff-ffff-ffff-ffff-ffffffffffff"
		aDev    = "11111111-1111-1111-1111-111111111111"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)
	insertUser(t, db, aUserID, aDev, clk.t)
	ctx := context.Background()

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	_, err := svc.Post(ctx, messages.PostRequest{EnvelopeBytes: env, SentAt: clk.t - 100, SessionUserID: sUserID})
	require.NoError(t, err)

	clk.t += 31 * 24 * 60 * 60 * 1000
	_, err = svc.RunPurgeOnce(ctx)
	require.NoError(t, err)

	// Attacker reuses the purged msgID under their OWN envelope (authorized as
	// their own sender, to a recipient of their choosing). The ack row belongs
	// to sUser→rUser, so this must be rejected as not-authorized — NOT 410,
	// which would confirm the id once existed.
	envForge := buildEnvelopeFromRaw(0x01, uuidRaw(aUserID), uuidRaw(aDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	_, err = svc.Post(ctx, messages.PostRequest{EnvelopeBytes: envForge, SentAt: clk.t, SessionUserID: aUserID})
	require.ErrorIs(t, err, messages.ErrNotAuthorized)
	require.NotErrorIs(t, err, messages.ErrMessageExpired,
		"a foreign sender must not learn the id was a real (purged) message")
}

func TestService_PostSenderMismatch_Returns403(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
		other   = "ffffffff-ffff-ffff-ffff-ffffffffffff"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: other, // mismatch
	})
	require.ErrorIs(t, err, messages.ErrNotAuthorized)
}

func TestService_PostRecipientRevoked(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)
	_, err := db.Exec(`UPDATE users SET revoked_at = ? WHERE id = ?`, clk.t, rUserID)
	require.NoError(t, err)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	_, err = svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: sUserID,
	})
	require.ErrorIs(t, err, messages.ErrRecipientRevoked)
}

func TestService_PostRecipientDeviceRotated(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		rDevNew = "11111111-1111-1111-1111-111111111111"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)
	_, err := db.Exec(`UPDATE devices SET revoked_at = ? WHERE id = ?`, clk.t, rDev)
	require.NoError(t, err)
	_, err = db.Exec(
		`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES (?, ?, randomblob(32), randomblob(1216), ?)`,
		rDevNew, rUserID, clk.t,
	)
	require.NoError(t, err)

	// Old device ID in envelope — expect typed error with the new active device.
	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	_, err = svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: sUserID,
	})
	var rotErr *messages.RecipientDeviceRotatedError
	require.True(t, errors.As(err, &rotErr), "expected RecipientDeviceRotatedError, got %v", err)
	assert.Equal(t, rDevNew, rotErr.ActiveDeviceID)
}

// TestService_PostReenrollRetryIsImmutableEcho documents the message
// immutability contract: a committed message_id is never rewritten. If the
// recipient re-enrolls after a message was spooled and the sender retries the
// same id (even re-sealed for the new device), the server echoes idempotently
// and leaves the stored ciphertext untouched. Ciphertext sealed for a revoked
// device is simply unreadable by the new device — an inherent property of E2EE
// re-enrollment; the sender resends as a NEW message if needed.
func TestService_PostReenrollRetryIsImmutableEcho(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		rDevNew = "11111111-1111-1111-1111-111111111111"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)
	ctx := context.Background()

	envOld := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	res1, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: envOld, SentAt: clk.t - 100, SessionUserID: sUserID,
	})
	require.NoError(t, err)

	// Recipient re-enrolls.
	_, err = db.Exec(`UPDATE devices SET revoked_at = ? WHERE id = ?`, clk.t, rDev)
	require.NoError(t, err)
	_, err = db.Exec(
		`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES (?, ?, randomblob(32), randomblob(1216), ?)`,
		rDevNew, rUserID, clk.t,
	)
	require.NoError(t, err)

	// Retry the same id re-sealed for the new device → idempotent echo, no rewrite.
	envNew := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDevNew), uuidRaw(msgID), bytes.Repeat([]byte{0xAB}, 64))
	res2, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: envNew, SentAt: clk.t, SessionUserID: sUserID,
	})
	require.NoError(t, err)
	assert.Equal(t, res1.ReceivedAt, res2.ReceivedAt, "echo returns the original received_at")
	assert.Equal(t, res1.SentAt, res2.SentAt, "echo returns the original sent_at")

	var stored []byte
	require.NoError(t, db.QueryRow(`SELECT envelope FROM messages WHERE id = ?`, msgID).Scan(&stored))
	assert.True(t, bytes.Equal(envOld, stored), "a committed message's envelope is immutable")
}

// TestService_PostDoesNotRewriteDeliveredMessageAfterRotation asserts a
// delivered message is immutable: a sender re-POSTing a DIFFERENT envelope after
// the recipient rotates devices gets an idempotent echo, never a rewrite.
func TestService_PostDoesNotRewriteDeliveredMessageAfterRotation(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		rDevNew = "11111111-1111-1111-1111-111111111111"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)
	ctx := context.Background()

	envOld := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: envOld, SentAt: clk.t - 100, SessionUserID: sUserID,
	})
	require.NoError(t, err)

	// Recipient receives + ACKs it on the original device.
	require.NoError(t, svc.Ack(ctx, messages.AckRequest{
		MessageID: msgID, Kind: "delivered", SessionUserID: rUserID,
	}))

	// Recipient re-enrolls.
	_, err = db.Exec(`UPDATE devices SET revoked_at = ? WHERE id = ?`, clk.t, rDev)
	require.NoError(t, err)
	_, err = db.Exec(
		`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES (?, ?, randomblob(32), randomblob(1216), ?)`,
		rDevNew, rUserID, clk.t,
	)
	require.NoError(t, err)

	// Sender re-POSTs a DIFFERENT envelope for the new device under the same id.
	envNew := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDevNew), uuidRaw(msgID), bytes.Repeat([]byte{0xAB}, 64))
	_, err = svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: envNew, SentAt: clk.t, SessionUserID: sUserID,
	})
	require.NoError(t, err, "an already-delivered message must echo idempotently, not error")

	// The stored envelope must be UNCHANGED — the delivered message is immutable.
	var stored []byte
	require.NoError(t, db.QueryRow(`SELECT envelope FROM messages WHERE id = ?`, msgID).Scan(&stored))
	assert.True(t, bytes.Equal(envOld, stored),
		"a delivered message's envelope must not be rewritten by a re-enroll retry")
}

// TestService_PostDoesNotRewriteAfterFetchAndRotation: a committed message is
// immutable. Even a message the recipient already FETCHED via /pending (but
// never ack'd) must not be rewritten by a later same-id re-POST after the
// recipient re-enrolls — a duplicate message_id is always an idempotent echo,
// never an in-place rewrite.
func TestService_PostDoesNotRewriteAfterFetchAndRotation(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		rDevNew = "11111111-1111-1111-1111-111111111111"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)
	ctx := context.Background()

	envOld := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: envOld, SentAt: clk.t - 100, SessionUserID: sUserID,
	})
	require.NoError(t, err)

	// Recipient FETCHES it (catch-up) — this exposes the row — but the
	// delivered ack is LOST (never sent to the server).
	pend, err := svc.Pending(ctx, messages.PendingRequest{RecipientUserID: rUserID, Limit: 100})
	require.NoError(t, err)
	require.Len(t, pend.Messages, 1)
	// NO Ack call here — simulating the transient ack failure.

	// Recipient re-enrolls.
	_, err = db.Exec(`UPDATE devices SET revoked_at = ? WHERE id = ?`, clk.t, rDev)
	require.NoError(t, err)
	_, err = db.Exec(
		`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at) VALUES (?, ?, randomblob(32), randomblob(1216), ?)`,
		rDevNew, rUserID, clk.t,
	)
	require.NoError(t, err)

	// Sender retries the same id with a DIFFERENT envelope for the new device.
	envNew := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDevNew), uuidRaw(msgID), bytes.Repeat([]byte{0xAB}, 64))
	_, err = svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: envNew, SentAt: clk.t, SessionUserID: sUserID,
	})
	require.NoError(t, err, "an already-exposed message must echo idempotently, not error")

	// The stored envelope must be UNCHANGED — exposure froze it.
	var stored []byte
	require.NoError(t, db.QueryRow(`SELECT envelope FROM messages WHERE id = ?`, msgID).Scan(&stored))
	assert.True(t, bytes.Equal(envOld, stored),
		"a message already returned by /pending must not be rewritten by a re-enroll retry")
}

// TestService_PostCannotHijackForeignMessageID covers the round-31 finding:
// a message_id is a stable retry key only for its OWN conversation. A user who
// learns another conversation's message UUID must not be able to reuse it under
// their own (authorized-sender) envelope to overwrite the stored row or fan an
// injected envelope at a live recipient.
func TestService_PostCannotHijackForeignMessageID(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		// Original conversation: bob -> alice.
		bobUID   = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		bobDev   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		aliceUID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		aliceDev = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		// Attacker reuses the same message_id to inject at carol.
		carolUID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
		carolDev = "11111111-1111-1111-1111-111111111111"
		msgID    = "22222222-2222-2222-2222-222222222222"
	)
	insertUser(t, db, bobUID, bobDev, clk.t)
	insertUser(t, db, aliceUID, aliceDev, clk.t)
	insertUser(t, db, carolUID, carolDev, clk.t)
	ctx := context.Background()

	// Bob legitimately sends to alice under msgID.
	envOrig := buildEnvelopeFromRaw(0x01, uuidRaw(bobUID), uuidRaw(bobDev), uuidRaw(aliceUID), uuidRaw(aliceDev), uuidRaw(msgID), make([]byte, 64))
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: envOrig,
		SentAt:        clk.t - 100,
		SessionUserID: bobUID,
	})
	require.NoError(t, err)

	// Alice (the original recipient, who knows msgID) reuses it as the SENDER
	// of a forged envelope aimed at carol. She is authorized for her own
	// envelope, but the stored row belongs to bob->alice.
	envInject := buildEnvelopeFromRaw(0x01, uuidRaw(aliceUID), uuidRaw(aliceDev), uuidRaw(carolUID), uuidRaw(carolDev), uuidRaw(msgID), bytes.Repeat([]byte{0xCC}, 64))
	_, err = svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: envInject,
		SentAt:        clk.t,
		SessionUserID: aliceUID,
	})
	require.ErrorIs(t, err, messages.ErrNotAuthorized,
		"reusing a foreign conversation's message_id must be rejected")

	// The original row's envelope is untouched, and carol got nothing.
	bobPending, err := svc.Pending(ctx, messages.PendingRequest{RecipientUserID: aliceUID, Limit: 100})
	require.NoError(t, err)
	require.Len(t, bobPending.Messages, 1)
	assert.True(t, bytes.Equal(envOrig, bobPending.Messages[0].Envelope),
		"the original stored envelope must be unchanged")
	carolPending, err := svc.Pending(ctx, messages.PendingRequest{RecipientUserID: carolUID, Limit: 100})
	require.NoError(t, err)
	assert.Empty(t, carolPending.Messages, "no injected envelope may reach carol")
}

// ----- Pending cursor pagination -----

func TestService_PendingCursorPagination(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	msgIDs := []string{
		"11111111-1111-1111-1111-111111111111",
		"22222222-2222-2222-2222-222222222222",
		"33333333-3333-3333-3333-333333333333",
		"44444444-4444-4444-4444-444444444444",
		"55555555-5555-5555-5555-555555555555",
	}
	ctx := context.Background()
	for i, id := range msgIDs {
		clk.t = 1_700_000_000_000 + int64(i)*1000
		env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(id), make([]byte, 64))
		_, err := svc.Post(ctx, messages.PostRequest{
			EnvelopeBytes: env,
			SentAt:        clk.t,
			SessionUserID: sUserID,
		})
		require.NoError(t, err)
	}

	page1, err := svc.Pending(ctx, messages.PendingRequest{RecipientUserID: rUserID, Limit: 2})
	require.NoError(t, err)
	require.Len(t, page1.Messages, 2)
	assert.Equal(t, msgIDs[0], page1.Messages[0].ID)
	assert.Equal(t, msgIDs[1], page1.Messages[1].ID)
	require.NotNil(t, page1.NextCursor)

	page2, err := svc.Pending(ctx, messages.PendingRequest{
		RecipientUserID: rUserID,
		Limit:           2,
		SinceReceivedAt: page1.NextCursor.ReceivedAt,
		SinceID:         page1.NextCursor.ID,
	})
	require.NoError(t, err)
	require.Len(t, page2.Messages, 2)
	assert.Equal(t, msgIDs[2], page2.Messages[0].ID)
	assert.Equal(t, msgIDs[3], page2.Messages[1].ID)

	page3, err := svc.Pending(ctx, messages.PendingRequest{
		RecipientUserID: rUserID,
		Limit:           2,
		SinceReceivedAt: page2.NextCursor.ReceivedAt,
		SinceID:         page2.NextCursor.ID,
	})
	require.NoError(t, err)
	require.Len(t, page3.Messages, 1)
	assert.Equal(t, msgIDs[4], page3.Messages[0].ID)
	require.NotNil(t, page3.NextCursor)
}

// ----- Ack tests -----

func TestService_AckDelivered(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t - 100,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)

	sess := &ws.Session{UserID: sUserID, DeviceID: sDev, Out: make(chan []byte, 4)}
	hub.Register(sess)

	err = svc.Ack(ctx, messages.AckRequest{
		MessageID:     msgID,
		Kind:          "delivered",
		SessionUserID: rUserID,
	})
	require.NoError(t, err)

	select {
	case body := <-sess.Out:
		var ev map[string]any
		require.NoError(t, json.Unmarshal(body, &ev))
		assert.Equal(t, "message_delivered", ev["type"])
		assert.Equal(t, msgID, ev["message_id"])
	default:
		t.Fatal("expected WS event to sender")
	}

	status, err := svc.Status(ctx, messages.StatusRequest{
		MessageID:     msgID,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)
	assert.Equal(t, "delivered", status)
}

func TestService_AckRead(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t - 100,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)

	sess := &ws.Session{UserID: sUserID, DeviceID: sDev, Out: make(chan []byte, 4)}
	hub.Register(sess)

	err = svc.Ack(ctx, messages.AckRequest{
		MessageID:     msgID,
		Kind:          "read",
		SessionUserID: rUserID,
	})
	require.NoError(t, err)

	select {
	case body := <-sess.Out:
		var ev map[string]any
		require.NoError(t, json.Unmarshal(body, &ev))
		assert.Equal(t, "message_read", ev["type"])
		assert.Equal(t, msgID, ev["message_id"])
	default:
		t.Fatal("expected WS event")
	}

	status, err := svc.Status(ctx, messages.StatusRequest{
		MessageID:     msgID,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)
	assert.Equal(t, "read", status)
}

func TestService_AckBadKind(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	ctx := context.Background()
	err := svc.Ack(ctx, messages.AckRequest{
		MessageID:     "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
		Kind:          "unknown",
		SessionUserID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
	})
	require.ErrorIs(t, err, messages.ErrInvalidAckKind)
}

func TestService_AckNotFound(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	ctx := context.Background()
	err := svc.Ack(ctx, messages.AckRequest{
		MessageID:     "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
		Kind:          "delivered",
		SessionUserID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
	})
	require.ErrorIs(t, err, messages.ErrNotFound)
}

func TestService_AckNotAuthorized(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
		other   = "ffffffff-ffff-ffff-ffff-ffffffffffff"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)

	err = svc.Ack(ctx, messages.AckRequest{
		MessageID:     msgID,
		Kind:          "delivered",
		SessionUserID: other, // neither sender nor recipient
	})
	require.ErrorIs(t, err, messages.ErrNotAuthorized)
}

// ----- Late ack (after purge) -----

func TestService_AckAfterPurge_LateAck(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)

	clk.t += 31 * 24 * 60 * 60 * 1000
	n, err := svc.RunPurgeOnce(ctx)
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	// After purge, only message_acks row exists. Late ack must succeed.
	err = svc.Ack(ctx, messages.AckRequest{
		MessageID:     msgID,
		Kind:          "delivered",
		SessionUserID: rUserID,
	})
	require.NoError(t, err)

	// delivered_at overrides expired → status is "delivered".
	status, err := svc.Status(ctx, messages.StatusRequest{
		MessageID:     msgID,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)
	assert.Equal(t, "delivered", status)
}

// ----- Status tests -----

func TestService_StatusGoneForUnknownMessage(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	ctx := context.Background()
	status, err := svc.Status(ctx, messages.StatusRequest{
		MessageID:     "ffffffff-ffff-ffff-ffff-ffffffffffff",
		SessionUserID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
	})
	require.NoError(t, err)
	assert.Equal(t, "gone", status)
}

func TestService_StatusForbiddenForNonSender(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
		other   = "ffffffff-ffff-ffff-ffff-ffffffffffff"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)

	_, err = svc.Status(ctx, messages.StatusRequest{
		MessageID:     msgID,
		SessionUserID: other, // not sender
	})
	require.ErrorIs(t, err, messages.ErrNotAuthorized)
}

func TestService_StatusPrecedence(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)

	// Purge → expired.
	clk.t += 31 * 24 * 60 * 60 * 1000
	_, err = svc.RunPurgeOnce(ctx)
	require.NoError(t, err)

	status, err := svc.Status(ctx, messages.StatusRequest{MessageID: msgID, SessionUserID: sUserID})
	require.NoError(t, err)
	assert.Equal(t, "expired", status)

	// Late-ack delivered.
	err = svc.Ack(ctx, messages.AckRequest{MessageID: msgID, Kind: "delivered", SessionUserID: rUserID})
	require.NoError(t, err)
	status, err = svc.Status(ctx, messages.StatusRequest{MessageID: msgID, SessionUserID: sUserID})
	require.NoError(t, err)
	assert.Equal(t, "delivered", status)

	// Late-ack read.
	err = svc.Ack(ctx, messages.AckRequest{MessageID: msgID, Kind: "read", SessionUserID: rUserID})
	require.NoError(t, err)
	status, err = svc.Status(ctx, messages.StatusRequest{MessageID: msgID, SessionUserID: sUserID})
	require.NoError(t, err)
	assert.Equal(t, "read", status)
}

// ----- Purge -----

func TestService_PurgePreservesAckThenDeletes(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)

	err = svc.Ack(ctx, messages.AckRequest{MessageID: msgID, Kind: "delivered", SessionUserID: rUserID})
	require.NoError(t, err)

	clk.t += 31 * 24 * 60 * 60 * 1000
	n, err := svc.RunPurgeOnce(ctx)
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	var count int
	require.NoError(t, db.QueryRow(`SELECT COUNT(*) FROM messages WHERE id = ?`, msgID).Scan(&count))
	assert.Equal(t, 0, count)

	var deliveredAt, expiredAt *int64
	require.NoError(t, db.QueryRow(
		`SELECT delivered_at, expired_at FROM message_acks WHERE message_id = ?`, msgID,
	).Scan(&deliveredAt, &expiredAt))
	assert.NotNil(t, deliveredAt, "delivered_at must be preserved by purge")
	assert.NotNil(t, expiredAt, "expired_at must be set by purge")
}

// ----- Unknown version round-trip (delivery-handle invariant) -----

func TestService_UnknownVersionEnvelope_RoundtripsAndAckable(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	ct := make([]byte, 32)
	env := buildEnvelopeFromRaw(0x02, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), ct)

	ctx := context.Background()
	res, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: sUserID,
	})
	require.NoError(t, err, "unknown version must be accepted")
	assert.Equal(t, msgID, res.ID)

	pending, err := svc.Pending(ctx, messages.PendingRequest{RecipientUserID: rUserID, Limit: 10})
	require.NoError(t, err)
	require.Len(t, pending.Messages, 1)
	assert.Equal(t, env, pending.Messages[0].Envelope, "envelope bytes must round-trip")

	sess := &ws.Session{UserID: sUserID, DeviceID: sDev, Out: make(chan []byte, 4)}
	hub.Register(sess)
	err = svc.Ack(ctx, messages.AckRequest{MessageID: msgID, Kind: "delivered", SessionUserID: rUserID})
	require.NoError(t, err)

	status, err := svc.Status(ctx, messages.StatusRequest{MessageID: msgID, SessionUserID: sUserID})
	require.NoError(t, err)
	assert.Equal(t, "delivered", status)
}

// ----- WS event shape on post -----

func TestService_WSEventOnPost(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	rSess := &ws.Session{UserID: rUserID, DeviceID: rDev, Out: make(chan []byte, 4)}
	hub.Register(rSess)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	_, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t - 50,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)

	select {
	case body := <-rSess.Out:
		var ev map[string]any
		require.NoError(t, json.Unmarshal(body, &ev))
		assert.Equal(t, "message", ev["type"])
		assert.Equal(t, msgID, ev["id"])
		assert.Equal(t, sUserID, ev["from"])
		assert.Equal(t, rUserID, ev["to"])
	default:
		t.Fatal("no WS event delivered to recipient")
	}
}

// ----- C1: nonce purge -----

func TestService_RunPurgeOnce_SweepsExpiredAuthNonces(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	// The auth_nonces table has a NOT NULL FK to devices, so we need a real device row.
	const (
		userID   = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		deviceID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
	)
	insertUser(t, db, userID, deviceID, clk.t)

	ctx := context.Background()
	now := clk.t

	// Row 1: expires_at well past the 1h grace — must be deleted.
	_, err := db.ExecContext(ctx,
		`INSERT INTO auth_nonces (nonce, device_id, issued_at, expires_at) VALUES (randomblob(32), ?, ?, ?)`,
		deviceID, now-7_200_000, now-3_700_000,
	)
	require.NoError(t, err)

	// Row 2: expires_at within the 1h grace — must NOT be deleted.
	_, err = db.ExecContext(ctx,
		`INSERT INTO auth_nonces (nonce, device_id, issued_at, expires_at) VALUES (randomblob(32), ?, ?, ?)`,
		deviceID, now-120_000, now-1_000,
	)
	require.NoError(t, err)

	_, err = svc.RunPurgeOnce(ctx)
	require.NoError(t, err)

	var count int
	require.NoError(t, db.QueryRowContext(ctx, `SELECT COUNT(*) FROM auth_nonces`).Scan(&count))
	assert.Equal(t, 1, count, "only the nonce within the 1h grace should survive")
}

// ----- C3: idempotent resend must not re-fan-out -----

func TestService_PostIdempotent_DoesNotRefanout(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	rSess := &ws.Session{UserID: rUserID, DeviceID: rDev, Out: make(chan []byte, 8)}
	hub.Register(rSess)

	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	ctx := context.Background()
	req := messages.PostRequest{EnvelopeBytes: env, SentAt: clk.t - 100, SessionUserID: sUserID}

	// First post — must deliver exactly one WS event.
	res1, err := svc.Post(ctx, req)
	require.NoError(t, err)
	select {
	case <-rSess.Out:
		// expected
	default:
		t.Fatal("expected WS event on first post")
	}
	// No second event queued.
	assert.Empty(t, rSess.Out)

	// Second post (idempotent) — chan must stay empty.
	res2, err := svc.Post(ctx, req)
	require.NoError(t, err)
	assert.Equal(t, res1.ID, res2.ID)
	assert.Equal(t, res1.ReceivedAt, res2.ReceivedAt)
	assert.Empty(t, rSess.Out, "idempotent resend must not emit a second WS event")
}

// ----- I2: WS event id == envelope.message_id for unknown-version envelope -----

func TestService_WSEventOnPost_UnknownVersionUsesWrapperId(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "12345678-1234-1234-1234-123456789012"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	rSess := &ws.Session{UserID: rUserID, DeviceID: rDev, Out: make(chan []byte, 4)}
	hub.Register(rSess)

	// version=0x02 envelope with a known message_id at offsets 65..80.
	env := buildEnvelopeFromRaw(0x02, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 32))
	ctx := context.Background()
	res, err := svc.Post(ctx, messages.PostRequest{
		EnvelopeBytes: env,
		SentAt:        clk.t,
		SessionUserID: sUserID,
	})
	require.NoError(t, err)
	assert.Equal(t, msgID, res.ID)

	select {
	case body := <-rSess.Out:
		var ev map[string]any
		require.NoError(t, json.Unmarshal(body, &ev))
		assert.Equal(t, msgID, ev["id"], "WS event id must equal envelope.message_id (delivery-handle invariant)")
	default:
		t.Fatal("no WS event delivered")
	}
}

// ----- I3: same-millisecond cursor collision -----

func TestService_PendingCursorPagination_SameMillisecond(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000} // frozen — all messages share the same received_at
	db := openDB(t, clk)
	hub := ws.NewHub()
	svc := messages.New(db, hub)

	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	// Three messages, all at the same millisecond. IDs are chosen to have a
	// deterministic lexicographic order: 111... < 222... < 333...
	msgIDs := []string{
		"11111111-1111-1111-1111-111111111111",
		"22222222-2222-2222-2222-222222222222",
		"33333333-3333-3333-3333-333333333333",
	}
	ctx := context.Background()
	for _, id := range msgIDs {
		env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(sDev), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(id), make([]byte, 64))
		_, err := svc.Post(ctx, messages.PostRequest{
			EnvelopeBytes: env,
			SentAt:        clk.t,
			SessionUserID: sUserID,
		})
		require.NoError(t, err)
	}

	// Page through with limit=1; the composite cursor (received_at, id) must
	// correctly skip already-seen rows even when received_at collides.
	var seen []string
	var cursor *messages.Cursor
	for i := 0; i < 3; i++ {
		req := messages.PendingRequest{RecipientUserID: rUserID, Limit: 1}
		if cursor != nil {
			req.SinceReceivedAt = cursor.ReceivedAt
			req.SinceID = cursor.ID
		}
		page, err := svc.Pending(ctx, req)
		require.NoError(t, err)
		require.Len(t, page.Messages, 1, "page %d must have exactly 1 message", i+1)
		seen = append(seen, page.Messages[0].ID)
		cursor = page.NextCursor
	}

	assert.Equal(t, msgIDs, seen, "all 3 messages must be returned in lexicographic id order")

	// One more page beyond the last message must be empty.
	req := messages.PendingRequest{RecipientUserID: rUserID, Limit: 1}
	if cursor != nil {
		req.SinceReceivedAt = cursor.ReceivedAt
		req.SinceID = cursor.ID
	}
	last, err := svc.Pending(ctx, req)
	require.NoError(t, err)
	assert.Empty(t, last.Messages, "no more messages after cursor exhaustion")
}

func TestService_PostSenderDeviceMismatch_Returns403(t *testing.T) {
	clk := &advanceClock{t: 1_700_000_000_000}
	db := openDB(t, clk)
	svc := messages.New(db, ws.NewHub())
	const (
		sUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		sDev    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		rUserID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
		rDev    = "dddddddd-dddd-dddd-dddd-dddddddddddd"
		msgID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
		forged  = "99999999-9999-9999-9999-999999999999"
	)
	insertUser(t, db, sUserID, sDev, clk.t)
	insertUser(t, db, rUserID, rDev, clk.t)

	// Envelope names the real sender USER but a forged (nonexistent)
	// sender DEVICE — must be rejected so a receiver can't get a message
	// whose signing key it can never resolve (wedging catch-up).
	env := buildEnvelopeFromRaw(0x01, uuidRaw(sUserID), uuidRaw(forged), uuidRaw(rUserID), uuidRaw(rDev), uuidRaw(msgID), make([]byte, 64))
	_, err := svc.Post(context.Background(), messages.PostRequest{
		EnvelopeBytes:   env,
		SentAt:          clk.t,
		SessionUserID:   sUserID,
		SessionDeviceID: sDev,
	})
	require.ErrorIs(t, err, messages.ErrNotAuthorized)
}
