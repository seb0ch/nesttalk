package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/auth"
	"github.com/seb0ch/nesttalk/server/internal/calls"
	"github.com/seb0ch/nesttalk/server/internal/control"
	"github.com/seb0ch/nesttalk/server/internal/keys"
	"github.com/seb0ch/nesttalk/server/internal/messages"
	"github.com/seb0ch/nesttalk/server/internal/reactions"
	"github.com/seb0ch/nesttalk/server/internal/roster"
	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// newWSStack spins up the full route mux against a fresh in-memory DB and
// enrolls one user, returning the issued session token plus the test server.
// The server is configured with allowedOrigins as the WS Origin whitelist.
func newWSStack(t *testing.T, allowedOrigins []string) (*httptest.Server, string) {
	t.Helper()
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	authSvc := auth.New(db)
	rosterSvc := roster.New(db)
	keysSvc := keys.New(db)
	hub := ws.NewHub()

	deps := &Deps{
		DB:             db,
		Auth:           authSvc,
		Roster:         rosterSvc,
		Keys:           keysSvc,
		Hub:            hub,
		AllowedOrigins: allowedOrigins,
	}

	mux := http.NewServeMux()
	RegisterRoutes(mux, deps)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	// Issue an enrollment via the control RPC dispatcher.
	ctrl := control.New(db, authSvc)
	enrollResp := ctrl.Dispatch(context.Background(), control.Request{
		ID:    1,
		CmdID: "ws-test-enroll",
		Cmd:   "enroll_user",
		Args:  mustJSON(t, map[string]string{"name": "alice"}),
	})
	require.True(t, enrollResp.OK, enrollResp.Error)
	var link struct {
		Code string `json:"code"`
	}
	require.NoError(t, json.Unmarshal(enrollResp.Result, &link))

	// Run start + complete + connect to land a session token.
	startRes, err := authSvc.EnrollStart(context.Background(), link.Code)
	require.NoError(t, err)
	devicePub, devicePriv, _ := ed25519.GenerateKey(rand.Reader)
	messagePubkey := make([]byte, auth.MessagePubKeyLen)
	_, _ = rand.Read(messagePubkey)
	completeRes, err := authSvc.EnrollComplete(context.Background(),
		link.Code, devicePub, messagePubkey,
		ed25519.Sign(devicePriv, startRes.Challenge),
	)
	require.NoError(t, err)
	chRes, err := authSvc.ConnectChallenge(context.Background(), completeRes.DeviceID)
	require.NoError(t, err)
	connRes, err := authSvc.ConnectComplete(context.Background(),
		completeRes.DeviceID, chRes.Nonce,
		ed25519.Sign(devicePriv, chRes.Nonce),
	)
	require.NoError(t, err)
	return srv, connRes.SessionToken
}

// TestWS_ReadDisconnectUnregistersSession guards the round-22 finding: a
// client close (read-loop error on the server) must unregister the session
// PROMPTLY, without requiring a subsequent outbound event. Otherwise the
// writer goroutine blocks forever on `range sess.Out`, the deferred
// Unregister never runs, and the zombie session keeps Hub.IsConnected true —
// defeating the stale-call sweep.
func TestWS_ReadDisconnectUnregistersSession(t *testing.T) {
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	authSvc := auth.New(db)
	hub := ws.NewHub()
	ctrl := control.New(db, authSvc)
	deps := &Deps{
		DB: db, Auth: authSvc, Roster: roster.New(db),
		Keys: keys.New(db), Hub: hub,
		AllowedOrigins: []string{"127.0.0.1", "127.0.0.1:*"},
	}
	mux := http.NewServeMux()
	RegisterRoutes(mux, deps)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	token, userID, _ := enrollAndConnectID(t, ctrl, authSvc, "alice")

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/v1/ws/control"
	conn, resp, err := websocket.Dial(context.Background(), wsURL, &websocket.DialOptions{
		HTTPHeader: http.Header{
			"Authorization": []string{"Bearer " + token},
			"Origin":        []string{"http://127.0.0.1:1234"},
		},
	})
	if resp != nil && resp.Body != nil {
		_ = resp.Body.Close()
	}
	require.NoError(t, err)
	require.NotNil(t, conn)

	// Registration is async; wait until the user is connected.
	require.Eventually(t, func() bool { return hub.IsConnected(userID) },
		2*time.Second, 10*time.Millisecond, "session must register")

	// Client disconnects. The server NEVER sends an outbound event, so the
	// only thing that can unregister the session is the read-error path.
	_ = conn.Close(websocket.StatusNormalClosure, "client gone")

	require.Eventually(t, func() bool { return !hub.IsConnected(userID) },
		2*time.Second, 10*time.Millisecond,
		"read-disconnect must unregister the session without an outbound event")
}

// TestReenroll_ClosesPriorDeviceWSSession guards the round-26 finding: a
// re-enroll revokes the prior device, and its live WS session must be closed
// SYNCHRONOUSLY by the enroll handler — not left active until the 30s
// revalidation tick.
func TestReenroll_ClosesPriorDeviceWSSession(t *testing.T) {
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	authSvc := auth.New(db)
	hub := ws.NewHub()
	ctrl := control.New(db, authSvc)
	deps := &Deps{
		DB: db, Auth: authSvc, Roster: roster.New(db),
		Keys: keys.New(db), Hub: hub,
		AllowedOrigins: []string{"127.0.0.1", "127.0.0.1:*"},
	}
	mux := http.NewServeMux()
	RegisterRoutes(mux, deps)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	token, userID, _ := enrollAndConnectID(t, ctrl, authSvc, "alice")

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/v1/ws/control"
	conn, resp, err := websocket.Dial(context.Background(), wsURL, &websocket.DialOptions{
		HTTPHeader: http.Header{
			"Authorization": []string{"Bearer " + token},
			"Origin":        []string{"http://127.0.0.1:1234"},
		},
	})
	if resp != nil && resp.Body != nil {
		_ = resp.Body.Close()
	}
	require.NoError(t, err)
	require.NotNil(t, conn)
	require.Eventually(t, func() bool { return hub.IsConnected(userID) },
		2*time.Second, 10*time.Millisecond, "prior device session must register")

	// Re-enroll the SAME user on a new device via the HTTP endpoint.
	code := issueExistingCode(t, ctrl, userID)
	startRes, err := authSvc.EnrollStart(context.Background(), code)
	require.NoError(t, err)
	newPub, newPriv, _ := ed25519.GenerateKey(rand.Reader)
	newMsgPub := make([]byte, auth.MessagePubKeyLen)
	body, _ := json.Marshal(enrollCompleteReq{
		Code:          code,
		DevicePubkey:  base64.StdEncoding.EncodeToString(newPub),
		MessagePubkey: base64.StdEncoding.EncodeToString(newMsgPub),
		Attestation:   base64.StdEncoding.EncodeToString(ed25519.Sign(newPriv, startRes.Challenge)),
	})
	httpResp, err := http.Post(srv.URL+"/api/v1/auth/enroll/complete", "application/json", bytes.NewReader(body))
	require.NoError(t, err)
	_ = httpResp.Body.Close()
	require.Equal(t, http.StatusOK, httpResp.StatusCode)

	// The prior device's live WS session must be gone immediately.
	require.Eventually(t, func() bool { return !hub.IsConnected(userID) },
		2*time.Second, 10*time.Millisecond,
		"re-enroll must close the prior device's WS session synchronously")
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	body, err := json.Marshal(v)
	require.NoError(t, err)
	return body
}

// TestWS_RevokeClosesSocketAtProtocolLevel guards the trust-boundary fix: when
// a connected user is revoked, the live control socket must be closed at the
// PROTOCOL level — not merely removed from the hub map — so the revoked device
// can no longer send typing_start / call_signal under its upgrade-time claims.
// A hub IsConnected check alone passes even with the bug, so this asserts the
// client's Read unblocks with a server-initiated close error.
func TestWS_RevokeClosesSocketAtProtocolLevel(t *testing.T) {
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	authSvc := auth.New(db)
	hub := ws.NewHub()
	ctrl := control.New(db, authSvc)
	deps := &Deps{
		DB: db, Auth: authSvc, Roster: roster.New(db),
		Keys: keys.New(db), Hub: hub,
		AllowedOrigins: []string{"127.0.0.1", "127.0.0.1:*"},
	}
	mux := http.NewServeMux()
	RegisterRoutes(mux, deps)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	token, userID, _ := enrollAndConnectID(t, ctrl, authSvc, "alice")

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/v1/ws/control"
	conn, resp, err := websocket.Dial(context.Background(), wsURL, &websocket.DialOptions{
		HTTPHeader: http.Header{
			"Authorization": []string{"Bearer " + token},
			"Origin":        []string{"http://127.0.0.1:1234"},
		},
	})
	if resp != nil && resp.Body != nil {
		_ = resp.Body.Close()
	}
	require.NoError(t, err)
	require.NotNil(t, conn)
	require.Eventually(t, func() bool { return hub.IsConnected(userID) },
		2*time.Second, 10*time.Millisecond, "session must register")

	// Revoke severs the live session exactly as the control revoke RPC does.
	require.Equal(t, 1, hub.DisconnectUser(userID))

	// The client socket must be closed at the protocol level: a blocking Read
	// returns an error promptly. Without the OnClose sever this could hang
	// until the writer drains buffered frames to a slow client or the 30s tick.
	readCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, _, err = conn.Read(readCtx)
	require.Error(t, err, "revoked WS must be closed at the protocol level, not left readable")
	require.False(t, hub.IsConnected(userID))
}

func TestWS_RejectsForbiddenOrigin(t *testing.T) {
	srv, token := newWSStack(t, []string{"localhost", "localhost:*", "127.0.0.1", "127.0.0.1:*", "*.nesttalk.local", "*.nesttalk.local:*"})

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/v1/ws/control"
	_, resp, err := websocket.Dial(context.Background(), wsURL, &websocket.DialOptions{
		HTTPHeader: http.Header{
			"Authorization": []string{"Bearer " + token},
			"Origin":        []string{"http://evil.example.com"},
		},
	})
	require.Error(t, err, "handshake from evil origin must fail")
	require.NotNil(t, resp, "evil-origin handshake must produce an HTTP response")
	defer resp.Body.Close()
	assert.Equal(t, http.StatusForbidden, resp.StatusCode,
		"the websocket library rejects forbidden origin with 403")
}

func TestWS_AcceptsSubprotocolBearer(t *testing.T) {
	// Flutter/browser clients cannot set the Authorization header on a WS
	// upgrade; they offer the session token via Sec-WebSocket-Protocol.
	// The server must read the bearer from the subprotocol list AND echo
	// it back so the handshake completes with a negotiated subprotocol.
	srv, token := newWSStack(t, []string{"127.0.0.1", "127.0.0.1:*"})

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/v1/ws/control"
	conn, resp, err := websocket.Dial(context.Background(), wsURL, &websocket.DialOptions{
		HTTPHeader: http.Header{
			"Origin": []string{"http://127.0.0.1:1234"},
		},
		Subprotocols: []string{token},
	})
	if resp != nil && resp.Body != nil {
		_ = resp.Body.Close()
	}
	require.NoError(t, err, "WS handshake via subprotocol bearer must succeed")
	require.NotNil(t, conn)
	assert.Equal(t, token, conn.Subprotocol(),
		"server must echo the offered subprotocol so the client's handshake completes")
	_ = conn.Close(websocket.StatusNormalClosure, "test done")
}

func TestWS_AcceptsAllowedOrigin(t *testing.T) {
	srv, token := newWSStack(t, []string{"localhost", "localhost:*", "127.0.0.1", "127.0.0.1:*", "*.nesttalk.local", "*.nesttalk.local:*"})

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/v1/ws/control"
	conn, resp, err := websocket.Dial(context.Background(), wsURL, &websocket.DialOptions{
		HTTPHeader: http.Header{
			"Authorization": []string{"Bearer " + token},
			"Origin":        []string{"http://127.0.0.1:1234"},
		},
	})
	// On a successful upgrade the websocket library hijacks the
	// response and sets resp.Body = nil, so don't close it here.
	if resp != nil && resp.Body != nil {
		_ = resp.Body.Close()
	}
	require.NoError(t, err, "handshake from allowlisted origin must succeed")
	require.NotNil(t, conn)
	_ = conn.Close(websocket.StatusNormalClosure, "test done")
}

// TestMessages_RecipientDeviceRotated_ProductionBody verifies that the
// production mux (via RegisterRoutes) emits both "error" and "reason" fields
// in the 403 body when the envelope targets a stale recipient device ID.
// This guards against regression of the C1 fix (spec line 527).
func TestMessages_RecipientDeviceRotated_ProductionBody(t *testing.T) {
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	authSvc := auth.New(db)
	hub := ws.NewHub()
	msgSvc := messages.New(db, hub)
	ctrl := control.New(db, authSvc)

	deps := &Deps{
		DB:       db,
		Auth:     authSvc,
		Roster:   roster.New(db),
		Keys:     keys.New(db),
		Messages: msgSvc,
		Hub:      hub,
	}
	mux := http.NewServeMux()
	RegisterRoutes(mux, deps)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	// Enroll alice fully — she is the sender; her user ID must match the envelope.
	aliceToken, aliceUserID, aliceDeviceID := enrollAndConnectID(t, ctrl, authSvc, "alice")

	// Enroll bob (initial device) — capture user ID and stale device ID.
	bobCode := issueCode(t, ctrl, "bob")
	bobStart, err := authSvc.EnrollStart(context.Background(), bobCode)
	require.NoError(t, err)
	bobPub, bobPriv, _ := ed25519.GenerateKey(rand.Reader)
	bobMsgPub := make([]byte, auth.MessagePubKeyLen)
	bobComplete, err := authSvc.EnrollComplete(context.Background(),
		bobCode, bobPub, bobMsgPub, ed25519.Sign(bobPriv, bobStart.Challenge),
	)
	require.NoError(t, err)
	staleDeviceID := bobComplete.DeviceID
	bobUserID := bobComplete.UserID

	// Rotate bob's device via enroll_existing_user — revokes stale device.
	rotateCode := issueExistingCode(t, ctrl, bobUserID)
	rotateStart, err := authSvc.EnrollStart(context.Background(), rotateCode)
	require.NoError(t, err)
	newPub, newPriv, _ := ed25519.GenerateKey(rand.Reader)
	newMsgPub := make([]byte, auth.MessagePubKeyLen)
	newComplete, err := authSvc.EnrollComplete(context.Background(),
		rotateCode, newPub, newMsgPub, ed25519.Sign(newPriv, rotateStart.Challenge),
	)
	require.NoError(t, err)
	activeDeviceID := newComplete.DeviceID

	// Build an envelope from alice to bob addressing the now-stale device.
	env := buildTestEnvelope(t, aliceUserID, aliceDeviceID, bobUserID, staleDeviceID)

	reqBody, _ := json.Marshal(map[string]any{
		"envelope": base64.StdEncoding.EncodeToString(env),
		"sent_at":  1_700_000_000_000,
	})
	req, err := http.NewRequest("POST", srv.URL+"/api/v1/messages", bytes.NewReader(reqBody))
	require.NoError(t, err)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+aliceToken)
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()

	bodyBytes, _ := io.ReadAll(resp.Body)
	assert.Equal(t, http.StatusForbidden, resp.StatusCode, "body: %s", string(bodyBytes))

	var body map[string]any
	require.NoError(t, json.Unmarshal(bodyBytes, &body))
	assert.Equal(t, "recipient_device_rotated", body["error"],
		"production body must carry 'error' field per spec line 527; body: %s", string(bodyBytes))
	assert.Equal(t, "recipient_device_rotated", body["reason"])
	assert.Equal(t, activeDeviceID, body["active_recipient_device_id"],
		"active_recipient_device_id must match bob's current active device")
}

// TestDevicePushToken_PersistsAndLooksUp guards the two push-token SQL
// regressions found in adversarial review round 13: the registration
// UPDATE referenced a nonexistent `device_id` column (PK is `id`) and the
// APNs lookup filtered on a nonexistent `revoked` column (schema uses
// nullable `revoked_at`). Either bug made VoIP pushes impossible.
func TestDevicePushToken_PersistsAndLooksUp(t *testing.T) {
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	authSvc := auth.New(db)
	hub := ws.NewHub()
	ctrl := control.New(db, authSvc)
	deps := &Deps{
		DB:       db,
		Auth:     authSvc,
		Roster:   roster.New(db),
		Keys:     keys.New(db),
		Messages: messages.New(db, hub),
		Hub:      hub,
	}
	mux := http.NewServeMux()
	RegisterRoutes(mux, deps)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	token, userID, _ := enrollAndConnectID(t, ctrl, authSvc, "alice")

	pushToken := strings.Repeat("ab", 32) // 64 hex chars
	reqBody, _ := json.Marshal(map[string]any{"token": pushToken, "env": "prod"})
	req, err := http.NewRequest("POST", srv.URL+"/api/v1/devices/push-token", bytes.NewReader(reqBody))
	require.NoError(t, err)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	require.Equal(t, http.StatusNoContent, resp.StatusCode, "registration must persist; body: %s", string(body))

	// The APNs lookup path must find the just-registered token.
	gotToken, gotEnv, err := lookupVoIPToken(context.Background(), db, userID)
	require.NoError(t, err)
	assert.Equal(t, pushToken, gotToken)
	assert.Equal(t, "prod", gotEnv)
}

// issueCode dispatches enroll_user and returns the enrollment code.
func issueCode(t *testing.T, ctrl *control.Server, name string) string {
	t.Helper()
	res := ctrl.Dispatch(context.Background(), control.Request{
		ID: 1, CmdID: "new-" + name, Cmd: "enroll_user",
		Args: mustJSON(t, map[string]string{"name": name}),
	})
	require.True(t, res.OK, res.Error)
	var link struct {
		Code string `json:"code"`
	}
	require.NoError(t, json.Unmarshal(res.Result, &link))
	return link.Code
}

// issueExistingCode dispatches enroll_existing_user and returns the enrollment code.
func issueExistingCode(t *testing.T, ctrl *control.Server, userID string) string {
	t.Helper()
	res := ctrl.Dispatch(context.Background(), control.Request{
		ID: 2, CmdID: "rotate-" + userID, Cmd: "enroll_existing_user",
		Args: mustJSON(t, map[string]string{"user_id": userID}),
	})
	require.True(t, res.OK, res.Error)
	var link struct {
		Code string `json:"code"`
	}
	require.NoError(t, json.Unmarshal(res.Result, &link))
	return link.Code
}

// enrollAndConnectID enrolls a user and returns (session token, user ID).
func enrollAndConnectID(t *testing.T, ctrl *control.Server, authSvc *auth.Service, name string) (token, userID, deviceID string) {
	t.Helper()
	code := issueCode(t, ctrl, name)
	startRes, err := authSvc.EnrollStart(context.Background(), code)
	require.NoError(t, err)
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	msgPub := make([]byte, auth.MessagePubKeyLen)
	completeRes, err := authSvc.EnrollComplete(context.Background(),
		code, pub, msgPub, ed25519.Sign(priv, startRes.Challenge),
	)
	require.NoError(t, err)
	chRes, err := authSvc.ConnectChallenge(context.Background(), completeRes.DeviceID)
	require.NoError(t, err)
	connRes, err := authSvc.ConnectComplete(context.Background(),
		completeRes.DeviceID, chRes.Nonce, ed25519.Sign(priv, chRes.Nonce),
	)
	require.NoError(t, err)
	return connRes.SessionToken, completeRes.UserID, completeRes.DeviceID
}

// buildTestEnvelope constructs a minimal spec-compliant envelope.
// ct is 64 zero bytes so ct_len = 64 satisfies the layout check.
func buildTestEnvelope(t *testing.T, senderUserID, senderDeviceIDStr, recipientUserID, recipientDeviceID string) []byte {
	t.Helper()
	messageID := make([]byte, 16)
	_, _ = rand.Read(messageID)

	parseUUID := func(s string) []byte {
		var b [16]byte
		hexStr := make([]byte, 0, 32)
		for _, c := range s {
			if c == '-' {
				continue
			}
			hexStr = append(hexStr, byte(c))
		}
		for i := 0; i < 16 && i*2+1 < len(hexStr); i++ {
			hi, lo := hexStr[i*2], hexStr[i*2+1]
			nibble := func(c byte) byte {
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
			b[i] = (nibble(hi) << 4) | nibble(lo)
		}
		return b[:]
	}

	ct := make([]byte, 64)
	buf := make([]byte, 0, messages.MinEnvelopeLen+64)
	buf = append(buf, 0x01)                            // version
	buf = append(buf, parseUUID(senderUserID)...)      // sender_user_id
	buf = append(buf, parseUUID(senderDeviceIDStr)...) // sender_device_id
	buf = append(buf, parseUUID(recipientUserID)...)   // recipient_user_id
	buf = append(buf, parseUUID(recipientDeviceID)...) // recipient_device_id
	buf = append(buf, messageID...)                    // message_id
	buf = append(buf, make([]byte, 32)...)             // eph_x25519_pub
	buf = append(buf, make([]byte, 1088)...)           // ml_kem_ct
	buf = append(buf, make([]byte, 12)...)             // nonce
	ctLenBytes := make([]byte, 4)
	binary.BigEndian.PutUint32(ctLenBytes, uint32(len(ct)))
	buf = append(buf, ctLenBytes...)
	buf = append(buf, ct...)
	buf = append(buf, make([]byte, 64)...) // sender_sig
	return buf
}

// TestMapCallsErr_BusyDoesNotLeakThirdPartyMetadata covers the round-33
// finding: a cross-pair busy 409 must NOT disclose the blocking call's id,
// caller, kind, or state — the requester is not a participant in it. Only the
// busy participant (always self or the dialed peer) may be returned.
func TestMapCallsErr_BusyDoesNotLeakThirdPartyMetadata(t *testing.T) {
	rec := httptest.NewRecorder()
	mapCallsErr(rec, &calls.BusyError{
		BusyUserID: "callee-user",
		Info: calls.GlareInfo{
			ExistingCallID:       "secret-call-id",
			ExistingCallerUserID: "third-party-user",
			ExistingCallKind:     calls.KindVideo,
			ExistingState:        calls.StateConnected,
		},
	})
	require.Equal(t, http.StatusConflict, rec.Code)

	var body map[string]any
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	assert.Equal(t, "busy", body["error"])
	assert.Equal(t, "callee-user", body["busy_user_id"])

	// None of the third party's call metadata may appear in the response.
	for _, leaked := range []string{"existing_call_id", "existing_caller_user_id", "existing_call_kind", "existing_call_state"} {
		_, present := body[leaked]
		assert.Falsef(t, present, "busy response must not expose %q", leaked)
	}
	assert.NotContains(t, rec.Body.String(), "secret-call-id")
	assert.NotContains(t, rec.Body.String(), "third-party-user")
}

// TestMapCallsErr_GlareStillCarriesDetail verifies the same-pair glare path is
// unchanged — the requester IS a participant, so the existing-call detail it
// needs to reconcile the race is still present.
func TestMapCallsErr_GlareStillCarriesDetail(t *testing.T) {
	rec := httptest.NewRecorder()
	mapCallsErr(rec, &calls.GlareError{Info: calls.GlareInfo{
		ExistingCallID:       "shared-call-id",
		ExistingCallerUserID: "the-peer",
		ExistingCallKind:     calls.KindAudio,
		ExistingState:        calls.StateRinging,
	}})
	require.Equal(t, http.StatusConflict, rec.Code)

	var body map[string]any
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	assert.Equal(t, "glare", body["error"])
	assert.Equal(t, "shared-call-id", body["existing_call_id"])
	assert.Equal(t, "the-peer", body["existing_caller_user_id"])
}

// TestDaemonBackupRunner_RebindsControlDBOnVacuumAndRestore covers the round-41
// finding: RestoreFrom/Vacuum close the old DB and swap a fresh handle into the
// HTTP deps, but the control RPC server held its own DB pointer and was not
// updated — so admin commands (enroll/revoke/list/vacuum) would hit a closed
// handle until the daemon restarted.
func TestDaemonBackupRunner_RebindsControlDBOnVacuumAndRestore(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "live.db")
	db, err := storage.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	hub := ws.NewHub()
	authSvc := auth.New(db)
	deps := &Deps{
		DB: db, Auth: authSvc, Roster: roster.New(db), Keys: keys.New(db),
		Messages: messages.New(db, hub), Reactions: reactions.New(db, hub),
		Calls: calls.New(db, hub), Hub: hub,
	}
	ctrl := control.New(db, authSvc)
	runner := newDaemonBackupRunner(deps, ctrl, dbPath)
	ctx := context.Background()

	var n int
	// Vacuum closes + reopens the DB; the control server must follow.
	require.NoError(t, runner.Vacuum(ctx))
	assert.NotSame(t, db, ctrl.DB, "vacuum must rebind the control DB off the closed handle")
	require.NoError(t, ctrl.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM users`).Scan(&n),
		"control DB must be a live handle after vacuum")

	// Restore from a fresh snapshot; the control server must follow again.
	snap := filepath.Join(dir, "snap.db")
	require.NoError(t, runner.BackupTo(ctx, snap))
	afterVacuum := ctrl.DB
	_, _, _, err = runner.RestoreFrom(ctx, snap)
	require.NoError(t, err)
	assert.NotSame(t, afterVacuum, ctrl.DB, "restore must rebind the control DB off the closed handle")
	require.NoError(t, ctrl.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM users`).Scan(&n),
		"control DB must be a live handle after restore")
}

// TestClearVoIPToken_OnlyClearsMatchingToken covers the round-42 stale-token
// cleanup: a dead-token APNs rejection clears the stored VoIP token, but only
// when it matches — a late rejection of an OLD token must not wipe one the
// client just re-registered.
func TestClearVoIPToken_OnlyClearsMatchingToken(t *testing.T) {
	dir := t.TempDir()
	db, err := storage.Open(filepath.Join(dir, "t.db"))
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	ctx := context.Background()

	_, err = db.ExecContext(ctx,
		`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES ('u1','U',0,1)`)
	require.NoError(t, err)
	_, err = db.ExecContext(ctx,
		`INSERT INTO devices (id, user_id, public_key, message_pubkey, enrolled_at, voip_push_token, voip_push_env)
		 VALUES ('d1','u1',randomblob(32),randomblob(1216),1,'tok-A','prod')`)
	require.NoError(t, err)

	readTok := func() string {
		var tok string
		require.NoError(t, db.QueryRowContext(ctx,
			`SELECT COALESCE(voip_push_token,'') FROM devices WHERE id='d1'`).Scan(&tok))
		return tok
	}

	// A late rejection of a DIFFERENT (old) token must NOT clear the current one.
	require.NoError(t, clearVoIPToken(ctx, db, "u1", "tok-OLD"))
	assert.Equal(t, "tok-A", readTok(), "mismatched token rejection must not clear the current token")

	// A rejection of the CURRENT token clears it so we stop pushing to it.
	require.NoError(t, clearVoIPToken(ctx, db, "u1", "tok-A"))
	assert.Equal(t, "", readTok(), "matching dead-token rejection clears it")
}
