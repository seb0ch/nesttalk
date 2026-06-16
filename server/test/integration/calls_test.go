// Integration tests for the call lifecycle REST endpoints:
//   POST /api/v1/calls
//   POST /api/v1/calls/{id}/accept
//   POST /api/v1/calls/{id}/decline
//   POST /api/v1/calls/{id}/cancel
//   POST /api/v1/calls/{id}/end
//   GET  /api/v1/relay/session
//
// These tests wire directly through calls.Manager + the integration-test
// helper stack (intDeps). The route logic under test is the full FSM path
// including glare detection, state transitions, and relay credential generation.
package integration_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
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

// callsStack sets up a full test stack with two enrolled users.
// Returns the httptest server, tokens for alice+bob, and their user IDs.
type callsStack struct {
	srv          *httptest.Server
	callsMgr     *calls.Manager
	aliceToken   string
	aliceUserID  string
	bobToken     string
	bobUserID    string
}

func newCallsStack(t *testing.T) *callsStack {
	t.Helper()
	dir := t.TempDir()
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db, err := storage.OpenWithClock(filepath.Join(dir, "calls_int_test.db"), clock)
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	authSvc := auth.New(db)
	rosterSvc := roster.New(db)
	keysSvc := keys.New(db)
	hub := ws.NewHub()
	messagesSvc := messages.New(db, hub)
	reactionsSvc := reactions.New(db, hub)
	callsMgr := calls.New(db, hub)
	callsMgr.TURNSecret = "integration-test-secret"
	callsMgr.TURNHost = "turn.test.local"

	// Register routes including the calls endpoints via the intDeps helper.
	mux := http.NewServeMux()
	d := &callsIntDeps{
		auth:      authSvc,
		calls:     callsMgr,
		hub:       hub,
	}
	registerCallsRoutes(mux, d)
	// Also register auth routes (reuse the existing intDeps).
	base := &intDeps{
		db:        db,
		auth:      authSvc,
		roster:    rosterSvc,
		keys:      keysSvc,
		messages:  messagesSvc,
		reactions: reactionsSvc,
		hub:       hub,
	}
	mux.HandleFunc("GET /api/v1/health", base.health)
	mux.HandleFunc("POST /api/v1/auth/enroll/start", base.enrollStart)
	mux.HandleFunc("POST /api/v1/auth/enroll/complete", base.enrollComplete)
	mux.HandleFunc("POST /api/v1/auth/connect/challenge", base.connectChallenge)
	mux.HandleFunc("POST /api/v1/auth/connect/complete", base.connectComplete)

	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	ctrl := control.New(db, authSvc)

	// Enroll alice and bob through the control socket + auth service.
	alice := enrollAndConnect(t, srv, ctrl, "alice", 101)
	bob := enrollAndConnect(t, srv, ctrl, "bob", 102)

	return &callsStack{
		srv:         srv,
		callsMgr:    callsMgr,
		aliceToken:  alice.Token,
		aliceUserID: alice.UserID,
		bobToken:    bob.Token,
		bobUserID:   bob.UserID,
	}
}

type callsIntDeps struct {
	auth  *auth.Service
	calls *calls.Manager
	hub   *ws.Hub
}

func registerCallsRoutes(mux *http.ServeMux, d *callsIntDeps) {
	mux.HandleFunc("POST /api/v1/calls", callsRequireSession(d.auth, d.callCreate))
	mux.HandleFunc("POST /api/v1/calls/{id}/accept", callsRequireSession(d.auth, d.callAccept))
	mux.HandleFunc("POST /api/v1/calls/{id}/decline", callsRequireSession(d.auth, d.callDecline))
	mux.HandleFunc("POST /api/v1/calls/{id}/cancel", callsRequireSession(d.auth, d.callCancel))
	mux.HandleFunc("POST /api/v1/calls/{id}/end", callsRequireSession(d.auth, d.callEnd))
	mux.HandleFunc("GET /api/v1/relay/session", callsRequireSession(d.auth, d.relaySession))
}

func callsRequireSession(authSvc *auth.Service, h func(w http.ResponseWriter, r *http.Request, claims *auth.SessionClaims)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := ""
		if v := r.Header.Get("Authorization"); len(v) > 7 {
			token = v[7:]
		}
		claims, err := authSvc.ValidateSession(r.Context(), token)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		h(w, r, claims)
	}
}

func (d *callsIntDeps) callCreate(w http.ResponseWriter, r *http.Request, claims *auth.SessionClaims) {
	var req struct {
		CalleeUserID string `json:"callee_user_id"`
		Kind         string `json:"kind"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	kind := calls.CallKind(req.Kind)
	if kind == "" {
		kind = calls.KindAudio
	}
	result, err := d.calls.Create(r.Context(), calls.CreateRequest{
		CallerUserID: claims.UserID,
		CalleeUserID: req.CalleeUserID,
		Kind:         kind,
	})
	if err != nil {
		mapCallsErrInt(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"call_id": result.CallID, "state": result.State})
}

func (d *callsIntDeps) callAccept(w http.ResponseWriter, r *http.Request, claims *auth.SessionClaims) {
	callID := r.PathValue("id")
	result, err := d.calls.Accept(r.Context(), calls.AcceptRequest{
		CallID:        callID,
		SessionUserID: claims.UserID,
	})
	if err != nil {
		mapCallsErrInt(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"state": result.State})
}

func (d *callsIntDeps) callDecline(w http.ResponseWriter, r *http.Request, claims *auth.SessionClaims) {
	callID := r.PathValue("id")
	result, err := d.calls.Decline(r.Context(), calls.DeclineRequest{
		CallID:        callID,
		SessionUserID: claims.UserID,
	})
	if err != nil {
		mapCallsErrInt(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"state": result.State})
}

func (d *callsIntDeps) callCancel(w http.ResponseWriter, r *http.Request, claims *auth.SessionClaims) {
	callID := r.PathValue("id")
	result, err := d.calls.Cancel(r.Context(), calls.CancelRequest{
		CallID:        callID,
		SessionUserID: claims.UserID,
	})
	if err != nil {
		mapCallsErrInt(w, err)
		return
	}
	body := map[string]any{"state": result.State}
	if result.EndedReason != nil {
		body["ended_reason"] = *result.EndedReason
	}
	writeJSON(w, http.StatusOK, body)
}

func (d *callsIntDeps) callEnd(w http.ResponseWriter, r *http.Request, claims *auth.SessionClaims) {
	callID := r.PathValue("id")
	result, err := d.calls.End(r.Context(), calls.EndRequest{
		CallID:        callID,
		SessionUserID: claims.UserID,
	})
	if err != nil {
		mapCallsErrInt(w, err)
		return
	}
	body := map[string]any{"state": result.State}
	if result.EndedReason != nil {
		body["ended_reason"] = *result.EndedReason
	}
	writeJSON(w, http.StatusOK, body)
}

func (d *callsIntDeps) relaySession(w http.ResponseWriter, r *http.Request, claims *auth.SessionClaims) {
	creds, err := d.calls.RelayCredentials(r.Context(), claims.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, creds)
}

func mapCallsErrInt(w http.ResponseWriter, err error) {
	var glareErr *calls.GlareError
	var wsErr *calls.WrongStateError
	switch {
	case errors.As(err, &glareErr):
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":                   "glare",
			"existing_call_id":        glareErr.Info.ExistingCallID,
			"existing_caller_user_id": glareErr.Info.ExistingCallerUserID,
		})
	case errors.As(err, &wsErr):
		writeJSON(w, http.StatusConflict, map[string]any{
			"error": "wrong_state",
			"state": wsErr.Current,
		})
	case errors.Is(err, calls.ErrNotFound):
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "not found"})
	case errors.Is(err, calls.ErrNotAuthorized), errors.Is(err, calls.ErrCalleeOnly), errors.Is(err, calls.ErrCallerOnly):
		writeJSON(w, http.StatusForbidden, map[string]any{"error": err.Error()})
	default:
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
	}
}

// ----- HTTP helpers for calls tests -----

func callsPost(t *testing.T, srv *httptest.Server, path string, body any, token string) (int, map[string]any) {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		require.NoError(t, err)
		r = bytes.NewReader(b)
	} else {
		r = bytes.NewReader([]byte("{}"))
	}
	req, err := http.NewRequest("POST", srv.URL+path, r)
	require.NoError(t, err)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, out
}

func callsGet(t *testing.T, srv *httptest.Server, path, token string) (int, map[string]any) {
	t.Helper()
	req, err := http.NewRequest("GET", srv.URL+path, nil)
	require.NoError(t, err)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, out
}

// ----- Tests -----

func TestCallsIntegration_CreateAndAccept(t *testing.T) {
	s := newCallsStack(t)

	// Alice calls Bob.
	code, body := callsPost(t, s.srv, "/api/v1/calls", map[string]any{
		"callee_user_id": s.bobUserID,
		"kind":           "audio",
	}, s.aliceToken)
	require.Equal(t, http.StatusOK, code, "create call: %v", body)
	callID, _ := body["call_id"].(string)
	require.NotEmpty(t, callID)
	assert.Equal(t, "ringing", body["state"])

	// Bob accepts.
	code, body = callsPost(t, s.srv, "/api/v1/calls/"+callID+"/accept", nil, s.bobToken)
	require.Equal(t, http.StatusOK, code, "accept: %v", body)
	assert.Equal(t, "connected", body["state"])
}

func TestCallsIntegration_CreateAndDecline(t *testing.T) {
	s := newCallsStack(t)

	code, body := callsPost(t, s.srv, "/api/v1/calls", map[string]any{
		"callee_user_id": s.bobUserID,
		"kind":           "audio",
	}, s.aliceToken)
	require.Equal(t, http.StatusOK, code)
	callID, _ := body["call_id"].(string)

	// Bob declines.
	code, body = callsPost(t, s.srv, "/api/v1/calls/"+callID+"/decline", nil, s.bobToken)
	require.Equal(t, http.StatusOK, code, "decline: %v", body)
	assert.Equal(t, "declined", body["state"])
}

func TestCallsIntegration_CreateAndCancel(t *testing.T) {
	s := newCallsStack(t)

	code, body := callsPost(t, s.srv, "/api/v1/calls", map[string]any{
		"callee_user_id": s.bobUserID,
		"kind":           "audio",
	}, s.aliceToken)
	require.Equal(t, http.StatusOK, code)
	callID, _ := body["call_id"].(string)

	// Alice cancels before Bob answers.
	code, body = callsPost(t, s.srv, "/api/v1/calls/"+callID+"/cancel", nil, s.aliceToken)
	require.Equal(t, http.StatusOK, code, "cancel: %v", body)
	assert.Equal(t, "cancelled", body["state"])
}

func TestCallsIntegration_End(t *testing.T) {
	s := newCallsStack(t)

	code, body := callsPost(t, s.srv, "/api/v1/calls", map[string]any{
		"callee_user_id": s.bobUserID,
		"kind":           "audio",
	}, s.aliceToken)
	require.Equal(t, http.StatusOK, code)
	callID, _ := body["call_id"].(string)

	_, _ = callsPost(t, s.srv, "/api/v1/calls/"+callID+"/accept", nil, s.bobToken)

	// Alice ends.
	code, body = callsPost(t, s.srv, "/api/v1/calls/"+callID+"/end", nil, s.aliceToken)
	require.Equal(t, http.StatusOK, code, "end: %v", body)
	assert.Equal(t, "ended", body["state"])
	assert.Equal(t, "normal", body["ended_reason"])
}

func TestCallsIntegration_Glare(t *testing.T) {
	s := newCallsStack(t)

	// Alice calls Bob.
	code, body := callsPost(t, s.srv, "/api/v1/calls", map[string]any{
		"callee_user_id": s.bobUserID,
		"kind":           "audio",
	}, s.aliceToken)
	require.Equal(t, http.StatusOK, code)
	firstCallID, _ := body["call_id"].(string)
	require.NotEmpty(t, firstCallID)

	// Bob also tries to call Alice while Alice's call is ringing → glare 409.
	code, body = callsPost(t, s.srv, "/api/v1/calls", map[string]any{
		"callee_user_id": s.aliceUserID,
		"kind":           "audio",
	}, s.bobToken)
	assert.Equal(t, http.StatusConflict, code, "expected glare 409, got: %v", body)
	assert.Equal(t, "glare", body["error"])
}

func TestCallsIntegration_CancelAfterConnect(t *testing.T) {
	s := newCallsStack(t)

	code, body := callsPost(t, s.srv, "/api/v1/calls", map[string]any{
		"callee_user_id": s.bobUserID,
		"kind":           "audio",
	}, s.aliceToken)
	require.Equal(t, http.StatusOK, code)
	callID, _ := body["call_id"].(string)

	_, _ = callsPost(t, s.srv, "/api/v1/calls/"+callID+"/accept", nil, s.bobToken)

	// Alice cancels after the call is already connected.
	code, body = callsPost(t, s.srv, "/api/v1/calls/"+callID+"/cancel", nil, s.aliceToken)
	require.Equal(t, http.StatusOK, code, "cancel-after-connect: %v", body)
	assert.Equal(t, "ended", body["state"])
	assert.Equal(t, "auto_ended_from_cancel", body["ended_reason"])
}

func TestCallsIntegration_RelaySession(t *testing.T) {
	s := newCallsStack(t)

	code, body := callsGet(t, s.srv, "/api/v1/relay/session", s.aliceToken)
	require.Equal(t, http.StatusOK, code, "relay/session: %v", body)
	assert.NotEmpty(t, body["username"])
	assert.NotEmpty(t, body["password"])
	assert.Equal(t, float64(900), body["ttl_seconds"])
	urls, _ := body["urls"].([]any)
	require.Len(t, urls, 1)
	assert.Equal(t, "turn:turn.test.local:3478", urls[0])
}

func TestCallsIntegration_CallerCannotAccept(t *testing.T) {
	s := newCallsStack(t)

	code, body := callsPost(t, s.srv, "/api/v1/calls", map[string]any{
		"callee_user_id": s.bobUserID,
		"kind":           "audio",
	}, s.aliceToken)
	require.Equal(t, http.StatusOK, code)
	callID, _ := body["call_id"].(string)

	// Alice (caller) tries to accept her own call → 403.
	code, _ = callsPost(t, s.srv, "/api/v1/calls/"+callID+"/accept", nil, s.aliceToken)
	assert.Equal(t, http.StatusForbidden, code)
}

func TestCallsIntegration_EndWhileRinging(t *testing.T) {
	s := newCallsStack(t)

	code, body := callsPost(t, s.srv, "/api/v1/calls", map[string]any{
		"callee_user_id": s.bobUserID,
		"kind":           "audio",
	}, s.aliceToken)
	require.Equal(t, http.StatusOK, code)
	callID, _ := body["call_id"].(string)

	// Can't end while ringing → 409.
	code, body = callsPost(t, s.srv, "/api/v1/calls/"+callID+"/end", nil, s.aliceToken)
	assert.Equal(t, http.StatusConflict, code, "expected 409: %v", body)
}

func TestCallsIntegration_MissedSweep(t *testing.T) {
	s := newCallsStack(t)
	// Access the clock via the calls manager's db clock.
	clock := s.callsMgr.DB.Clock.(*storage.FixedClock)

	_, body := callsPost(t, s.srv, "/api/v1/calls", map[string]any{
		"callee_user_id": s.bobUserID,
		"kind":           "audio",
	}, s.aliceToken)
	callID, _ := body["call_id"].(string)

	// Advance clock past 33s + 3s grace.
	clock.T += 37_000

	n, err := s.callsMgr.RunMissedSweepCount(context.Background())
	require.NoError(t, err)
	assert.GreaterOrEqual(t, n, 1, "expected at least 1 missed call")

	// Bob's attempt to accept now → 409 wrong_state.
	code, body := callsPost(t, s.srv, "/api/v1/calls/"+callID+"/accept", nil, s.bobToken)
	assert.Equal(t, http.StatusConflict, code, "expected 409 for missed call: %v", body)
	assert.Equal(t, "wrong_state", body["error"])
}
