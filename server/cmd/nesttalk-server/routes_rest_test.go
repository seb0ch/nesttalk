package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

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

// testUser carries the session credentials plus identifiers for one enrolled
// device, so REST tests can address it as both a session principal and an
// envelope endpoint.
type testUser struct {
	Token    string
	UserID   string
	DeviceID string
}

// fullStack is the in-memory route stack used by the REST endpoint tests:
// every service is wired (unlike newWSStack, which omits messages/reactions/
// calls), the calls manager has a TURN secret so the relay path succeeds, and
// two users are enrolled so caller/callee and sender/recipient flows work.
type fullStack struct {
	srv   *httptest.Server
	deps  *Deps
	alice testUser
	bob   testUser
}

func newFullStack(t *testing.T) *fullStack {
	t.Helper()
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "test.db"), &storage.FixedClock{T: 1_700_000_000_000})
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	authSvc := auth.New(db)
	hub := ws.NewHub()
	callsMgr := calls.New(db, hub)
	callsMgr.TURNSecret = "test-turn-secret"
	callsMgr.TURNHost = "turn.example.test"

	deps := &Deps{
		DB:             db,
		Auth:           authSvc,
		Roster:         roster.New(db),
		Keys:           keys.New(db),
		Messages:       messages.New(db, hub),
		Reactions:      reactions.New(db, hub),
		Calls:          callsMgr,
		Hub:            hub,
		Typing:         messages.NewTypingTracker(hub, db.Clock.NowMillis),
		AllowedOrigins: []string{"127.0.0.1", "127.0.0.1:*"},
	}
	mux := http.NewServeMux()
	RegisterRoutes(mux, deps)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	ctrl := control.New(db, authSvc)
	aToken, aUser, aDevice := enrollAndConnectID(t, ctrl, authSvc, "alice")
	bToken, bUser, bDevice := enrollAndConnectID(t, ctrl, authSvc, "bob")

	return &fullStack{
		srv:   srv,
		deps:  deps,
		alice: testUser{Token: aToken, UserID: aUser, DeviceID: aDevice},
		bob:   testUser{Token: bToken, UserID: bUser, DeviceID: bDevice},
	}
}

// do issues an HTTP request to the stack. A nil body sends no payload; a
// non-nil body is JSON-encoded. An empty token omits the Authorization header.
func (s *fullStack) do(t *testing.T, method, path, token string, body any) *http.Response {
	t.Helper()
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(mustJSON(t, body))
	}
	req, err := http.NewRequest(method, s.srv.URL+path, rdr)
	require.NoError(t, err)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

// raw issues a request with a literal string body (for malformed-JSON cases).
func (s *fullStack) raw(t *testing.T, method, path, token, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, s.srv.URL+path, strings.NewReader(body))
	require.NoError(t, err)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

func decodeBody(t *testing.T, resp *http.Response) map[string]any {
	t.Helper()
	var m map[string]any
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&m))
	return m
}

func TestHealth(t *testing.T) {
	s := newFullStack(t)
	resp := s.do(t, http.MethodGet, "/api/v1/health", "", nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	body := decodeBody(t, resp)
	assert.Equal(t, true, body["ok"])
	assert.Equal(t, "v0.2.0", body["api_version"])
}

func TestEnrollStart_Validation(t *testing.T) {
	s := newFullStack(t)
	// Missing code → 400.
	resp := s.do(t, http.MethodPost, "/api/v1/auth/enroll/start", "", map[string]string{})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Malformed JSON → 400.
	resp = s.raw(t, http.MethodPost, "/api/v1/auth/enroll/start", "", "{not json")
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Unknown code → mapped auth error (4xx/5xx, never 200).
	resp = s.do(t, http.MethodPost, "/api/v1/auth/enroll/start", "", map[string]string{"code": "no-such-code"})
	assert.NotEqual(t, http.StatusOK, resp.StatusCode)
}

func TestConnectChallenge_Validation(t *testing.T) {
	s := newFullStack(t)
	resp := s.do(t, http.MethodPost, "/api/v1/auth/connect/challenge", "", map[string]string{})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Unknown device → device_not_found (401).
	resp = s.do(t, http.MethodPost, "/api/v1/auth/connect/challenge", "", map[string]string{"device_id": "00000000-0000-0000-0000-000000000000"})
	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
}

func TestConnectComplete_Validation(t *testing.T) {
	s := newFullStack(t)
	resp := s.raw(t, http.MethodPost, "/api/v1/auth/connect/complete", "", "{bad")
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Bad base64 nonce → 400.
	resp = s.do(t, http.MethodPost, "/api/v1/auth/connect/complete", "", map[string]string{
		"device_id": "x", "nonce": "!!!notb64", "attestation": "AAAA",
	})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Bad base64 attestation → 400.
	resp = s.do(t, http.MethodPost, "/api/v1/auth/connect/complete", "", map[string]string{
		"device_id": "x", "nonce": "AAAA", "attestation": "!!!notb64",
	})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
}

func TestEnrollComplete_Validation(t *testing.T) {
	s := newFullStack(t)
	resp := s.raw(t, http.MethodPost, "/api/v1/auth/enroll/complete", "", "{bad")
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	for _, field := range []string{"device_pubkey", "message_pubkey", "attestation"} {
		req := map[string]string{"code": "c", "device_pubkey": "AAAA", "message_pubkey": "AAAA", "attestation": "AAAA"}
		req[field] = "!!!notb64"
		resp := s.do(t, http.MethodPost, "/api/v1/auth/enroll/complete", "", req)
		assert.Equalf(t, http.StatusBadRequest, resp.StatusCode, "bad base64 %s", field)
	}
}

func TestProtectedEndpoints_RequireBearer(t *testing.T) {
	s := newFullStack(t)
	protected := []struct {
		method, path string
	}{
		{http.MethodGet, "/api/v1/roster"},
		{http.MethodGet, "/api/v1/keys/message/" + s.bob.UserID},
		{http.MethodPost, "/api/v1/messages"},
		{http.MethodGet, "/api/v1/messages/pending"},
		{http.MethodGet, "/api/v1/reactions/since"},
		{http.MethodPost, "/api/v1/calls"},
		{http.MethodGet, "/api/v1/relay/session"},
		{http.MethodPost, "/api/v1/devices/push-token"},
	}
	for _, e := range protected {
		resp := s.do(t, e.method, e.path, "", nil)
		assert.Equalf(t, http.StatusUnauthorized, resp.StatusCode, "%s %s", e.method, e.path)
	}
	// A garbage token is rejected too.
	resp := s.do(t, http.MethodGet, "/api/v1/roster", "garbage-token", nil)
	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode)
}

func TestRoster(t *testing.T) {
	s := newFullStack(t)
	resp := s.do(t, http.MethodGet, "/api/v1/roster", s.alice.Token, nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	body := decodeBody(t, resp)
	entries, ok := body["roster"].([]any)
	require.True(t, ok)
	// alice sees bob (all enrolled non-revoked users appear).
	assert.NotEmpty(t, entries)
}

func TestMessageKeys(t *testing.T) {
	s := newFullStack(t)
	resp := s.do(t, http.MethodGet, "/api/v1/keys/message/"+s.bob.UserID, s.alice.Token, nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	body := decodeBody(t, resp)
	devices, ok := body["devices"].([]any)
	require.True(t, ok)
	assert.Len(t, devices, 1)

	// Unknown user → 404.
	resp = s.do(t, http.MethodGet, "/api/v1/keys/message/00000000-0000-0000-0000-000000000000", s.alice.Token, nil)
	assert.Equal(t, http.StatusNotFound, resp.StatusCode)
}

func TestMessagesPost_Validation(t *testing.T) {
	s := newFullStack(t)
	// Bad JSON.
	resp := s.raw(t, http.MethodPost, "/api/v1/messages", s.alice.Token, "{bad")
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Missing envelope.
	resp = s.do(t, http.MethodPost, "/api/v1/messages", s.alice.Token, map[string]any{"sent_at": 1})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Non-base64 envelope.
	resp = s.do(t, http.MethodPost, "/api/v1/messages", s.alice.Token, map[string]any{"envelope": "!!!notb64"})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Well-formed base64 but malformed envelope bytes → 400 envelope_malformed.
	resp = s.do(t, http.MethodPost, "/api/v1/messages", s.alice.Token, map[string]any{
		"envelope": base64.StdEncoding.EncodeToString([]byte("too short")),
	})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
}

// postMessage sends a valid alice→bob message and returns its id.
func (s *fullStack) postMessage(t *testing.T) string {
	t.Helper()
	env := buildTestEnvelope(t, s.alice.UserID, s.alice.DeviceID, s.bob.UserID, s.bob.DeviceID)
	resp := s.do(t, http.MethodPost, "/api/v1/messages", s.alice.Token, map[string]any{
		"envelope": base64.StdEncoding.EncodeToString(env),
		"sent_at":  1_700_000_000_001,
	})
	require.Equal(t, http.StatusOK, resp.StatusCode)
	body := decodeBody(t, resp)
	id, _ := body["id"].(string)
	require.NotEmpty(t, id)
	return id
}

func TestMessages_PostPendingAckStatus(t *testing.T) {
	s := newFullStack(t)
	msgID := s.postMessage(t)

	// bob fetches pending and sees the message.
	resp := s.do(t, http.MethodGet, "/api/v1/messages/pending?limit=10", s.bob.Token, nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	body := decodeBody(t, resp)
	msgs, ok := body["messages"].([]any)
	require.True(t, ok)
	assert.NotEmpty(t, msgs)

	// bob acks delivered.
	resp = s.do(t, http.MethodPost, "/api/v1/messages/"+msgID+"/ack", s.bob.Token, map[string]string{"kind": "delivered"})
	assert.Equal(t, http.StatusOK, resp.StatusCode)

	// Invalid ack kind → 400.
	resp = s.do(t, http.MethodPost, "/api/v1/messages/"+msgID+"/ack", s.bob.Token, map[string]string{"kind": "bogus"})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)

	// Bad JSON ack → 400.
	resp = s.raw(t, http.MethodPost, "/api/v1/messages/"+msgID+"/ack", s.bob.Token, "{bad")
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)

	// alice (sender) checks status.
	resp = s.do(t, http.MethodGet, "/api/v1/messages/"+msgID+"/status", s.alice.Token, nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	body = decodeBody(t, resp)
	assert.NotEmpty(t, body["status"])

	// Unknown message status → 200 "gone" (sender unverified, no rows at all).
	resp = s.do(t, http.MethodGet, "/api/v1/messages/00000000-0000-0000-0000-000000000000/status", s.alice.Token, nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, "gone", decodeBody(t, resp)["status"])
}

// parseUUID16 decodes a hyphenated UUID string into its 16 raw bytes, matching
// the envelope layout's UUID fields.
func parseUUID16(s string) []byte {
	var b [16]byte
	hexStr := make([]byte, 0, 32)
	for _, c := range s {
		if c == '-' {
			continue
		}
		hexStr = append(hexStr, byte(c))
	}
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
	for i := 0; i < 16 && i*2+1 < len(hexStr); i++ {
		b[i] = (nibble(hexStr[i*2]) << 4) | nibble(hexStr[i*2+1])
	}
	return b[:]
}

func TestReactions_Validation(t *testing.T) {
	s := newFullStack(t)
	msgID := s.postMessage(t)
	path := "/api/v1/messages/" + msgID + "/reactions"
	// Bad JSON.
	resp := s.raw(t, http.MethodPut, path, s.bob.Token, "{bad")
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Missing envelope.
	resp = s.do(t, http.MethodPut, path, s.bob.Token, map[string]any{"sent_at": 1})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Non-base64 envelope.
	resp = s.do(t, http.MethodPut, path, s.bob.Token, map[string]any{"envelope": "!!!notb64"})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
}

func TestReactions_PutAndSince(t *testing.T) {
	s := newFullStack(t)
	msgID := s.postMessage(t)

	// bob reacts to alice's message: reaction envelope sender=bob, recipient=alice.
	// The signed message_id inside the envelope must equal the parent id, so
	// overwrite the random message_id (offset 65, after version + 4 UUIDs).
	env := buildTestEnvelope(t, s.bob.UserID, s.bob.DeviceID, s.alice.UserID, s.alice.DeviceID)
	copy(env[65:81], parseUUID16(msgID))
	resp := s.do(t, http.MethodPut, "/api/v1/messages/"+msgID+"/reactions", s.bob.Token, map[string]any{
		"envelope": base64.StdEncoding.EncodeToString(env),
		"sent_at":  1_700_000_000_002,
	})
	require.Equal(t, http.StatusOK, resp.StatusCode, decodeBody(t, resp))

	// alice pulls reactions since the beginning.
	resp = s.do(t, http.MethodGet, "/api/v1/reactions/since?limit=10", s.alice.Token, nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	body := decodeBody(t, resp)
	rxns, ok := body["reactions"].([]any)
	require.True(t, ok)
	assert.NotEmpty(t, rxns)
}

func TestCalls_FullLifecycles(t *testing.T) {
	s := newFullStack(t)

	// create → accept → end
	callID := s.createCall(t)
	resp := s.do(t, http.MethodPost, "/api/v1/calls/"+callID+"/accept", s.bob.Token, nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, string(calls.StateConnected), decodeBody(t, resp)["state"])
	resp = s.do(t, http.MethodPost, "/api/v1/calls/"+callID+"/end", s.alice.Token, nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)

	// create → decline (callee)
	callID = s.createCall(t)
	resp = s.do(t, http.MethodPost, "/api/v1/calls/"+callID+"/decline", s.bob.Token, nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, string(calls.StateDeclined), decodeBody(t, resp)["state"])

	// create → cancel (caller)
	callID = s.createCall(t)
	resp = s.do(t, http.MethodPost, "/api/v1/calls/"+callID+"/cancel", s.alice.Token, nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, string(calls.StateCancelled), decodeBody(t, resp)["state"])
}

func (s *fullStack) createCall(t *testing.T) string {
	t.Helper()
	resp := s.do(t, http.MethodPost, "/api/v1/calls", s.alice.Token, map[string]string{
		"callee_user_id": s.bob.UserID,
		"kind":           "audio",
	})
	body := decodeBody(t, resp)
	require.Equalf(t, http.StatusOK, resp.StatusCode, "%v", body)
	assert.Equal(t, string(calls.StateRinging), body["state"])
	id, _ := body["call_id"].(string)
	require.NotEmpty(t, id)
	return id
}

func TestCallCreate_Validation(t *testing.T) {
	s := newFullStack(t)
	// Bad JSON.
	resp := s.raw(t, http.MethodPost, "/api/v1/calls", s.alice.Token, "{bad")
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Missing callee.
	resp = s.do(t, http.MethodPost, "/api/v1/calls", s.alice.Token, map[string]string{"kind": "audio"})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Unknown call id on a transition → 404.
	resp = s.do(t, http.MethodPost, "/api/v1/calls/00000000-0000-0000-0000-000000000000/accept", s.bob.Token, nil)
	assert.Equal(t, http.StatusNotFound, resp.StatusCode)
}

func TestRelaySession(t *testing.T) {
	s := newFullStack(t)
	resp := s.do(t, http.MethodGet, "/api/v1/relay/session", s.alice.Token, nil)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	body := decodeBody(t, resp)
	assert.NotEmpty(t, body["username"])
	assert.NotEmpty(t, body["password"])
	urls, ok := body["urls"].([]any)
	require.True(t, ok)
	assert.NotEmpty(t, urls)
}

func TestDevicePushToken(t *testing.T) {
	s := newFullStack(t)
	hexToken := strings.Repeat("ab", 32) // 64 hex chars
	// Happy path.
	resp := s.do(t, http.MethodPost, "/api/v1/devices/push-token", s.alice.Token, map[string]string{
		"token": hexToken, "env": "prod",
	})
	assert.Equal(t, http.StatusNoContent, resp.StatusCode)

	// Bad JSON.
	resp = s.raw(t, http.MethodPost, "/api/v1/devices/push-token", s.alice.Token, "{bad")
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Wrong length.
	resp = s.do(t, http.MethodPost, "/api/v1/devices/push-token", s.alice.Token, map[string]string{"token": "abcd", "env": "prod"})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Non-hex.
	resp = s.do(t, http.MethodPost, "/api/v1/devices/push-token", s.alice.Token, map[string]string{"token": strings.Repeat("zz", 32), "env": "prod"})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
	// Bad env.
	resp = s.do(t, http.MethodPost, "/api/v1/devices/push-token", s.alice.Token, map[string]string{"token": hexToken, "env": "staging"})
	assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
}

// TestMapAuthErr_StatusMapping exercises the auth-error translation table
// directly, since several branches are hard to reach via the live handlers.
func TestMapAuthErr_StatusMapping(t *testing.T) {
	cases := []struct {
		err  error
		want int
	}{
		{auth.ErrLinkGone, http.StatusGone},
		{auth.ErrLinkConsumed, http.StatusGone},
		{auth.ErrInvalidAttestation, http.StatusBadRequest},
		{auth.ErrUserRevoked, http.StatusForbidden},
		{auth.ErrNonceInvalid, http.StatusUnauthorized},
		{auth.ErrDeviceNotFound, http.StatusUnauthorized},
		{auth.ErrSessionExpired, http.StatusUnauthorized},
		{context.DeadlineExceeded, http.StatusInternalServerError},
	}
	for _, tc := range cases {
		rec := httptest.NewRecorder()
		mapAuthErr(rec, tc.err)
		assert.Equalf(t, tc.want, rec.Code, "%v", tc.err)
	}
}

// TestMapMessagesErr_StatusMapping covers the messages-error table directly.
func TestMapMessagesErr_StatusMapping(t *testing.T) {
	cases := []struct {
		err  error
		want int
	}{
		{messages.ErrEnvelopeMalformed, http.StatusBadRequest},
		{messages.ErrNotAuthorized, http.StatusForbidden},
		{messages.ErrRecipientRevoked, http.StatusForbidden},
		{messages.ErrMessageExpired, http.StatusGone},
		{messages.ErrInvalidAckKind, http.StatusBadRequest},
		{messages.ErrNotFound, http.StatusNotFound},
		{&messages.RecipientDeviceRotatedError{ActiveDeviceID: "dev-1"}, http.StatusForbidden},
		{context.DeadlineExceeded, http.StatusInternalServerError},
	}
	for _, tc := range cases {
		rec := httptest.NewRecorder()
		mapMessagesErr(rec, tc.err)
		assert.Equalf(t, tc.want, rec.Code, "%v", tc.err)
	}
}

// TestMapReactionsErr_StatusMapping covers the reactions-error table directly.
func TestMapReactionsErr_StatusMapping(t *testing.T) {
	cases := []struct {
		err  error
		want int
	}{
		{reactions.ErrEnvelopeMalformed, http.StatusBadRequest},
		{reactions.ErrNotAuthorized, http.StatusForbidden},
		{reactions.ErrParentPurged, http.StatusGone},
		{&messages.RecipientDeviceRotatedError{ActiveDeviceID: "dev-2"}, http.StatusForbidden},
		{context.DeadlineExceeded, http.StatusInternalServerError},
	}
	for _, tc := range cases {
		rec := httptest.NewRecorder()
		mapReactionsErr(rec, tc.err)
		assert.Equalf(t, tc.want, rec.Code, "%v", tc.err)
	}
}

// TestMapCallsErr_StatusMapping covers the remaining calls-error sentinels not
// already asserted by the glare/busy leak tests.
func TestMapCallsErr_StatusMapping(t *testing.T) {
	cases := []struct {
		err  error
		want int
	}{
		{calls.ErrNotFound, http.StatusNotFound},
		{calls.ErrNotAuthorized, http.StatusForbidden},
		{calls.ErrCalleeOnly, http.StatusForbidden},
		{calls.ErrCallerOnly, http.StatusForbidden},
		{&calls.WrongStateError{Current: "ended"}, http.StatusConflict},
		{context.DeadlineExceeded, http.StatusInternalServerError},
	}
	for _, tc := range cases {
		rec := httptest.NewRecorder()
		mapCallsErr(rec, tc.err)
		assert.Equalf(t, tc.want, rec.Code, "%v", tc.err)
	}
}
