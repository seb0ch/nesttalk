package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/seb0ch/nesttalk/server/internal/auth"
	"github.com/seb0ch/nesttalk/server/internal/calls"
	"github.com/seb0ch/nesttalk/server/internal/keys"
	"github.com/seb0ch/nesttalk/server/internal/messages"
	"github.com/seb0ch/nesttalk/server/internal/reactions"
	"github.com/seb0ch/nesttalk/server/internal/roster"
	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/trace"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// Deps bundles the per-process services for the HTTP/WS layer.
type Deps struct {
	DB        *storage.DB
	Auth      *auth.Service
	Roster    *roster.Service
	Keys      *keys.Service
	Messages  *messages.Service
	Reactions *reactions.Service
	Calls     *calls.Manager
	Hub       *ws.Hub
	Typing    *messages.TypingTracker
	// AllowedOrigins is the OriginPatterns whitelist passed to the
	// WebSocket handshake. Empty disables origin verification, which is
	// only safe in tests; main.go always populates a default.
	AllowedOrigins []string
}

// RegisterRoutes wires every v0.2.0 endpoint onto mux.
func RegisterRoutes(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/v1/health", d.health)
	mux.HandleFunc("POST /api/v1/auth/enroll/start", d.enrollStart)
	mux.HandleFunc("POST /api/v1/auth/enroll/complete", d.enrollComplete)
	mux.HandleFunc("POST /api/v1/auth/connect/challenge", d.connectChallenge)
	mux.HandleFunc("POST /api/v1/auth/connect/complete", d.connectComplete)
	mux.HandleFunc("GET /api/v1/roster", d.requireSession(d.roster))
	mux.HandleFunc("GET /api/v1/keys/message/{userId}", d.requireSession(d.messageKeys))
	mux.HandleFunc("POST /api/v1/messages", d.requireSession(d.messagesPost))
	mux.HandleFunc("GET /api/v1/messages/pending", d.requireSession(d.messagesPending))
	mux.HandleFunc("POST /api/v1/messages/{id}/ack", d.requireSession(d.messageAck))
	mux.HandleFunc("GET /api/v1/messages/{id}/status", d.requireSession(d.messageStatus))
	mux.HandleFunc("PUT /api/v1/messages/{id}/reactions", d.requireSession(d.reactionPut))
	mux.HandleFunc("GET /api/v1/reactions/since", d.requireSession(d.reactionsSince))
	// Calls (Slice 4)
	mux.HandleFunc("POST /api/v1/calls", d.requireSession(d.callCreate))
	mux.HandleFunc("POST /api/v1/calls/{id}/accept", d.requireSession(d.callAccept))
	mux.HandleFunc("POST /api/v1/calls/{id}/decline", d.requireSession(d.callDecline))
	mux.HandleFunc("POST /api/v1/calls/{id}/cancel", d.requireSession(d.callCancel))
	mux.HandleFunc("POST /api/v1/calls/{id}/end", d.requireSession(d.callEnd))
	// Relay
	mux.HandleFunc("GET /api/v1/relay/session", d.requireSession(d.relaySession))
	mux.HandleFunc("POST /api/v1/devices/push-token", d.requireSession(d.devicePushTokenPut))
	mux.HandleFunc("/api/v1/ws/control", d.requireSession(d.wsControl))
}

// ----- helpers -----

type errBody struct {
	Error  string `json:"error"`
	Reason string `json:"reason,omitempty"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg, reason string) {
	writeJSON(w, status, errBody{Error: msg, Reason: reason})
}

// ----- health -----

func (d *Deps) health(w http.ResponseWriter, r *http.Request) {
	var (
		generation int64
		kid        string
	)
	if err := d.DB.QueryRowContext(r.Context(),
		`SELECT generation, jwt_kid FROM server_runtime_state WHERE singleton = 1`,
	).Scan(&generation, &kid); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error(), "")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"server_time": d.DB.Clock.NowMillis(),
		"generation":  generation,
		"jwt_kid":     kid,
		"api_version": "v0.2.0",
	})
}

// ----- enroll -----

type enrollStartReq struct {
	Code string `json:"code"`
}
type enrollStartResp struct {
	Challenge string `json:"challenge"`
}

func (d *Deps) enrollStart(w http.ResponseWriter, r *http.Request) {
	var req enrollStartReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Code == "" {
		writeErr(w, http.StatusBadRequest, "code required", "")
		return
	}
	res, err := d.Auth.EnrollStart(r.Context(), req.Code)
	if err != nil {
		mapAuthErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, enrollStartResp{
		Challenge: base64.StdEncoding.EncodeToString(res.Challenge),
	})
}

type enrollCompleteReq struct {
	Code          string `json:"code"`
	DevicePubkey  string `json:"device_pubkey"`
	MessagePubkey string `json:"message_pubkey"`
	Attestation   string `json:"attestation"`
}
type enrollCompleteResp struct {
	UserID      string `json:"user_id"`
	DeviceID    string `json:"device_id"`
	DisplayName string `json:"display_name"`
	ColorHint   int    `json:"color_hint"`
}

func (d *Deps) enrollComplete(w http.ResponseWriter, r *http.Request) {
	var req enrollCompleteReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json", "")
		return
	}
	devicePubkey, err := base64.StdEncoding.DecodeString(req.DevicePubkey)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "device_pubkey must be base64", "")
		return
	}
	messagePubkey, err := base64.StdEncoding.DecodeString(req.MessagePubkey)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "message_pubkey must be base64", "")
		return
	}
	attestation, err := base64.StdEncoding.DecodeString(req.Attestation)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "attestation must be base64", "")
		return
	}
	res, err := d.Auth.EnrollComplete(r.Context(), req.Code, devicePubkey, messagePubkey, attestation)
	if err != nil {
		mapAuthErr(w, err)
		return
	}
	// Re-enroll/device-replacement revoked the prior device(s): close their
	// live WS sessions NOW so a revoked device loses fan-out + send access
	// immediately, rather than lingering until the 30s revalidation tick.
	if d.Hub != nil {
		for _, deviceID := range res.RevokedDeviceIDs {
			d.Hub.DisconnectDevice(deviceID)
		}
	}
	writeJSON(w, http.StatusOK, enrollCompleteResp{
		UserID:      res.UserID,
		DeviceID:    res.DeviceID,
		DisplayName: res.DisplayName,
		ColorHint:   res.ColorHint,
	})
}

// ----- connect -----

type connectChallengeReq struct {
	DeviceID string `json:"device_id"`
}
type connectChallengeResp struct {
	Nonce string `json:"nonce"`
}

func (d *Deps) connectChallenge(w http.ResponseWriter, r *http.Request) {
	var req connectChallengeReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.DeviceID == "" {
		writeErr(w, http.StatusBadRequest, "device_id required", "")
		return
	}
	res, err := d.Auth.ConnectChallenge(r.Context(), req.DeviceID)
	if err != nil {
		mapAuthErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, connectChallengeResp{
		Nonce: base64.StdEncoding.EncodeToString(res.Nonce),
	})
}

type connectCompleteReq struct {
	DeviceID    string `json:"device_id"`
	Nonce       string `json:"nonce"`
	Attestation string `json:"attestation"`
}
type connectCompleteResp struct {
	SessionToken string `json:"session_token"`
	ExpiresAt    int64  `json:"expires_at"`
	UserID       string `json:"user_id"`
}

func (d *Deps) connectComplete(w http.ResponseWriter, r *http.Request) {
	var req connectCompleteReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json", "")
		return
	}
	nonce, err := base64.StdEncoding.DecodeString(req.Nonce)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "nonce must be base64", "")
		return
	}
	attestation, err := base64.StdEncoding.DecodeString(req.Attestation)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "attestation must be base64", "")
		return
	}
	res, err := d.Auth.ConnectComplete(r.Context(), req.DeviceID, nonce, attestation)
	if err != nil {
		mapAuthErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, connectCompleteResp{
		SessionToken: res.SessionToken,
		ExpiresAt:    res.ExpiresAt,
		UserID:       res.UserID,
	})
}

// ----- session middleware -----

type ctxKey string

const sessionCtxKey ctxKey = "session"

func (d *Deps) requireSession(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := bearerToken(r)
		if token == "" {
			writeErr(w, http.StatusUnauthorized, "missing bearer", "missing_token")
			return
		}
		claims, err := d.Auth.ValidateSession(r.Context(), token)
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "invalid session", "session_invalid")
			return
		}
		ctx := context.WithValue(r.Context(), sessionCtxKey, claims)
		h(w, r.WithContext(ctx))
	}
}

func bearerToken(r *http.Request) string {
	if v := r.Header.Get("Authorization"); strings.HasPrefix(v, "Bearer ") {
		return strings.TrimSpace(v[len("Bearer "):])
	}
	// WebSocket fallback: browsers and Flutter clients cannot attach a
	// custom Authorization header on the WS upgrade, so the session token
	// is offered as the first Sec-WebSocket-Protocol entry. wsControl
	// echoes the same value back via AcceptOptions.Subprotocols so the
	// handshake completes cleanly.
	if v := r.Header.Get("Sec-WebSocket-Protocol"); v != "" {
		for _, p := range strings.Split(v, ",") {
			if p = strings.TrimSpace(p); p != "" {
				return p
			}
		}
	}
	return ""
}

func sessionFrom(r *http.Request) *auth.SessionClaims {
	v, _ := r.Context().Value(sessionCtxKey).(*auth.SessionClaims)
	return v
}

// ----- roster -----

func (d *Deps) roster(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	entries, err := d.Roster.List(r.Context(), claims.UserID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error(), "")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"roster": entries})
}

// ----- keys -----

func (d *Deps) messageKeys(w http.ResponseWriter, r *http.Request) {
	userID := r.PathValue("userId")
	if userID == "" {
		writeErr(w, http.StatusBadRequest, "userId required", "")
		return
	}
	entries, err := d.Keys.MessageKeys(r.Context(), userID)
	if err != nil {
		if errors.Is(err, keys.ErrUserNotFound) {
			writeErr(w, http.StatusNotFound, "user not found", "")
			return
		}
		writeErr(w, http.StatusInternalServerError, err.Error(), "")
		return
	}
	// Surface base64 strings rather than raw bytes for JSON consumers.
	type devKey struct {
		DeviceID      string `json:"device_id"`
		PublicKey     string `json:"public_key"`
		MessagePubkey string `json:"message_pubkey"`
		EnrolledAt    int64  `json:"enrolled_at"`
		RevokedAt     *int64 `json:"revoked_at"`
	}
	out := make([]devKey, 0, len(entries))
	for _, e := range entries {
		out = append(out, devKey{
			DeviceID:      e.DeviceID,
			PublicKey:     base64.StdEncoding.EncodeToString(e.PublicKey),
			MessagePubkey: base64.StdEncoding.EncodeToString(e.MessagePubKey),
			EnrolledAt:    e.EnrolledAt,
			RevokedAt:     e.RevokedAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

// ----- messages -----

type messagesPostReq struct {
	Envelope  string  `json:"envelope"`
	SentAt    int64   `json:"sent_at"`
	ReplyToID *string `json:"reply_to_id"`
}

func (d *Deps) messagesPost(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	var req messagesPostReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json", "")
		return
	}
	if req.Envelope == "" {
		writeErr(w, http.StatusBadRequest, "envelope required", "")
		return
	}
	envBytes, err := base64.StdEncoding.DecodeString(req.Envelope)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "envelope must be base64", "")
		return
	}
	res, err := d.Messages.Post(r.Context(), messages.PostRequest{
		EnvelopeBytes:   envBytes,
		SentAt:          req.SentAt,
		ReplyToID:       req.ReplyToID,
		SessionUserID:   claims.UserID,
		SessionDeviceID: claims.DeviceID,
	})
	if err != nil {
		trace.Logf(r.Context(), "message rejected from=%s: %v", claims.UserID, err)
		mapMessagesErr(w, err)
		return
	}
	trace.Logf(r.Context(), "message accepted id=%s from=%s", res.ID, claims.UserID)
	writeJSON(w, http.StatusOK, map[string]any{
		"id":          res.ID,
		"received_at": res.ReceivedAt,
		"sent_at":     res.SentAt,
	})
}

func (d *Deps) messagesPending(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	q := r.URL.Query()
	limit := 100
	if v := q.Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	sinceReceivedAt, _ := strconv.ParseInt(q.Get("since_received_at"), 10, 64)
	sinceID := q.Get("since_id")

	res, err := d.Messages.Pending(r.Context(), messages.PendingRequest{
		RecipientUserID: claims.UserID,
		SinceReceivedAt: sinceReceivedAt,
		SinceID:         sinceID,
		Limit:           limit,
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error(), "")
		return
	}
	// Serialize messages with base64 envelope.
	type msgJSON struct {
		ID           string  `json:"id"`
		SenderUserID string  `json:"sender_user_id"`
		Envelope     string  `json:"envelope"`
		ReplyToID    *string `json:"reply_to_id"`
		SentAt       int64   `json:"sent_at"`
		ReceivedAt   int64   `json:"received_at"`
	}
	out := make([]msgJSON, 0, len(res.Messages))
	for _, m := range res.Messages {
		out = append(out, msgJSON{
			ID:           m.ID,
			SenderUserID: m.SenderUserID,
			Envelope:     base64.StdEncoding.EncodeToString(m.Envelope),
			ReplyToID:    m.ReplyToID,
			SentAt:       m.SentAt,
			ReceivedAt:   m.ReceivedAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"messages":    out,
		"next_cursor": res.NextCursor,
	})
}

type messageAckReq struct {
	Kind string `json:"kind"`
}

func (d *Deps) messageAck(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	msgID := r.PathValue("id")
	var req messageAckReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json", "")
		return
	}
	err := d.Messages.Ack(r.Context(), messages.AckRequest{
		MessageID:     msgID,
		Kind:          req.Kind,
		SessionUserID: claims.UserID,
	})
	if err != nil {
		mapMessagesErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (d *Deps) messageStatus(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	msgID := r.PathValue("id")
	status, err := d.Messages.Status(r.Context(), messages.StatusRequest{
		MessageID:     msgID,
		SessionUserID: claims.UserID,
	})
	if err != nil {
		mapMessagesErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": status})
}

// ----- reactions -----

type reactionPutReq struct {
	Envelope string `json:"envelope"`
	SentAt   int64  `json:"sent_at"`
}

func (d *Deps) reactionPut(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	msgID := r.PathValue("id")
	var req reactionPutReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json", "")
		return
	}
	if req.Envelope == "" {
		writeErr(w, http.StatusBadRequest, "envelope required", "")
		return
	}
	envBytes, err := base64.StdEncoding.DecodeString(req.Envelope)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "envelope must be base64", "")
		return
	}
	res, err := d.Reactions.Put(r.Context(), reactions.PutRequest{
		MessageID:       msgID,
		EnvelopeBytes:   envBytes,
		SentAt:          req.SentAt,
		SessionUserID:   claims.UserID,
		SessionDeviceID: claims.DeviceID,
	})
	if err != nil {
		mapReactionsErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":          res.ID,
		"received_at": res.ReceivedAt,
	})
}

func (d *Deps) reactionsSince(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	q := r.URL.Query()
	limit := 100
	if v := q.Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	sinceReceivedAt, _ := strconv.ParseInt(q.Get("since_received_at"), 10, 64)
	sinceID := q.Get("since_id")
	if sinceID == "" {
		sinceID = "00000000-0000-0000-0000-000000000000"
	}

	res, err := d.Reactions.Since(r.Context(), reactions.SinceRequest{
		RecipientUserID: claims.UserID,
		SinceReceivedAt: sinceReceivedAt,
		SinceID:         sinceID,
		Limit:           limit,
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error(), "")
		return
	}

	type rxnJSON struct {
		ID           string `json:"id"`
		MessageID    string `json:"message_id"`
		SenderUserID string `json:"sender_user_id"`
		Envelope     string `json:"envelope"`
		SentAt       int64  `json:"sent_at"`
		ReceivedAt   int64  `json:"received_at"`
	}
	out := make([]rxnJSON, 0, len(res.Reactions))
	for _, rx := range res.Reactions {
		out = append(out, rxnJSON{
			ID:           rx.ID,
			MessageID:    rx.MessageID,
			SenderUserID: rx.SenderUserID,
			Envelope:     base64.StdEncoding.EncodeToString(rx.Envelope),
			SentAt:       rx.SentAt,
			ReceivedAt:   rx.ReceivedAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"reactions":   out,
		"next_cursor": res.NextCursor,
	})
}

func mapReactionsErr(w http.ResponseWriter, err error) {
	var rdr *messages.RecipientDeviceRotatedError
	switch {
	case errors.Is(err, reactions.ErrEnvelopeMalformed):
		writeErr(w, http.StatusBadRequest, err.Error(), "envelope_malformed")
	case errors.As(err, &rdr):
		// Same 403 body shape as the messages path so the client's
		// rotation handling (re-fetch keys, re-seal, retry) is uniform.
		body := map[string]any{
			"error":  "recipient_device_rotated",
			"reason": "recipient_device_rotated",
		}
		if rdr.ActiveDeviceID != "" {
			body["active_recipient_device_id"] = rdr.ActiveDeviceID
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(body)
	case errors.Is(err, reactions.ErrNotAuthorized):
		writeErr(w, http.StatusForbidden, err.Error(), "not_authorized")
	case errors.Is(err, reactions.ErrParentPurged):
		writeErr(w, http.StatusGone, "parent message has been purged", "parent_purged")
	default:
		writeErr(w, http.StatusInternalServerError, err.Error(), "")
	}
}

// ----- ws -----

type wsInboundMsg struct {
	Type     string         `json:"type"`
	To       string         `json:"to"`
	CallID   string         `json:"call_id"`
	SignalID string         `json:"signal_id"`
	Payload  map[string]any `json:"payload"`
}

// maxControlReadBytes hard-caps a single inbound control-WS frame. It must
// comfortably exceed the largest legitimate frame (a call_signal carrying an
// SDP offer ≤ maxSignalPayloadBytes plus its small JSON envelope) while
// bounding what an authenticated client can force the server to buffer per
// read. coder/websocket defaults to 32 KiB; we set it explicitly so the bound
// is visible and intentional.
const maxControlReadBytes = 32 * 1024

func (d *Deps) wsControl(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	// If the client offered its session token via Sec-WebSocket-Protocol
	// (the only way Flutter / browser clients can carry auth across the
	// WS upgrade), echo the same value back so the handshake finishes
	// with a negotiated subprotocol. Without this, coder/websocket
	// refuses to complete the handshake and the client loops reconnect.
	var subprotocols []string
	if v := r.Header.Get("Sec-WebSocket-Protocol"); v != "" {
		for _, p := range strings.Split(v, ",") {
			if p = strings.TrimSpace(p); p != "" {
				subprotocols = append(subprotocols, p)
			}
		}
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Enforce Origin against the configured whitelist. Empty patterns
		// only happen in tests; main.go always supplies a default.
		OriginPatterns: d.AllowedOrigins,
		Subprotocols:   subprotocols,
	})
	if err != nil {
		return
	}
	// Bound a single inbound frame so a participant can't force a huge
	// allocation per read. A frame over the limit fails the Read (closing the
	// socket), which is the correct outcome for an abusive client.
	conn.SetReadLimit(maxControlReadBytes)
	sess := &ws.Session{
		UserID:   claims.UserID,
		DeviceID: claims.DeviceID,
		Out:      make(chan []byte, 64),
	}
	// Sever the socket at the protocol level the moment the hub closes this
	// session (revoke, re-enroll, or same-device re-handshake). Closing the
	// outbound channel only unblocks the writer; without this the reader
	// below keeps relaying typing / call_signal under the now-revoked
	// upgrade-time claims until its next read errors. coder/websocket's
	// Close is safe to call concurrently with the in-flight Read/Write and
	// unblocks them. Set before Register so a revoke racing the register
	// still tears the connection down.
	sess.OnClose = func() {
		_ = conn.Close(websocket.StatusPolicyViolation, "session closed")
	}
	d.Hub.Register(sess)
	defer func() {
		d.Hub.Unregister(sess)
		if d.Typing != nil {
			d.Typing.OnSessionClose(claims.UserID)
		}
	}()

	// Revalidation goroutine: a session is validated only at the WS
	// upgrade, so a revoke after that would otherwise be invisible to a
	// live socket. The control-socket revoke path closes sessions
	// directly (the deterministic mechanism); this periodic re-check is
	// defense-in-depth and also catches a generation bump (server
	// restore) for long-lived sockets.
	go func() {
		token := bearerToken(r)
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-r.Context().Done():
				return
			case <-ticker.C:
				if _, err := d.Auth.ValidateSession(r.Context(), token); err != nil {
					_ = conn.Close(websocket.StatusPolicyViolation, "session revoked")
					return
				}
			}
		}
	}()

	// Reader goroutine: handle inbound typing_start and call_signal frames.
	go func() {
		for {
			_, payload, err := conn.Read(r.Context())
			if err != nil {
				// The socket is dead. Unregister NOW — closing sess.Out
				// lets the writer's `range` exit promptly. Without this the
				// writer blocks forever waiting for an event that never
				// comes, the deferred Unregister never runs, and the zombie
				// session keeps Hub.IsConnected true — which makes the
				// stale-call sweep treat the user as live and skip ending
				// abandoned calls, leaving glare-blocking rows behind.
				d.Hub.Unregister(sess)
				return
			}
			var msg wsInboundMsg
			if err := json.Unmarshal(payload, &msg); err != nil {
				continue
			}
			switch msg.Type {
			case "typing_start":
				if d.Typing != nil && msg.To != "" {
					d.Typing.HandleTypingStart(claims.UserID, msg.To)
				}
			case "call_signal":
				// Relay the WebRTC offer/answer/ICE payload to the call's
				// peer. Errors (unknown call, non-participant, terminal
				// state) are dropped — the signaling layer retries through
				// call state changes, and a noisy client must not kill the
				// read loop. On acceptance, ACK the sender by signal_id so
				// it can stop retaining + replaying the signal.
				if d.Calls != nil && msg.CallID != "" && msg.Payload != nil {
					if err := d.Calls.RelaySignal(r.Context(), msg.CallID, claims.UserID, msg.SignalID, msg.Payload); err == nil && msg.SignalID != "" {
						d.Hub.SendToUser(claims.UserID, ws.CallSignalAck(msg.CallID, msg.SignalID, d.Calls.Clock.NowMillis()))
					}
				}
			}
		}
	}()

	for body := range sess.Out {
		if err := conn.Write(r.Context(), websocket.MessageText, body); err != nil {
			// The socket is dead, but SendToUser already reported this
			// frame (and any still buffered behind it) as delivered. Stop
			// new sends, then salvage the buffered frames so call_signal
			// SDP/ICE replays on the peer's reconnect instead of vanishing.
			d.Hub.Unregister(sess) // idempotent with the defer; closes sess.Out
			undelivered := [][]byte{body}
			for b := range sess.Out {
				undelivered = append(undelivered, b)
			}
			if d.Calls != nil {
				d.Calls.RequeueUndeliveredSignals(claims.UserID, undelivered)
			}
			return
		}
	}
	_ = conn.Close(websocket.StatusNormalClosure, "")
}

// ----- error mapping -----

func mapMessagesErr(w http.ResponseWriter, err error) {
	var rdr *messages.RecipientDeviceRotatedError
	switch {
	case errors.Is(err, messages.ErrEnvelopeMalformed):
		writeErr(w, http.StatusBadRequest, err.Error(), "envelope_malformed")
	case errors.Is(err, messages.ErrNotAuthorized):
		writeErr(w, http.StatusForbidden, err.Error(), "not_authorized")
	case errors.Is(err, messages.ErrRecipientRevoked):
		writeErr(w, http.StatusForbidden, err.Error(), "recipient_revoked")
	case errors.As(err, &rdr):
		// Spec line 527: 403 body must carry both "error" and "reason" fields.
		body := map[string]any{
			"error":  "recipient_device_rotated",
			"reason": "recipient_device_rotated",
		}
		if rdr.ActiveDeviceID != "" {
			body["active_recipient_device_id"] = rdr.ActiveDeviceID
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(body)
	case errors.Is(err, messages.ErrMessageExpired):
		writeErr(w, http.StatusGone, "message envelope expired", "")
	case errors.Is(err, messages.ErrInvalidAckKind):
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": "invalid kind", "field": "kind"})
	case errors.Is(err, messages.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not found", "")
	default:
		writeErr(w, http.StatusInternalServerError, err.Error(), "")
	}
}

// ----- calls -----

type callCreateReq struct {
	CalleeUserID string `json:"callee_user_id"`
	Kind         string `json:"kind"`
}

func (d *Deps) callCreate(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	var req callCreateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json", "")
		return
	}
	if req.CalleeUserID == "" {
		writeErr(w, http.StatusBadRequest, "callee_user_id required", "")
		return
	}
	kind := calls.CallKind(req.Kind)
	if kind == "" {
		kind = calls.KindAudio
	}
	result, err := d.Calls.Create(r.Context(), calls.CreateRequest{
		CallerUserID: claims.UserID,
		CalleeUserID: req.CalleeUserID,
		Kind:         kind,
	})
	if err != nil {
		mapCallsErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"call_id": result.CallID,
		"state":   result.State,
	})
}

func (d *Deps) callAccept(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	callID := r.PathValue("id")
	result, err := d.Calls.Accept(r.Context(), calls.AcceptRequest{
		CallID:        callID,
		SessionUserID: claims.UserID,
	})
	if err != nil {
		mapCallsErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"state": result.State})
}

func (d *Deps) callDecline(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	callID := r.PathValue("id")
	result, err := d.Calls.Decline(r.Context(), calls.DeclineRequest{
		CallID:        callID,
		SessionUserID: claims.UserID,
	})
	if err != nil {
		mapCallsErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"state": result.State})
}

func (d *Deps) callCancel(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	callID := r.PathValue("id")
	result, err := d.Calls.Cancel(r.Context(), calls.CancelRequest{
		CallID:        callID,
		SessionUserID: claims.UserID,
	})
	if err != nil {
		mapCallsErr(w, err)
		return
	}
	body := map[string]any{"state": result.State}
	if result.EndedReason != nil {
		body["ended_reason"] = *result.EndedReason
	}
	writeJSON(w, http.StatusOK, body)
}

func (d *Deps) callEnd(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	callID := r.PathValue("id")
	result, err := d.Calls.End(r.Context(), calls.EndRequest{
		CallID:        callID,
		SessionUserID: claims.UserID,
	})
	if err != nil {
		mapCallsErr(w, err)
		return
	}
	body := map[string]any{"state": result.State}
	if result.EndedReason != nil {
		body["ended_reason"] = *result.EndedReason
	}
	writeJSON(w, http.StatusOK, body)
}

// ----- relay -----

func (d *Deps) relaySession(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	if d.Calls == nil {
		writeErr(w, http.StatusServiceUnavailable, "relay not configured", "")
		return
	}
	creds, err := d.Calls.RelayCredentials(r.Context(), claims.UserID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error(), "")
		return
	}
	writeJSON(w, http.StatusOK, creds)
}

// mapCallsErr translates calls package sentinel errors to HTTP status codes.
func mapCallsErr(w http.ResponseWriter, err error) {
	var glareErr *calls.GlareError
	var busyErr *calls.BusyError
	var wsErr *calls.WrongStateError

	switch {
	case errors.As(err, &busyErr):
		// Cross-pair busy: the requester is NOT a participant in the blocking
		// call, so the response must NOT disclose the existing call's id,
		// caller, kind, or state (that would leak a third party's activity and
		// — when the dialed peer is a callee — the third-party caller's user
		// id). Only `busy_user_id` is returned, and it is always one of the
		// requester's own intended participants (self or the dialed peer).
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"error":        "busy",
			"busy_user_id": busyErr.BusyUserID,
		})
	case errors.As(err, &glareErr):
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"error":                   "glare",
			"state":                   "ringing",
			"existing_call_id":        glareErr.Info.ExistingCallID,
			"existing_caller_user_id": glareErr.Info.ExistingCallerUserID,
			"existing_call_kind":      glareErr.Info.ExistingCallKind,
			"existing_call_state":     glareErr.Info.ExistingState,
		})
	case errors.As(err, &wsErr):
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"error": "wrong_state",
			"state": wsErr.Current,
		})
	case errors.Is(err, calls.ErrNotFound):
		writeErr(w, http.StatusNotFound, "call not found", "")
	case errors.Is(err, calls.ErrNotAuthorized):
		writeErr(w, http.StatusForbidden, err.Error(), "not_authorized")
	case errors.Is(err, calls.ErrCalleeOnly):
		writeErr(w, http.StatusForbidden, err.Error(), "callee_only")
	case errors.Is(err, calls.ErrCallerOnly):
		writeErr(w, http.StatusForbidden, err.Error(), "caller_only")
	default:
		writeErr(w, http.StatusInternalServerError, err.Error(), "")
	}
}

func mapAuthErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, auth.ErrLinkGone), errors.Is(err, auth.ErrLinkConsumed):
		writeErr(w, http.StatusGone, err.Error(), "")
	case errors.Is(err, auth.ErrInvalidAttestation):
		writeErr(w, http.StatusBadRequest, err.Error(), "invalid_attestation")
	case errors.Is(err, auth.ErrUserRevoked):
		writeErr(w, http.StatusForbidden, err.Error(), "user_revoked")
	case errors.Is(err, auth.ErrNonceInvalid):
		writeErr(w, http.StatusUnauthorized, err.Error(), "nonce_invalid")
	case errors.Is(err, auth.ErrDeviceNotFound):
		writeErr(w, http.StatusUnauthorized, err.Error(), "device_not_found")
	case errors.Is(err, auth.ErrSessionExpired):
		writeErr(w, http.StatusUnauthorized, err.Error(), "jwt_expired")
	default:
		writeErr(w, http.StatusInternalServerError, err.Error(), "")
	}
}

// ----- device push token (v0.4.0) -----

type devicePushTokenReq struct {
	Token string `json:"token"`
	Env   string `json:"env"`
}

// devicePushTokenPut upserts a VoIP push token for the calling device.
// Body: {token: "<hex>", env: "dev"|"prod"}. The token is the raw
// PKPushCredentials.token bytes hex-encoded; env distinguishes the
// APNs sandbox endpoint from production. We refuse anything else.
func (d *Deps) devicePushTokenPut(w http.ResponseWriter, r *http.Request) {
	claims := sessionFrom(r)
	var req devicePushTokenReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json", "")
		return
	}
	if len(req.Token) != 64 {
		writeErr(w, http.StatusBadRequest, "token must be 64 hex chars", "")
		return
	}
	for _, c := range req.Token {
		ok := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !ok {
			writeErr(w, http.StatusBadRequest, "token must be hex", "")
			return
		}
	}
	if req.Env != "dev" && req.Env != "prod" {
		writeErr(w, http.StatusBadRequest, "env must be dev or prod", "")
		return
	}
	res, err := d.DB.ExecContext(r.Context(),
		`UPDATE devices SET voip_push_token = ?, voip_push_env = ? WHERE id = ?`,
		req.Token, req.Env, claims.DeviceID,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error(), "")
		return
	}
	// A token for an unknown / revoked device id must not silently 204:
	// the row count tells us whether the registration actually landed.
	if n, err := res.RowsAffected(); err == nil && n == 0 {
		writeErr(w, http.StatusNotFound, "device not found", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
