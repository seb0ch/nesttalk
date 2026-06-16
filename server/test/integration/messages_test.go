// Integration tests for the message pipeline endpoints:
//   POST /api/v1/messages
//   GET  /api/v1/messages/pending
//   POST /api/v1/messages/{id}/ack
//   GET  /api/v1/messages/{id}/status
//
// Keep registerRoutes in sync with cmd/nesttalk-server/routes.go.
package integration_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/auth"
	"github.com/seb0ch/nesttalk/server/internal/control"
	"github.com/seb0ch/nesttalk/server/internal/messages"
)

// ----- envelope builder -----

func buildEnvelope(version byte, senderUserID, senderDeviceID, recipientUserID, recipientDeviceID, messageID string, ct []byte) []byte {
	sUID := msgUUIDRaw(senderUserID)
	sDID := msgUUIDRaw(senderDeviceID)
	rUID := msgUUIDRaw(recipientUserID)
	rDID := msgUUIDRaw(recipientDeviceID)
	mID := msgUUIDRaw(messageID)

	buf := make([]byte, 0, 1217+len(ct)+64)
	buf = append(buf, version)
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

func msgUUIDRaw(s string) [16]byte {
	var b [16]byte
	hex := make([]byte, 0, 32)
	for _, c := range s {
		if c == '-' {
			continue
		}
		hex = append(hex, byte(c))
	}
	for i := 0; i < 16 && i*2+1 < len(hex); i++ {
		b[i] = msgHexByte(hex[i*2], hex[i*2+1])
	}
	return b
}

func msgHexByte(hi, lo byte) byte { return (msgHexNib(hi) << 4) | msgHexNib(lo) }
func msgHexNib(c byte) byte {
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

// ----- http helpers -----

func postCode(t *testing.T, srv *httptest.Server, path string, body any, out any, bearer string) int {
	t.Helper()
	jsBody, err := json.Marshal(body)
	require.NoError(t, err)
	req, err := http.NewRequest("POST", srv.URL+path, bytes.NewReader(jsBody))
	require.NoError(t, err)
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if out != nil {
		_ = json.Unmarshal(b, out)
	}
	return resp.StatusCode
}

func getCode(t *testing.T, url string, out any, bearer string) int {
	t.Helper()
	req, err := http.NewRequest("GET", url, nil)
	require.NoError(t, err)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if out != nil {
		_ = json.Unmarshal(b, out)
	}
	return resp.StatusCode
}

// ----- enrollment helper -----

type enrolledUser struct {
	UserID   string
	DeviceID string
	Token    string
	Priv     ed25519.PrivateKey
}

func enrollAndConnect(t *testing.T, srv *httptest.Server, ctrl *control.Server, name string, reqID int) enrolledUser {
	t.Helper()
	ctx := context.Background()

	resp := ctrl.Dispatch(ctx, control.Request{
		ID:    reqID,
		CmdID: fmt.Sprintf("rpc-%d", reqID),
		Cmd:   "enroll_user",
		Args:  rawJSON(t, map[string]string{"name": name}),
	})
	require.True(t, resp.OK, resp.Error)
	var link struct{ Code string `json:"code"` }
	require.NoError(t, json.Unmarshal(resp.Result, &link))

	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	msgPub := make([]byte, auth.MessagePubKeyLen)
	_, _ = rand.Read(msgPub)

	var startResp struct{ Challenge string `json:"challenge"` }
	postJSON(t, srv, "/api/v1/auth/enroll/start", enrollStartReq{Code: link.Code}, &startResp, "")
	challenge, _ := base64.StdEncoding.DecodeString(startResp.Challenge)

	var complete enrollCompleteResp
	postJSON(t, srv, "/api/v1/auth/enroll/complete", enrollCompleteReq{
		Code:          link.Code,
		DevicePubkey:  base64.StdEncoding.EncodeToString(pub),
		MessagePubkey: base64.StdEncoding.EncodeToString(msgPub),
		Attestation:   base64.StdEncoding.EncodeToString(ed25519.Sign(priv, challenge)),
	}, &complete, "")

	var cc struct{ Nonce string `json:"nonce"` }
	postJSON(t, srv, "/api/v1/auth/connect/challenge", map[string]string{"device_id": complete.DeviceID}, &cc, "")
	nonce, _ := base64.StdEncoding.DecodeString(cc.Nonce)
	var sess struct{ SessionToken string `json:"session_token"` }
	postJSON(t, srv, "/api/v1/auth/connect/complete", map[string]any{
		"device_id":   complete.DeviceID,
		"nonce":       base64.StdEncoding.EncodeToString(nonce),
		"attestation": base64.StdEncoding.EncodeToString(ed25519.Sign(priv, nonce)),
	}, &sess, "")

	return enrolledUser{
		UserID:   complete.UserID,
		DeviceID: complete.DeviceID,
		Token:    sess.SessionToken,
		Priv:     priv,
	}
}

// ----- tests -----

func TestMessages_EndToEnd(t *testing.T) {
	srv, ctrl, _ := newStack(t)

	alice := enrollAndConnect(t, srv, ctrl, "alice", 1)
	bob := enrollAndConnect(t, srv, ctrl, "bob", 2)

	msgID := "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
	envBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID, msgID, make([]byte, 64))
	envB64 := base64.StdEncoding.EncodeToString(envBytes)

	// POST message (alice → bob).
	var postResp struct {
		ID         string `json:"id"`
		ReceivedAt int64  `json:"received_at"`
		SentAt     int64  `json:"sent_at"`
	}
	code := postCode(t, srv, "/api/v1/messages", map[string]any{
		"envelope": envB64,
		"sent_at":  int64(1_700_000_000_000 - 50),
	}, &postResp, alice.Token)
	require.Equal(t, 200, code)
	assert.Equal(t, msgID, postResp.ID)

	// Idempotent resend → 200, same received_at.
	var postResp2 struct {
		ID         string `json:"id"`
		ReceivedAt int64  `json:"received_at"`
	}
	code2 := postCode(t, srv, "/api/v1/messages", map[string]any{
		"envelope": envB64,
		"sent_at":  int64(1_700_000_000_000 - 50),
	}, &postResp2, alice.Token)
	assert.Equal(t, 200, code2)
	assert.Equal(t, postResp.ID, postResp2.ID)
	assert.Equal(t, postResp.ReceivedAt, postResp2.ReceivedAt)

	// Sender mismatch → 403.
	code403 := postCode(t, srv, "/api/v1/messages", map[string]any{
		"envelope": envB64,
		"sent_at":  int64(1_700_000_000_000),
	}, nil, bob.Token) // bob posting alice's envelope
	assert.Equal(t, 403, code403)

	// GET /messages/pending as bob.
	var pendingResp struct {
		Messages   []messages.PendingMessage `json:"messages"`
		NextCursor *messages.Cursor          `json:"next_cursor"`
	}
	codePending := getCode(t, srv.URL+"/api/v1/messages/pending?limit=10", &pendingResp, bob.Token)
	require.Equal(t, 200, codePending)
	require.Len(t, pendingResp.Messages, 1)
	assert.Equal(t, msgID, pendingResp.Messages[0].ID)

	// POST ack/delivered.
	codeAck := postCode(t, srv, "/api/v1/messages/"+msgID+"/ack",
		map[string]string{"kind": "delivered"}, nil, bob.Token)
	assert.Equal(t, 200, codeAck)

	// GET status as alice.
	var statusResp struct{ Status string `json:"status"` }
	codeStatus := getCode(t, srv.URL+"/api/v1/messages/"+msgID+"/status", &statusResp, alice.Token)
	require.Equal(t, 200, codeStatus)
	assert.Equal(t, "delivered", statusResp.Status)

	// Ack with unknown kind → 400.
	code400 := postCode(t, srv, "/api/v1/messages/"+msgID+"/ack",
		map[string]string{"kind": "bogus"}, nil, bob.Token)
	assert.Equal(t, 400, code400)

	// Status from non-sender → 403.
	code403b := getCode(t, srv.URL+"/api/v1/messages/"+msgID+"/status", nil, bob.Token)
	assert.Equal(t, 403, code403b)

	// Status for unknown message → 200 "gone".
	var goneResp struct{ Status string `json:"status"` }
	codeGone := getCode(t, srv.URL+"/api/v1/messages/ffffffff-ffff-ffff-ffff-ffffffffffff/status", &goneResp, alice.Token)
	require.Equal(t, 200, codeGone)
	assert.Equal(t, "gone", goneResp.Status)

	// Unknown-version (0x02) envelope round-trip — delivery-handle invariant.
	msgIDv2 := "12345678-1234-1234-1234-123456789012"
	envBytesV2 := buildEnvelope(0x02, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID, msgIDv2, make([]byte, 32))
	var postRespV2 struct{ ID string `json:"id"` }
	codeV2 := postCode(t, srv, "/api/v1/messages", map[string]any{
		"envelope": base64.StdEncoding.EncodeToString(envBytesV2),
		"sent_at":  int64(1_700_000_000_000),
	}, &postRespV2, alice.Token)
	require.Equal(t, 200, codeV2, "unknown version must be accepted")
	assert.Equal(t, msgIDv2, postRespV2.ID)

	codeAckV2 := postCode(t, srv, "/api/v1/messages/"+msgIDv2+"/ack",
		map[string]string{"kind": "delivered"}, nil, bob.Token)
	assert.Equal(t, 200, codeAckV2)

	var statusRespV2 struct{ Status string `json:"status"` }
	codeStatusV2 := getCode(t, srv.URL+"/api/v1/messages/"+msgIDv2+"/status", &statusRespV2, alice.Token)
	require.Equal(t, 200, codeStatusV2)
	assert.Equal(t, "delivered", statusRespV2.Status)
}

func TestMessages_PaginationCursor(t *testing.T) {
	srv, ctrl, _ := newStack(t)

	alice := enrollAndConnect(t, srv, ctrl, "alice", 1)
	bob := enrollAndConnect(t, srv, ctrl, "bob", 2)

	msgIDs := []string{
		"11111111-1111-1111-1111-111111111111",
		"22222222-2222-2222-2222-222222222222",
		"33333333-3333-3333-3333-333333333333",
		"44444444-4444-4444-4444-444444444444",
		"55555555-5555-5555-5555-555555555555",
	}
	for _, id := range msgIDs {
		envBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID, id, make([]byte, 64))
		code := postCode(t, srv, "/api/v1/messages", map[string]any{
			"envelope": base64.StdEncoding.EncodeToString(envBytes),
			"sent_at":  int64(1_700_000_000_000),
		}, nil, alice.Token)
		require.Equal(t, 200, code, "post msg %s", id)
	}

	// Page 1: limit=2.
	var page1 struct {
		Messages   []messages.PendingMessage `json:"messages"`
		NextCursor *messages.Cursor          `json:"next_cursor"`
	}
	code1 := getCode(t, srv.URL+"/api/v1/messages/pending?limit=2", &page1, bob.Token)
	require.Equal(t, 200, code1)
	require.Len(t, page1.Messages, 2)
	require.NotNil(t, page1.NextCursor)

	// Page 2.
	url2 := fmt.Sprintf("%s/api/v1/messages/pending?limit=2&since_received_at=%d&since_id=%s",
		srv.URL, page1.NextCursor.ReceivedAt, page1.NextCursor.ID)
	var page2 struct {
		Messages   []messages.PendingMessage `json:"messages"`
		NextCursor *messages.Cursor          `json:"next_cursor"`
	}
	code2 := getCode(t, url2, &page2, bob.Token)
	require.Equal(t, 200, code2)
	require.Len(t, page2.Messages, 2)
	require.NotNil(t, page2.NextCursor)

	// Page 3: last page.
	url3 := fmt.Sprintf("%s/api/v1/messages/pending?limit=2&since_received_at=%d&since_id=%s",
		srv.URL, page2.NextCursor.ReceivedAt, page2.NextCursor.ID)
	var page3 struct {
		Messages []messages.PendingMessage `json:"messages"`
	}
	code3 := getCode(t, url3, &page3, bob.Token)
	require.Equal(t, 200, code3)
	require.Len(t, page3.Messages, 1)
}

// ----- I1: recipient_device_rotated HTTP round-trip -----

// TestMessages_RecipientDeviceRotated_HTTP tests that POSTing a message with
// a stale recipient device_id returns 403 with the correct error body
// including the new active_recipient_device_id.
func TestMessages_RecipientDeviceRotated_HTTP(t *testing.T) {
	srv, ctrl, _ := newStack(t)

	alice := enrollAndConnect(t, srv, ctrl, "alice", 1)
	bob := enrollAndConnect(t, srv, ctrl, "bob", 2)

	// Alice builds an envelope addressed to bob's current (soon-to-be-old) device.
	msgID := "aaaaaaaa-aaaa-aaaa-aaaa-000000000001"
	envBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID, msgID, make([]byte, 32))

	// Bob re-enrolls the SAME user identity (enroll_existing_user) — this
	// creates a new device and revokes the prior one via the partial-unique index.
	ctx := context.Background()
	resp := ctrl.Dispatch(ctx, control.Request{
		ID:    3,
		CmdID: "rpc-3",
		Cmd:   "enroll_existing_user",
		Args:  rawJSON(t, map[string]string{"user_id": bob.UserID}),
	})
	require.True(t, resp.OK, resp.Error)
	var link struct{ Code string `json:"code"` }
	require.NoError(t, json.Unmarshal(resp.Result, &link))

	// Complete re-enrollment for bob.
	bobNew := completeEnroll(t, srv, link.Code, bob.UserID, 0)

	// Alice POSTs with the OLD device ID (bob.DeviceID) in the envelope → 403.
	var errResp struct {
		Error                   string `json:"error"`
		Reason                  string `json:"reason"`
		ActiveRecipientDeviceID string `json:"active_recipient_device_id"`
	}
	code := postCode(t, srv, "/api/v1/messages", map[string]any{
		"envelope": base64.StdEncoding.EncodeToString(envBytes),
		"sent_at":  int64(1_700_000_000_000),
	}, &errResp, alice.Token)

	require.Equal(t, 403, code)
	assert.Equal(t, "recipient_device_rotated", errResp.Error)
	assert.Equal(t, "recipient_device_rotated", errResp.Reason)
	assert.Equal(t, bobNew.DeviceID, errResp.ActiveRecipientDeviceID,
		"active_recipient_device_id must point to bob's new device")
}

// completeEnroll performs only the client-side enroll/complete steps
// (no connect handshake) and returns the new device ID.
func completeEnroll(t *testing.T, srv *httptest.Server, code, _ string, _ int) enrolledUser {
	t.Helper()
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	msgPub := make([]byte, auth.MessagePubKeyLen)
	_, _ = rand.Read(msgPub)

	var startResp struct{ Challenge string `json:"challenge"` }
	postJSON(t, srv, "/api/v1/auth/enroll/start", enrollStartReq{Code: code}, &startResp, "")
	challenge, _ := base64.StdEncoding.DecodeString(startResp.Challenge)

	var complete enrollCompleteResp
	postJSON(t, srv, "/api/v1/auth/enroll/complete", enrollCompleteReq{
		Code:          code,
		DevicePubkey:  base64.StdEncoding.EncodeToString(pub),
		MessagePubkey: base64.StdEncoding.EncodeToString(msgPub),
		Attestation:   base64.StdEncoding.EncodeToString(ed25519.Sign(priv, challenge)),
	}, &complete, "")

	var cc struct{ Nonce string `json:"nonce"` }
	postJSON(t, srv, "/api/v1/auth/connect/challenge", map[string]string{"device_id": complete.DeviceID}, &cc, "")
	nonce, _ := base64.StdEncoding.DecodeString(cc.Nonce)
	var sess struct{ SessionToken string `json:"session_token"` }
	postJSON(t, srv, "/api/v1/auth/connect/complete", map[string]any{
		"device_id":   complete.DeviceID,
		"nonce":       base64.StdEncoding.EncodeToString(nonce),
		"attestation": base64.StdEncoding.EncodeToString(ed25519.Sign(priv, nonce)),
	}, &sess, "")

	return enrolledUser{
		UserID:   complete.UserID,
		DeviceID: complete.DeviceID,
		Token:    sess.SessionToken,
		Priv:     priv,
	}
}

// ----- I4: integration-level proofs for purge/idempotent scenarios -----

// TestMessages_IdempotentResend_200ThenAfterPurge410 proves the HTTP layer
// correctly returns 200 on idempotent resend and 410 after the message is
// purged, using the full HTTP stack.
func TestMessages_IdempotentResend_200ThenAfterPurge410(t *testing.T) {
	srv, ctrl, db := newStack(t)

	alice := enrollAndConnect(t, srv, ctrl, "alice", 1)
	bob := enrollAndConnect(t, srv, ctrl, "bob", 2)

	msgID := "bbbbbbbb-bbbb-bbbb-bbbb-000000000001"
	envBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID, msgID, make([]byte, 32))
	envB64 := base64.StdEncoding.EncodeToString(envBytes)
	postBody := map[string]any{"envelope": envB64, "sent_at": int64(1_700_000_000_000)}

	// First POST → 200.
	var resp1 struct{ ID string `json:"id"` }
	code1 := postCode(t, srv, "/api/v1/messages", postBody, &resp1, alice.Token)
	require.Equal(t, 200, code1)
	assert.Equal(t, msgID, resp1.ID)

	// Idempotent resend → still 200, same id.
	var resp2 struct{ ID string `json:"id"` }
	code2 := postCode(t, srv, "/api/v1/messages", postBody, &resp2, alice.Token)
	require.Equal(t, 200, code2)
	assert.Equal(t, msgID, resp2.ID)

	// Simulate purge: write tombstone ack row then delete the message envelope,
	// as RunPurgeOnce would do.
	_, err := db.Exec(
		`INSERT INTO message_acks (message_id, sender_user_id, recipient_user_id, expired_at)
		 SELECT id, sender_user_id, recipient_user_id, 1 FROM messages WHERE id = ?
		 ON CONFLICT(message_id) DO UPDATE SET expired_at = COALESCE(message_acks.expired_at, excluded.expired_at)`,
		msgID,
	)
	require.NoError(t, err)
	_, err = db.Exec(`DELETE FROM messages WHERE id = ?`, msgID)
	require.NoError(t, err)

	// POST same envelope again after purge → 410.
	var errResp map[string]any
	code410 := postCode(t, srv, "/api/v1/messages", postBody, &errResp, alice.Token)
	assert.Equal(t, 410, code410, "re-POST after purge must return 410")
}

// TestMessages_LateAckAfterPurge proves the HTTP ack endpoint correctly
// handles Branch B (acks-only row) and the final status query returns "read".
func TestMessages_LateAckAfterPurge(t *testing.T) {
	srv, ctrl, db := newStack(t)

	alice := enrollAndConnect(t, srv, ctrl, "alice", 1)
	bob := enrollAndConnect(t, srv, ctrl, "bob", 2)

	msgID := "cccccccc-cccc-cccc-cccc-000000000001"
	envBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID, msgID, make([]byte, 32))
	envB64 := base64.StdEncoding.EncodeToString(envBytes)

	// Post the message.
	code := postCode(t, srv, "/api/v1/messages", map[string]any{
		"envelope": envB64,
		"sent_at":  int64(1_700_000_000_000),
	}, nil, alice.Token)
	require.Equal(t, 200, code)

	// Bob acks delivered first.
	codeAck1 := postCode(t, srv, "/api/v1/messages/"+msgID+"/ack",
		map[string]string{"kind": "delivered"}, nil, bob.Token)
	require.Equal(t, 200, codeAck1)

	// Manually purge the message envelope via raw SQL (simulates TTL expiry).
	_, err := db.Exec(
		`INSERT INTO message_acks (message_id, sender_user_id, recipient_user_id, expired_at)
		 SELECT id, sender_user_id, recipient_user_id, 1 FROM messages WHERE id = ?
		 ON CONFLICT(message_id) DO UPDATE SET expired_at = COALESCE(message_acks.expired_at, excluded.expired_at)`,
		msgID,
	)
	require.NoError(t, err)
	_, err = db.Exec(`DELETE FROM messages WHERE id = ?`, msgID)
	require.NoError(t, err)

	// Bob sends late "read" ack (Branch B: only message_acks row exists) → 200.
	codeAck2 := postCode(t, srv, "/api/v1/messages/"+msgID+"/ack",
		map[string]string{"kind": "read"}, nil, bob.Token)
	assert.Equal(t, 200, codeAck2, "late ack after purge must succeed (Branch B)")

	// Alice checks status → "read" (read beats delivered and expired).
	var statusResp struct{ Status string `json:"status"` }
	codeStatus := getCode(t, srv.URL+"/api/v1/messages/"+msgID+"/status", &statusResp, alice.Token)
	require.Equal(t, 200, codeStatus)
	assert.Equal(t, "read", statusResp.Status)
}
