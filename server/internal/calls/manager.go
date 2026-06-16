// Package calls implements the v0.2.0 audio/video call lifecycle FSM.
// See types.go for the state machine diagram and sentinel errors.
package calls

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strconv"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// ringingTimeoutMs is the server-side ringing timer (33 seconds).
const ringingTimeoutMs = int64(33 * time.Second / time.Millisecond)

// graceWindowMs is the 3-second grace window for late accept arrivals.
const graceWindowMs = int64(3 * time.Second / time.Millisecond)

// staleCallThresholdMs is the 4-hour stale call threshold for startup sweep.
const staleCallThresholdMs = int64(4 * time.Hour / time.Millisecond)

// turnTTLSeconds is the TURN credential TTL (15 minutes).
const turnTTLSeconds = 900

// recentTerminalReplayMs is how far back OnWSRegister replays terminal
// call-state snapshots — long enough to cover any realistic reconnect
// gap during a call, short enough not to spam history on every connect.
const recentTerminalReplayMs = int64(10 * time.Minute / time.Millisecond)

// defaultRingRetransmitInterval is the incoming_call retransmission
// cadence during the ringing window (spec line 807: every 3 seconds).
const defaultRingRetransmitInterval = 3 * time.Second

// maxPendingSignalsPerCall bounds the per-call replay queue for
// call_signal payloads whose recipient was offline at relay time. A
// normal handshake is one offer + one answer + a handful of ICE
// candidates; 64 is generous headroom, not a buffer for abuse.
const maxPendingSignalsPerCall = 64

// maxSignalPayloadBytes caps a single call_signal payload (the WebRTC
// SDP/ICE JSON object). A full SDP offer is a few KiB; 16 KiB is generous.
// Larger frames are rejected outright so a participant can't pin memory with
// a handful of huge payloads.
const maxSignalPayloadBytes = 16 * 1024

// maxSignalIDBytes bounds the client-chosen signal_id BEFORE it's stored in
// the per-call dedup set — a UUID is 36 chars, so 64 is generous. Without it a
// participant could pin maxSeenSignalsPerCall * (frame-sized id) of memory.
const maxSignalIDBytes = 64

// maxPendingSignalBytesPerCall bounds the TOTAL encoded bytes parked in a
// single call's replay queue, independent of the count cap — 64 max-size
// frames would otherwise reach ~1 MiB. 256 KiB comfortably holds a real
// offer + answer + ICE burst while capping abuse.
const maxPendingSignalBytesPerCall = 256 * 1024

// Manager is the call FSM service. Construct via New.
type Manager struct {
	DB         *storage.DB
	Hub        *ws.Hub
	Clock      storage.Clock
	TURNSecret string // shared HMAC secret for coturn credentials
	TURNHost   string // coturn hostname (e.g. "turn.example.com")

	// VoIPPush is invoked once per `Create` call when a recipient has a
	// registered VoIP push token. Optional — main.go wires it to the
	// internal/push package on startup if APNs env vars are present.
	// Best-effort: invoked in a goroutine so a slow or failing APNs
	// round-trip never delays the HTTP response.
	VoIPPush func(callID, fromUserID, fromName, kind, toUserID string)

	// RingRetransmitInterval overrides the incoming_call retransmission
	// cadence. Zero means defaultRingRetransmitInterval; tests shrink it.
	RingRetransmitInterval time.Duration

	// signalMu guards pendingSignals — call_signal payloads whose
	// recipient had no live WS session at relay time, replayed when the
	// user's session registers (Hub.OnRegister → FlushPendingSignals).
	//
	// DELIBERATELY in-memory, not persisted (review discussion,
	// 2026-06-12): a server restart kills the TURN allocations and both
	// WS sessions, so the media session is unrecoverable regardless of
	// whether the SDP survived — recovery is redial. A mid-ring restart
	// self-heals: the 5s missed sweep transitions the still-`ringing`
	// row within ~41s of call start, and a `connected` row whose media
	// died tears down client-side on ICE `.failed`. Persisting SDP/ICE
	// (network metadata) to disk for that 36-second window is a privacy
	// cost with no recovery payoff at this deployment's scale.
	signalMu       sync.Mutex
	pendingSignals map[string][]pendingSignal
	// seenSignals dedups call_signal frames by id, per call: the client
	// re-sends un-acked signals after a reconnect, so without this a
	// signal whose ACK was lost (server relayed it, the ack didn't make it
	// back) would be relayed to the peer twice. Cleared when the call
	// reaches a terminal state. Empty signal ids (older clients) bypass
	// dedup and always relay.
	//
	// BOUNDED (FIFO): a connected participant can submit unlimited unique
	// ids, so the per-call set is capped and the oldest id is evicted past
	// the cap. The retry window is recent (a reconnect re-sends the still-
	// un-acked tail), so recent-N dedup is what matters; evicting ancient
	// ids only risks re-relaying a long-dead signal, which can't happen
	// (the sender dropped it on its ack).
	seenSignals map[string]*signalDedup

	// staleMu guards bothAbsentSince — per connected-call timestamps of when
	// BOTH participants were first observed absent from the hub. The periodic
	// sweep ends a >4h connected call only after both sides stay absent for a
	// grace window, so a transient double-reconnect (server restart, network
	// handoff, app background, writer-loop unregister) can't force-hang a
	// healthy call on a single instantaneous liveness check.
	staleMu         sync.Mutex
	bothAbsentSince map[string]int64
}

// signalDedup is a bounded, FIFO-evicting set of seen signal ids.
type signalDedup struct {
	set   map[string]struct{}
	order []string
}

// maxSeenSignalsPerCall bounds the dedup set so a connected participant
// can't exhaust memory by submitting unlimited unique signal ids.
const maxSeenSignalsPerCall = 512

func (d *signalDedup) has(id string) bool {
	_, ok := d.set[id]
	return ok
}

func (d *signalDedup) add(id string) {
	if _, ok := d.set[id]; ok {
		return
	}
	if len(d.order) >= maxSeenSignalsPerCall {
		oldest := d.order[0]
		d.order = d.order[1:]
		delete(d.set, oldest)
	}
	d.set[id] = struct{}{}
	d.order = append(d.order, id)
}

func (d *signalDedup) remove(id string) {
	if _, ok := d.set[id]; !ok {
		return
	}
	delete(d.set, id)
	for i, v := range d.order {
		if v == id {
			d.order = append(d.order[:i], d.order[i+1:]...)
			break
		}
	}
}

type pendingSignal struct {
	toUserID string
	payload  map[string]any
	size     int // encoded payload bytes, for the per-call byte budget
}

// New constructs a Manager. Clock defaults to db.Clock.
func New(db *storage.DB, hub *ws.Hub) *Manager {
	return &Manager{
		DB:              db,
		Hub:             hub,
		Clock:           db.Clock,
		pendingSignals:  make(map[string][]pendingSignal),
		seenSignals:     make(map[string]*signalDedup),
		bothAbsentSince: make(map[string]int64),
	}
}

func (m *Manager) now() int64 { return m.Clock.NowMillis() }

// connectedCallAbsenceGraceMs is how long BOTH participants must be
// continuously absent from the hub before the periodic sweep ends a >4h
// connected call. A single instantaneous absence is unreliable: a server
// restart, network handoff, app background, or transient WS error briefly
// unregisters a still-active participant, and the 5s sweep could otherwise
// catch both mid-reconnect and force-hang a healthy call with no retry path.
// Requiring sustained absence distinguishes "clients vanished" (battery
// death, uninstall) from "clients briefly reconnecting".
const connectedCallAbsenceGraceMs = int64(2 * time.Minute / time.Millisecond)

// absenceGraceElapsed reports whether a connected call has had BOTH peers
// absent for at least the grace window. The first observation starts the
// clock (and returns false); a later observation past the window returns true.
func (m *Manager) absenceGraceElapsed(callID string, now int64) bool {
	m.staleMu.Lock()
	defer m.staleMu.Unlock()
	first, ok := m.bothAbsentSince[callID]
	if !ok {
		m.bothAbsentSince[callID] = now
		return false
	}
	return now-first >= connectedCallAbsenceGraceMs
}

// clearAbsence resets the grace clock for a call (a peer reappeared, or the
// call was ended).
func (m *Manager) clearAbsence(callID string) {
	m.staleMu.Lock()
	defer m.staleMu.Unlock()
	delete(m.bothAbsentSince, callID)
}

// pruneAbsence drops grace entries for calls no longer in the candidate set
// (ended elsewhere, or no longer >4h connected) so the map stays bounded.
func (m *Manager) pruneAbsence(keep map[string]struct{}) {
	m.staleMu.Lock()
	defer m.staleMu.Unlock()
	for id := range m.bothAbsentSince {
		if _, ok := keep[id]; !ok {
			delete(m.bothAbsentSince, id)
		}
	}
}

// ----- Create -----

// CreateRequest is the input to Manager.Create.
type CreateRequest struct {
	CallerUserID string
	CalleeUserID string
	Kind         CallKind
}

// CreateResult is returned from Manager.Create on success.
type CreateResult struct {
	CallID string
	State  CallState
}

// Create initiates a new call. Returns GlareError if an active call already
// exists between the pair (in either direction). Uses BEGIN IMMEDIATE to ensure
// atomicity of the glare check + insert.
func (m *Manager) Create(ctx context.Context, req CreateRequest) (*CreateResult, error) {
	if req.Kind == "" {
		req.Kind = KindAudio
	}

	now := m.now()
	callID := uuid.New().String()

	var result *CreateResult

	err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		// Glare detection: look for any ringing or connected call between
		// this pair in either direction (caller→callee or callee→caller).
		var (
			existingID       string
			existingCallerID string
			existingKind     string
			existingState    string
		)
		err := tx.QueryRow(
			`SELECT id, caller_user_id, kind, state FROM calls
			 WHERE state IN ('ringing', 'connected')
			   AND ((caller_user_id = ? AND callee_user_id = ?)
			     OR (caller_user_id = ? AND callee_user_id = ?))
			 LIMIT 1`,
			req.CallerUserID, req.CalleeUserID,
			req.CalleeUserID, req.CallerUserID,
		).Scan(&existingID, &existingCallerID, &existingKind, &existingState)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if err == nil {
			// An active call already exists between THIS pair — return glare
			// error. The state lets the client decide whether to pivot to a
			// ring (ringing) or reconcile/show-busy (connected) instead of
			// trying to "accept".
			return &GlareError{Info: GlareInfo{
				ExistingCallID:       existingID,
				ExistingCallerUserID: existingCallerID,
				ExistingCallKind:     CallKind(existingKind),
				ExistingState:        CallState(existingState),
			}}
		}

		// Single-active-call-per-user invariant: reject when either participant
		// is already ringing/connected with a THIRD party. Enforced here at the
		// trust boundary so a direct REST client can't put a user into two
		// concurrent calls even though the Apple stack gates to one via CallKit
		// and a single CallCoordinator phase.
		var (
			busyID       string
			busyCallerID string
			busyCalleeID string
			busyKind     string
			busyState    string
		)
		err = tx.QueryRow(
			`SELECT id, caller_user_id, callee_user_id, kind, state FROM calls
			 WHERE state IN ('ringing', 'connected')
			   AND (caller_user_id IN (?, ?) OR callee_user_id IN (?, ?))
			 LIMIT 1`,
			req.CallerUserID, req.CalleeUserID,
			req.CallerUserID, req.CalleeUserID,
		).Scan(&busyID, &busyCallerID, &busyCalleeID, &busyKind, &busyState)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if err == nil {
			// The same-pair check above already returned, so this match is a
			// cross-pair call: identify which requested participant is busy.
			busyUser := busyCallerID
			if busyUser != req.CallerUserID && busyUser != req.CalleeUserID {
				busyUser = busyCalleeID
			}
			return &BusyError{
				BusyUserID: busyUser,
				Info: GlareInfo{
					ExistingCallID:       busyID,
					ExistingCallerUserID: busyCallerID,
					ExistingCallKind:     CallKind(busyKind),
					ExistingState:        CallState(busyState),
				},
			}
		}

		// No active call; insert new ringing call.
		_, err = tx.Exec(
			`INSERT INTO calls (id, caller_user_id, callee_user_id, kind, state, started_at)
			 VALUES (?, ?, ?, ?, 'ringing', ?)`,
			callID, req.CallerUserID, req.CalleeUserID, string(req.Kind), now,
		)
		if err != nil {
			return err
		}
		result = &CreateResult{CallID: callID, State: StateRinging}
		return nil
	})
	if err != nil {
		return nil, err
	}

	// Fan out incoming_call event to callee (best-effort).
	if m.Hub != nil {
		m.Hub.SendToUser(req.CalleeUserID, ws.IncomingCall(callID, req.CallerUserID, string(req.Kind), now))
		// Retransmit while ringing (spec line 807). SendToUser is a
		// no-op for offline users, so this doubles as the replay that
		// lets a cold-launched client (VoIP push → app boot → WS
		// register mid-ring) learn about the call and drain buffered
		// CallKit answer/decline actions.
		go m.retransmitRing(callID, req.CalleeUserID, req.CallerUserID, string(req.Kind))
	}

	// VoIP push fan-out (best-effort, non-blocking). Wakes a terminated
	// iOS app to ring CallKit on the lock screen — the WS broadcast
	// above only reaches devices with a live socket. main.go wires the
	// hook to internal/push on startup.
	if m.VoIPPush != nil {
		var fromName string
		if name, err := lookupDisplayName(ctx, m.DB, req.CallerUserID); err == nil {
			fromName = name
		}
		go m.VoIPPush(callID, req.CallerUserID, fromName, string(req.Kind), req.CalleeUserID)
	}

	return result, nil
}

// lookupDisplayName fetches `users.display_name` for the given user id.
// Best-effort; falls back to the user id itself if the lookup fails so
// the CallKit ring still has SOMETHING to display.
func lookupDisplayName(ctx context.Context, db *storage.DB, userID string) (string, error) {
	var name string
	err := db.QueryRowContext(ctx,
		`SELECT display_name FROM users WHERE id = ?`, userID,
	).Scan(&name)
	if err != nil {
		return userID, err
	}
	return name, nil
}

// ----- Accept -----

// AcceptRequest is the input to Manager.Accept.
type AcceptRequest struct {
	CallID        string
	SessionUserID string
}

// AcceptResult is returned from Manager.Accept on success.
type AcceptResult struct {
	State CallState
}

// sendCallEvent delivers a call-lifecycle state change to a user's live
// session. Unlike a bare SendToUser, a live-but-BACKPRESSURED session (its
// channel full / closing, but the socket not yet dropped) is force-
// disconnected so the client reconnects and OnWSRegister replays the
// persisted terminal state. Without this, a stuck-but-not-dropped peer
// socket would never converge on a hang-up — the "drop on one device
// doesn't drop on the other" bug. Offline (NoSession) needs nothing here:
// the register-time replay covers it. NOT for call_signal (that has its own
// per-call replay queue) nor for the OnWSRegister replay itself.
func (m *Manager) sendCallEvent(userID string, ev ws.Event) bool {
	if m.Hub == nil || userID == "" {
		return false
	}
	switch m.Hub.SendToUserResult(userID, ev) {
	case ws.DeliveryDelivered:
		return true
	case ws.DeliveryBackpressured:
		m.Hub.DisconnectUser(userID)
		return false
	default: // DeliveryNoSession — offline; OnWSRegister replay covers it.
		return false
	}
}

// Accept transitions ringing → connected. Only the callee may accept.
// Accepts within the 3-second grace window (33s..36s) succeed.
func (m *Manager) Accept(ctx context.Context, req AcceptRequest) (*AcceptResult, error) {
	now := m.now()
	var result *AcceptResult
	var callerID string
	var expiredToMissed bool

	err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		row, err := fetchCall(tx, req.CallID)
		if err != nil {
			return err
		}

		if row.CalleeUserID != req.SessionUserID {
			return ErrCalleeOnly
		}
		callerID = row.CallerUserID

		switch row.State {
		case StateRinging:
			// Check if we are within the grace window (33s + 3s = 36s).
			deadline := row.StartedAt + ringingTimeoutMs + graceWindowMs
			if now > deadline {
				// The sweep hasn't caught this row yet. Persist the
				// missed transition HERE (returning an error would roll
				// the tx back) — a row left `ringing` blocks the pair's
				// future calls via glare detection until a sweep runs.
				if _, err := tx.Exec(
					`UPDATE calls SET state = 'missed', ended_at = ?, missed_notified = 0 WHERE id = ?`,
					now, req.CallID,
				); err != nil {
					return err
				}
				expiredToMissed = true
				return nil
			}
		default:
			if row.State.IsTerminal() {
				return &WrongStateError{Current: row.State}
			}
			// connected state (already accepted?): treat as conflict.
			return &WrongStateError{Current: row.State}
		}

		_, err = tx.Exec(
			`UPDATE calls SET state = 'connected', connected_at = ? WHERE id = ?`,
			now, req.CallID,
		)
		if err != nil {
			return err
		}
		result = &AcceptResult{State: StateConnected}
		callerID = row.CallerUserID
		return nil
	})
	if err != nil {
		return nil, err
	}

	if expiredToMissed {
		// Same fan-out the sweep performs; the callee (the accept
		// caller) learns via the error response.
		if m.Hub != nil {
			m.sendCallEvent(req.SessionUserID, ws.CallMissed(req.CallID, callerID, now))
		}
		m.purgePendingSignals(req.CallID)
		return nil, &WrongStateError{Current: StateMissed}
	}

	// Notify caller that call was accepted.
	if m.Hub != nil && callerID != "" {
		m.sendCallEvent(callerID, ws.CallStateChanged(req.CallID, string(StateConnected), false, nil, now))
	}
	return result, nil
}

// ----- Decline -----

// DeclineRequest is the input to Manager.Decline.
type DeclineRequest struct {
	CallID        string
	SessionUserID string
}

// DeclineResult is returned from Manager.Decline on success.
type DeclineResult struct {
	State CallState
}

// Decline transitions ringing → declined. Only the callee may decline.
func (m *Manager) Decline(ctx context.Context, req DeclineRequest) (*DeclineResult, error) {
	now := m.now()
	var callerID string

	err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		row, err := fetchCall(tx, req.CallID)
		if err != nil {
			return err
		}
		if row.CalleeUserID != req.SessionUserID {
			return ErrCalleeOnly
		}
		if row.State != StateRinging {
			return &WrongStateError{Current: row.State}
		}
		_, err = tx.Exec(
			`UPDATE calls SET state = 'declined', ended_at = ? WHERE id = ?`,
			now, req.CallID,
		)
		if err != nil {
			return err
		}
		callerID = row.CallerUserID
		return nil
	})
	if err != nil {
		return nil, err
	}

	// Notify caller.
	if m.Hub != nil && callerID != "" {
		m.sendCallEvent(callerID, ws.CallStateChanged(req.CallID, string(StateDeclined), false, nil, now))
	}
	m.purgePendingSignals(req.CallID)
	return &DeclineResult{State: StateDeclined}, nil
}

// ----- Cancel -----

// CancelRequest is the input to Manager.Cancel.
type CancelRequest struct {
	CallID        string
	SessionUserID string
}

// CancelResult is returned from Manager.Cancel on success.
type CancelResult struct {
	State       CallState
	EndedReason *string // non-nil only when state=ended (auto_ended_from_cancel)
}

// Cancel transitions ringing → cancelled, or (connected → ended with
// ended_reason=auto_ended_from_cancel) for the cancel-after-connect race.
// Only the caller may cancel.
func (m *Manager) Cancel(ctx context.Context, req CancelRequest) (*CancelResult, error) {
	now := m.now()
	var result *CancelResult
	var calleeID string

	err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		row, err := fetchCall(tx, req.CallID)
		if err != nil {
			return err
		}
		if row.CallerUserID != req.SessionUserID {
			return ErrCallerOnly
		}

		switch row.State {
		case StateRinging:
			_, err = tx.Exec(
				`UPDATE calls SET state = 'cancelled', ended_at = ? WHERE id = ?`,
				now, req.CallID,
			)
			if err != nil {
				return err
			}
			reason := (*string)(nil)
			result = &CancelResult{State: StateCancelled, EndedReason: reason}
		case StateConnected:
			// Cancel-after-connect race: auto-promote to ended.
			reason := string(ReasonAutoEndedFromCancel)
			_, err = tx.Exec(
				`UPDATE calls SET state = 'ended', ended_at = ?, ended_reason = ? WHERE id = ?`,
				now, reason, req.CallID,
			)
			if err != nil {
				return err
			}
			result = &CancelResult{State: StateEnded, EndedReason: &reason}
		default:
			return &WrongStateError{Current: row.State}
		}
		calleeID = row.CalleeUserID
		return nil
	})
	if err != nil {
		return nil, err
	}

	// Notify callee.
	if m.Hub != nil && calleeID != "" {
		state := string(result.State)
		m.sendCallEvent(calleeID, ws.CallStateChanged(req.CallID, state, false, result.EndedReason, now))
	}
	m.purgePendingSignals(req.CallID)
	return result, nil
}

// ----- End -----

// EndRequest is the input to Manager.End.
type EndRequest struct {
	CallID        string
	SessionUserID string
}

// EndResult is returned from Manager.End on success.
type EndResult struct {
	State       CallState
	EndedReason *string
}

// End transitions connected → ended (either party). Only valid when connected.
func (m *Manager) End(ctx context.Context, req EndRequest) (*EndResult, error) {
	now := m.now()
	var peerID string

	err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		row, err := fetchCall(tx, req.CallID)
		if err != nil {
			return err
		}
		if row.CallerUserID != req.SessionUserID && row.CalleeUserID != req.SessionUserID {
			return ErrNotAuthorized
		}
		if row.State != StateConnected {
			return &WrongStateError{Current: row.State}
		}

		reason := string(ReasonNormal)
		_, err = tx.Exec(
			`UPDATE calls SET state = 'ended', ended_at = ?, ended_reason = ? WHERE id = ?`,
			now, reason, req.CallID,
		)
		if err != nil {
			return err
		}

		// Determine peer.
		if row.CallerUserID == req.SessionUserID {
			peerID = row.CalleeUserID
		} else {
			peerID = row.CallerUserID
		}
		return nil
	})
	if err != nil {
		return nil, err
	}

	reason := string(ReasonNormal)
	// Notify peer.
	if m.Hub != nil && peerID != "" {
		m.sendCallEvent(peerID, ws.CallStateChanged(req.CallID, string(StateEnded), false, &reason, now))
	}
	m.purgePendingSignals(req.CallID)
	return &EndResult{State: StateEnded, EndedReason: &reason}, nil
}

// ----- RelaySignal -----

// RelaySignal forwards a WebRTC signaling payload (offer / answer / ICE
// candidate JSON — opaque to the server) from one participant of a live
// call to the other over the control WebSocket. The server validates
// only that the sender participates in the call and that the call is
// still ringing or connected; payload content is never inspected or
// persisted. Returns ErrNotFound / ErrNotAuthorized / WrongStateError
// like the other call actions.
func (m *Manager) RelaySignal(ctx context.Context, callID, senderUserID, signalID string, payload map[string]any) error {
	// Reject an oversized client-chosen signal_id before it can reach the
	// bounded dedup set (see maxSignalIDBytes).
	if len(signalID) > maxSignalIDBytes {
		return ErrSignalTooLarge
	}
	var peerID string

	err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		row, err := fetchCall(tx, callID)
		if err != nil {
			return err
		}
		switch senderUserID {
		case row.CallerUserID:
			peerID = row.CalleeUserID
		case row.CalleeUserID:
			peerID = row.CallerUserID
		default:
			return ErrNotAuthorized
		}
		if row.State != StateRinging && row.State != StateConnected {
			return &WrongStateError{Current: row.State}
		}
		return nil
	})
	if err != nil {
		return err
	}

	// Size gate: reject an oversized payload BEFORE reserving a dedup id or
	// touching the queue, so a malicious participant can neither relay nor
	// park large frames. The encoded size is reused for the byte budget below.
	payloadBytes, merr := json.Marshal(payload)
	if merr != nil {
		return fmt.Errorf("marshal call signal payload: %w", merr)
	}
	signalSize := len(payloadBytes)
	if signalSize > maxSignalPayloadBytes {
		return ErrSignalTooLarge
	}

	// Idempotency: a client that didn't get our ack re-sends the same
	// signal_id on reconnect. If we already relayed it, treat the re-send
	// as a no-op (but the caller still re-acks) so the peer isn't handed a
	// duplicate offer/answer. Empty ids (older clients) always relay.
	if signalID != "" {
		m.signalMu.Lock()
		seen := m.seenSignals[callID]
		if seen == nil {
			seen = &signalDedup{set: make(map[string]struct{})}
			m.seenSignals[callID] = seen
		}
		dup := seen.has(signalID)
		if !dup {
			seen.add(signalID)
		}
		m.signalMu.Unlock()
		if dup {
			return nil
		}
	}

	if m.Hub == nil {
		return nil
	}
	switch m.Hub.SendToUserResult(peerID, ws.CallSignal(callID, payload, m.now())) {
	case ws.DeliveryDelivered:
		return nil
	case ws.DeliveryBackpressured:
		// The peer has a LIVE session but its outbound channel is full (or
		// closing). Parking in pendingSignals would NOT help — those only flush
		// on a fresh WS registration, which a still-connected peer won't
		// trigger — so the frame would sit until disconnect while the sender,
		// ack'd, drops its retry copy. Instead un-reserve the dedup mark and
		// return queue-full so the WS handler withholds the ack and the client
		// retries; the channel has likely drained by then.
		if signalID != "" {
			m.signalMu.Lock()
			if seen := m.seenSignals[callID]; seen != nil {
				seen.remove(signalID)
			}
			m.signalMu.Unlock()
		}
		return ErrSignalQueueFull
	case ws.DeliveryNoSession:
		// fall through to the offline-replay queue below.
	}
	// Peer has no live WS session (cold launch from VoIP push, or a
	// transient reconnect). Queue for replay when their session
	// registers — dropping SDP/ICE here would strand the handshake.
	m.signalMu.Lock()
	q := m.pendingSignals[callID]
	queuedBytes := 0
	for _, s := range q {
		queuedBytes += s.size
	}
	// Reject when EITHER the count cap or the per-call byte budget would be
	// exceeded — 64 max-size frames would otherwise pin ~1 MiB per call.
	full := len(q) >= maxPendingSignalsPerCall || queuedBytes+signalSize > maxPendingSignalBytesPerCall
	if !full {
		m.pendingSignals[callID] = append(q, pendingSignal{toUserID: peerID, payload: payload, size: signalSize})
	} else if signalID != "" {
		// Couldn't deliver OR queue — UN-RESERVE the dedup mark we set
		// above, or the sender's retry of this same signal_id would be
		// falsely deduped (returning nil → an ack), permanently losing the
		// SDP/ICE. Withholding the ack alone isn't enough.
		if seen := m.seenSignals[callID]; seen != nil {
			seen.remove(signalID)
		}
	}
	m.signalMu.Unlock()
	if full {
		// Surface it so the handler withholds the ack and the sender keeps
		// retrying instead of dropping its only copy on a false success.
		return ErrSignalQueueFull
	}
	return nil
}

// OnWSRegister replays call state to a freshly-registered session, in
// an order a cold-launched client can consume:
//
//  1. `incoming_call` for any call still ringing where the user is the
//     callee — BEFORE the queued signals, so the client establishes its
//     call context first (an offer arriving before the ring would be
//     dropped or mis-buffered).
//  2. `call_state_changed` snapshots (stale=true) for the user's active
//     and recently-terminal calls — a peer that missed a best-effort
//     terminal event while offline would otherwise stay stuck in
//     ringing/active forever.
//  3. Queued call_signal payloads (FlushPendingSignals).
//
// Wired to Hub.OnRegister in main.go.
func (m *Manager) OnWSRegister(userID string) {
	if m.Hub == nil {
		return
	}
	now := m.now()
	recentCutoff := now - recentTerminalReplayMs

	type callRow struct {
		id          string
		callerID    string
		calleeID    string
		kind        string
		state       string
		endedReason sql.NullString
	}
	var active []callRow
	var terminal []callRow
	dbRows, err := m.DB.QueryContext(context.Background(),
		`SELECT id, caller_user_id, callee_user_id, kind, state, ended_reason
		   FROM calls
		  WHERE (caller_user_id = ? OR callee_user_id = ?)
		    AND (state IN ('ringing', 'connected') OR COALESCE(ended_at, 0) >= ?)
		  ORDER BY COALESCE(ended_at, started_at) DESC`,
		userID, userID, recentCutoff,
	)
	if err == nil {
		defer dbRows.Close()
		for dbRows.Next() {
			var r callRow
			if scanErr := dbRows.Scan(&r.id, &r.callerID, &r.calleeID, &r.kind, &r.state, &r.endedReason); scanErr == nil {
				if r.state == string(StateRinging) || r.state == string(StateConnected) {
					active = append(active, r)
				} else {
					terminal = append(terminal, r)
				}
			}
		}
	}

	// Active calls first — they carry the ring (and its pending offer
	// must follow), so they must reach the channel before anything else
	// competes for its 64 slots. Terminal-history replay is bounded
	// (most-recent-first) so a user who churned through many recent
	// calls can't saturate the channel and starve the offer.
	const maxTerminalReplay = 8
	if len(terminal) > maxTerminalReplay {
		terminal = terminal[:maxTerminalReplay]
	}

	emit := func(r callRow) {
		if r.state == string(StateRinging) && r.calleeID == userID {
			m.Hub.SendToUser(userID, ws.IncomingCall(r.id, r.callerID, r.kind, now))
		}
		var reason *string
		if r.endedReason.Valid {
			s := r.endedReason.String
			reason = &s
		}
		m.Hub.SendToUser(userID, ws.CallStateChanged(r.id, r.state, true, reason, now))
	}
	for _, r := range active {
		emit(r)
	}

	// Pending SDP/ICE before the bounded terminal history: signals are
	// irreplaceable (no catch-up endpoint), terminal snapshots are
	// advisory. FlushPendingSignals also requeues anything that still
	// fails to enqueue, so a transient full channel self-heals on the
	// next flush.
	m.FlushPendingSignals(userID)

	// Deliver any missed-call notifications the callee never received (it
	// was offline when the ring timed out). Terminal call_state_changed
	// snapshots below are advisory and the client ignores them for
	// non-current calls, so call_missed is the ONLY path that surfaces a
	// missed call after a cold reconnect. Best-effort: failures leave
	// missed_notified=0 for the next register to retry.
	if _, err := m.DeliverMissedCalls(context.Background(), userID); err != nil {
		log.Printf("[WARN] deliver missed calls on register for %s: %v", userID, err)
	}

	for _, r := range terminal {
		emit(r)
	}
}

// FlushPendingSignals replays queued call_signal payloads addressed to
// userID. Invoked from OnWSRegister so a freshly-connected client
// receives the offer/answer/ICE frames it missed while offline.
func (m *Manager) FlushPendingSignals(userID string) {
	if m.Hub == nil {
		return
	}
	type outItem struct {
		callID  string
		payload map[string]any
		size    int // carried through so a requeue preserves the byte budget
	}
	var deliver []outItem
	m.signalMu.Lock()
	for callID, q := range m.pendingSignals {
		keep := q[:0]
		for _, s := range q {
			if s.toUserID == userID {
				deliver = append(deliver, outItem{callID: callID, payload: s.payload, size: s.size})
			} else {
				keep = append(keep, s)
			}
		}
		if len(keep) == 0 {
			delete(m.pendingSignals, callID)
		} else {
			m.pendingSignals[callID] = keep
		}
	}
	m.signalMu.Unlock()
	for _, d := range deliver {
		switch m.classifySignalCall(d.callID, userID) {
		case signalCallTerminal:
			// Don't flush a terminated call's signals ahead of the terminal
			// snapshot, nor fill the bounded channel for a call that can't be
			// accepted. Drop + purge.
			m.purgePendingSignals(d.callID)
			continue
		case signalCallUnknown:
			// Transient lookup failure — don't deliver now, but don't lose the
			// frame either: requeue it for the next flush/register.
			m.signalMu.Lock()
			m.pendingSignals[d.callID] = append(m.pendingSignals[d.callID],
				pendingSignal{toUserID: userID, payload: d.payload, size: d.size})
			m.enforcePerCallSignalBudgetLocked(d.callID)
			m.signalMu.Unlock()
			continue
		case signalCallActive:
			// fall through to deliver
		}
		if m.Hub.SendToUser(userID, ws.CallSignal(d.callID, d.payload, m.now())) {
			continue
		}
		// Enqueue failed (session closed mid-register, or its bounded
		// outbound channel is saturated by the state snapshots that
		// precede us). Re-queue instead of dropping — the next register
		// or a later flush gets another chance. Dequeue-then-send
		// without this requeue silently lost the frame.
		//
		// WITHOUT the cap: these were already accepted (dequeued from the
		// pending queue and handed to SendToUser), so the sender has
		// dropped its retry copy and the signal_id is deduped. Cap-dropping
		// them on a replay-enqueue failure would permanently lose an
		// offer/answer/ICE. The set is bounded by what was queued.
		m.signalMu.Lock()
		m.pendingSignals[d.callID] = append(m.pendingSignals[d.callID],
			pendingSignal{toUserID: userID, payload: d.payload, size: d.size})
		m.enforcePerCallSignalBudgetLocked(d.callID)
		m.signalMu.Unlock()
	}
}

// RequeueUndeliveredSignals salvages call frames that were buffered to a
// session's outbound channel but never actually written to the wire.
//
// SendToUser reports success the moment a frame enters the per-session
// channel, NOT when conn.Write succeeds. If the peer socket has died but is
// not yet unregistered, the sender (or DeliverMissedCalls) sees that
// optimistic success and advances its own state; the writer then fails to
// write the frame and it is lost. The WS writer hands those buffered-but-
// unwritten frames here on write failure so they recover on the peer's next
// registration:
//   - call_signal → re-enters the per-call replay queue.
//   - call_missed → resets missed_notified=0 so DeliverMissedCalls re-emits
//     it (DeliverMissedCalls marks notified on channel-accept, which this
//     undoes when the write truly failed).
//
// Other frames (presence, typing, message echoes, state snapshots) are
// recoverable through their own catch-up paths and are ignored here.
func (m *Manager) RequeueUndeliveredSignals(userID string, frames [][]byte) {
	for _, body := range frames {
		var f struct {
			Type    string         `json:"type"`
			CallID  string         `json:"call_id"`
			Payload map[string]any `json:"payload"`
		}
		if err := json.Unmarshal(body, &f); err != nil {
			continue
		}
		switch {
		case f.Type == "call_signal" && f.CallID != "" && f.Payload != nil:
			// Don't resurrect a signal for a call that already terminated. A
			// frame can reach here AFTER purgePendingSignals (it was in the dead
			// session's channel when the call was cancelled/ended, and the
			// writer only salvages it on its next failed write). Re-queuing it
			// would replay stale SDP/ICE on the peer's reconnect — ahead of the
			// terminal snapshot — and could fill the bounded outbound channel.
			// On a TRANSIENT lookup failure, keep it (these frames were already
			// acked, so dropping would permanently lose the offer/answer/ICE).
			if m.classifySignalCall(f.CallID, userID) == signalCallTerminal {
				m.purgePendingSignals(f.CallID)
				continue
			}
			// Append WITHOUT the maxPendingSignalsPerCall cap: these frames
			// were already ACKed (SendToUser accepted them into the session
			// channel), so the sender has dropped its retry copy — silently
			// dropping them here would permanently lose SDP/ICE and strand
			// call setup. The salvage set is inherently bounded (one in-flight
			// frame plus the drained channel, len <= cap(sess.Out)), and the
			// next OnWSRegister drains the queue. The live-relay path and the
			// dedup set keep their own caps for the DoS surface.
			//
			// Record the encoded size so the per-call byte budget stays
			// accurate: a salvaged frame counted as 0 bytes would let a later
			// LIVE RelaySignal push the queue past maxPendingSignalBytesPerCall.
			payloadBytes, _ := json.Marshal(f.Payload)
			m.signalMu.Lock()
			m.pendingSignals[f.CallID] = append(m.pendingSignals[f.CallID],
				pendingSignal{toUserID: userID, payload: f.Payload, size: len(payloadBytes)})
			// Bound the aggregate queue even though salvage bypasses the live
			// cap — repeated salvage cycles must not grow it without limit.
			m.enforcePerCallSignalBudgetLocked(f.CallID)
			m.signalMu.Unlock()
		case f.Type == "call_missed" && f.CallID != "":
			// The call_missed frame never made it to the wire — undo the
			// notified mark so the next register re-delivers it.
			if _, err := m.DB.ExecContext(context.Background(),
				`UPDATE calls SET missed_notified = 0 WHERE id = ?`, f.CallID); err != nil {
				log.Printf("[WARN] reset missed_notified for undelivered call_missed %s: %v", f.CallID, err)
			}
		}
	}
}

// purgePendingSignals drops the replay queue for a call that reached a
// terminal state — stale SDP/ICE must not leak into a future call.
func (m *Manager) purgePendingSignals(callID string) {
	m.signalMu.Lock()
	delete(m.pendingSignals, callID)
	delete(m.seenSignals, callID)
	m.signalMu.Unlock()
}

// enforcePerCallSignalBudgetLocked trims a call's replay queue to the count and
// byte caps by evicting the OLDEST frames (FIFO) — caller must hold signalMu.
// The salvage path appends already-acked frames bypassing the live RelaySignal
// cap; without this, repeated write-failure → salvage cycles (the slice
// persists across reconnects) would grow per-call memory past the advertised
// caps using valid <=16 KiB frames. Under normal handshakes the queue is far
// below the caps so nothing is evicted; the bound only bites under abuse, where
// dropping the abuser's oldest (likely stale ICE) frame is the right tradeoff.
func (m *Manager) enforcePerCallSignalBudgetLocked(callID string) {
	q := m.pendingSignals[callID]
	bytes := 0
	for _, s := range q {
		bytes += s.size
	}
	drop := 0
	for drop < len(q) && (len(q)-drop > maxPendingSignalsPerCall || bytes > maxPendingSignalBytesPerCall) {
		bytes -= q[drop].size
		drop++
	}
	if drop == 0 {
		return
	}
	if drop >= len(q) {
		delete(m.pendingSignals, callID)
		return
	}
	// Compact in place (reuses the backing array so it can't grow unboundedly).
	m.pendingSignals[callID] = append(q[:0], q[drop:]...)
}

// signalCallState classifies whether a call_signal may be (re)queued or flushed
// to a user. It is deliberately TRI-state: a transient DB error must NOT be
// collapsed into "drop", or a still-live call's already-acked SDP/ICE (the
// sender has dropped its retry copy) would be permanently lost during a
// restore/vacuum or closed-handle blip.
type signalCallState int

const (
	signalCallActive   signalCallState = iota // ringing/connected, user is a participant → deliver
	signalCallTerminal                        // confirmed gone / non-participant / terminal → drop + purge
	signalCallUnknown                         // transient lookup failure → KEEP, retry later
)

// classifySignalCall determines whether callID is a live call the given user
// participates in. Only a CONFIRMED no-row, non-participant, or terminal state
// returns Terminal (safe to drop). A transient query error returns Unknown so
// callers keep the signal instead of losing it.
func (m *Manager) classifySignalCall(callID, userID string) signalCallState {
	var caller, callee, state string
	err := m.DB.QueryRowContext(context.Background(),
		`SELECT caller_user_id, callee_user_id, state FROM calls WHERE id = ?`, callID,
	).Scan(&caller, &callee, &state)
	if errors.Is(err, sql.ErrNoRows) {
		return signalCallTerminal // row gone (purged / never existed)
	}
	if err != nil {
		return signalCallUnknown // transient — do NOT drop a possibly-live signal
	}
	if userID != caller && userID != callee {
		return signalCallTerminal // never deliver to a non-participant
	}
	if state == string(StateRinging) || state == string(StateConnected) {
		return signalCallActive
	}
	return signalCallTerminal // declined / cancelled / missed / ended
}

// retransmitRing re-emits incoming_call on a fixed cadence while the
// call stays ringing. Self-terminating: stops on the first tick where
// the row is no longer ringing, on any DB error, or once the ringing
// window (+grace) has elapsed.
func (m *Manager) retransmitRing(callID, calleeID, callerID, kind string) {
	interval := m.RingRetransmitInterval
	if interval <= 0 {
		interval = defaultRingRetransmitInterval
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	deadline := time.Now().Add(time.Duration(ringingTimeoutMs+graceWindowMs) * time.Millisecond)
	for range ticker.C {
		if time.Now().After(deadline) {
			return
		}
		var state string
		err := m.DB.QueryRowContext(context.Background(),
			`SELECT state FROM calls WHERE id = ?`, callID,
		).Scan(&state)
		if err != nil || state != string(StateRinging) {
			return
		}
		m.Hub.SendToUser(calleeID, ws.IncomingCall(callID, callerID, kind, m.now()))
	}
}

// ----- Missed sweep -----

// RunMissedSweepForever drives the ringing-timeout sweep on a fixed
// interval until ctx is cancelled. Without this, an unanswered call
// stays `ringing` forever and glare detection blocks the pair from
// ever calling again. Wired from main.go.
func (m *Manager) RunMissedSweepForever(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if _, err := m.RunMissedSweepCount(ctx); err != nil && ctx.Err() == nil {
				log.Printf("calls: missed sweep error: %v", err)
			}
		}
	}
}

// RunMissedSweep transitions all ringing calls that have exceeded the
// ringing window + grace window to missed state. Returns nil.
func (m *Manager) RunMissedSweep(ctx context.Context) error {
	_, err := m.RunMissedSweepCount(ctx)
	return err
}

// RunMissedSweepCount is RunMissedSweep but returns the count of transitioned
// calls. Used by tests.
func (m *Manager) RunMissedSweepCount(ctx context.Context) (int, error) {
	now := m.now()
	// A call is past the grace window when: now > started_at + 33s + 3s
	cutoff := now - ringingTimeoutMs - graceWindowMs

	type missedRow struct {
		callID   string
		calleeID string
		callerID string
	}
	var missed []missedRow

	err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		rows, err := tx.Query(
			`SELECT id, callee_user_id, caller_user_id FROM calls
			 WHERE state = 'ringing' AND started_at <= ?`,
			cutoff,
		)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var r missedRow
			if err := rows.Scan(&r.callID, &r.calleeID, &r.callerID); err != nil {
				return err
			}
			missed = append(missed, r)
		}
		if err := rows.Err(); err != nil {
			return err
		}
		for _, r := range missed {
			if _, err := tx.Exec(
				`UPDATE calls SET state = 'missed', ended_at = ?, missed_notified = 0 WHERE id = ?`,
				now, r.callID,
			); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return 0, err
	}

	// Emit missed events. Mirror DeliverMissedCalls: mark missed_notified
	// BEFORE enqueue and undo on a failed enqueue. Without the mark a live
	// callee gets the event here AND again from DeliverMissedCalls on its next
	// WS register (duplicate missed-call), since this sweep now runs every 5s.
	// Mark-before keeps the writer's salvage reset (missed_notified=0 for an
	// enqueued-but-unwritten frame) as the last write, so a dropped frame still
	// re-delivers; a failed enqueue (offline / saturated) is undone inline.
	for _, r := range missed {
		m.purgePendingSignals(r.callID)
		if m.Hub == nil {
			continue
		}
		if err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
			_, e := tx.Exec(`UPDATE calls SET missed_notified = 1 WHERE id = ?`, r.callID)
			return e
		}); err != nil {
			return len(missed), fmt.Errorf("mark swept missed call %s notified: %w", r.callID, err)
		}
		if m.sendCallEvent(r.calleeID, ws.CallMissed(r.callID, r.callerID, now)) {
			continue
		}
		if err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
			_, e := tx.Exec(`UPDATE calls SET missed_notified = 0 WHERE id = ?`, r.callID)
			return e
		}); err != nil {
			return len(missed), fmt.Errorf("undo swept missed-call mark %s: %w", r.callID, err)
		}
	}

	// Connected-call lease: end only a stale `connected` row whose BOTH
	// participants have NO live WS session — the precise "clients
	// vanished" case (battery death, uninstall). A genuinely healthy
	// long call (both peers connected) must NOT be killed on a wall-
	// clock threshold alone, and both participants are notified +
	// queued signals purged when we do expire one.
	staleCutoff := now - staleCallThresholdMs
	type connRow struct{ id, callerID, calleeID string }
	var stale []connRow
	err = m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		rows, err := tx.Query(
			`SELECT id, caller_user_id, callee_user_id FROM calls
			 WHERE state = 'connected' AND started_at < ?`,
			staleCutoff,
		)
		if err != nil {
			return err
		}
		var candidates []connRow
		func() {
			defer rows.Close()
			for rows.Next() {
				var r connRow
				if rows.Scan(&r.id, &r.callerID, &r.calleeID) == nil {
					candidates = append(candidates, r)
				}
			}
		}()
		seen := make(map[string]struct{}, len(candidates))
		for _, r := range candidates {
			seen[r.id] = struct{}{}
			// Hub is the live-connectivity oracle; a nil hub (tests)
			// treats everyone as disconnected.
			callerLive := m.Hub != nil && m.Hub.IsConnected(r.callerID)
			calleeLive := m.Hub != nil && m.Hub.IsConnected(r.calleeID)
			if callerLive || calleeLive {
				m.clearAbsence(r.id) // a peer is present — reset the grace clock
				continue             // leave a (re)connected call alone
			}
			// Both peers absent. End only after BOTH have stayed absent for
			// the grace window — a single instantaneous absence is unreliable
			// (a server restart, network handoff, app background, or transient
			// WS error briefly unregisters a still-active participant, and this
			// 5s sweep could otherwise catch both mid-reconnect and force-hang
			// a healthy long call).
			if !m.absenceGraceElapsed(r.id, now) {
				continue
			}
			if _, err := tx.Exec(
				`UPDATE calls SET state = 'ended', ended_at = ?, ended_reason = 'stale_sweep' WHERE id = ?`,
				now, r.id,
			); err != nil {
				return err
			}
			m.clearAbsence(r.id)
			stale = append(stale, r)
		}
		m.pruneAbsence(seen)
		return nil
	})
	if err != nil {
		return len(missed), err
	}
	for _, r := range stale {
		reason := "stale_sweep"
		if m.Hub != nil {
			m.sendCallEvent(r.callerID, ws.CallStateChanged(r.id, string(StateEnded), false, &reason, now))
			m.sendCallEvent(r.calleeID, ws.CallStateChanged(r.id, string(StateEnded), false, &reason, now))
		}
		m.purgePendingSignals(r.id)
	}
	return len(missed), nil
}

// ----- Startup sweep -----

// RunStartupSweep transitions stale (>4h) ringing→missed and
// connected→ended(stale_sweep) calls. Called once at server startup before
// HTTP listen. Returns count of transitioned rows.
func (m *Manager) RunStartupSweep(ctx context.Context) (int, error) {
	now := m.now()
	staleCutoff := now - staleCallThresholdMs
	var count int

	err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
		// Stale ringing → missed.
		res, err := tx.Exec(
			`UPDATE calls SET state = 'missed', ended_at = ?, missed_notified = 0
			 WHERE state = 'ringing' AND started_at < ?`,
			now, staleCutoff,
		)
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		count += int(n)

		// Stale connected → ended(stale_sweep).
		res, err = tx.Exec(
			`UPDATE calls SET state = 'ended', ended_at = ?, ended_reason = 'stale_sweep'
			 WHERE state = 'connected' AND started_at < ?`,
			now, staleCutoff,
		)
		if err != nil {
			return err
		}
		n, _ = res.RowsAffected()
		count += int(n)
		return nil
	})
	return count, err
}

// ----- Missed-call delivery -----

// DeliverMissedCalls finds all missed calls for userID that have not yet been
// notified, emits call_missed WS events for each, and marks them delivered.
// Returns the count of delivered events.
func (m *Manager) DeliverMissedCalls(ctx context.Context, userID string) (int, error) {
	if m.Hub == nil {
		return 0, nil
	}
	now := m.now()
	type mc struct {
		callID   string
		callerID string
	}

	var pending []mc
	rows, err := m.DB.QueryContext(ctx,
		`SELECT id, caller_user_id FROM calls
		 WHERE callee_user_id = ? AND state = 'missed' AND missed_notified = 0`,
		userID,
	)
	if err != nil {
		return 0, fmt.Errorf("query missed calls for %s: %w", userID, err)
	}
	defer rows.Close()
	for rows.Next() {
		var r mc
		if err := rows.Scan(&r.callID, &r.callerID); err != nil {
			return 0, fmt.Errorf("scan missed call: %w", err)
		}
		pending = append(pending, r)
	}
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("iterate missed calls: %w", err)
	}

	// Mark BEFORE enqueue, undo on a failed enqueue. The writer salvages an
	// unwritten call_missed by resetting missed_notified=0; that salvage can
	// only happen AFTER the frame was enqueued. Marking first guarantees the
	// mark is never the LAST write for a failed delivery — a salvage reset
	// always lands after it and wins (the round-27 enqueue-then-mark order let
	// the mark race ahead of the reset, permanently suppressing the replay).
	// A failed enqueue (no session / saturated channel) never enqueues a frame,
	// so there's nothing to salvage — we undo the mark inline so the next
	// register retries.
	delivered := 0
	for _, r := range pending {
		if err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
			_, execErr := tx.Exec(`UPDATE calls SET missed_notified = 1 WHERE id = ?`, r.callID)
			return execErr
		}); err != nil {
			return delivered, fmt.Errorf("mark missed call %s notified: %w", r.callID, err)
		}
		if m.sendCallEvent(userID, ws.CallMissed(r.callID, r.callerID, now)) {
			delivered++
			continue
		}
		// Not enqueued — undo the mark so the next register re-delivers.
		if err := m.DB.WriteTx(ctx, func(tx *storage.Tx) error {
			_, execErr := tx.Exec(`UPDATE calls SET missed_notified = 0 WHERE id = ?`, r.callID)
			return execErr
		}); err != nil {
			return delivered, fmt.Errorf("undo missed-call mark %s: %w", r.callID, err)
		}
	}
	return delivered, nil
}

// ----- Relay credentials -----

// RelayCredentials generates time-limited TURN credentials using coturn's
// HMAC-SHA1 static-auth-secret scheme.
//
// Username format: "<unix-expiry>:<userID>"
// Password: base64(HMAC-SHA1(secret, username))
func (m *Manager) RelayCredentials(ctx context.Context, userID string) (*RelayCredentials, error) {
	if m.TURNSecret == "" {
		return nil, fmt.Errorf("TURN secret not configured")
	}
	now := m.now()
	expiryUnix := (now / 1000) + int64(turnTTLSeconds)
	username := strconv.FormatInt(expiryUnix, 10) + ":" + userID

	mac := hmac.New(sha1.New, []byte(m.TURNSecret))
	mac.Write([]byte(username))
	password := base64.StdEncoding.EncodeToString(mac.Sum(nil))

	host := m.TURNHost
	if host == "" {
		host = "localhost"
	}

	return &RelayCredentials{
		Username:   username,
		Password:   password,
		TTLSeconds: turnTTLSeconds,
		URLs:       []string{fmt.Sprintf("turn:%s:3478", host)},
	}, nil
}

// ----- List recent calls -----

// ListRecentCallsRequest is the input to Manager.ListRecentCalls.
type ListRecentCallsRequest struct {
	Limit           int
	BeforeStartedAt *int64 // nil for first page
}

// RecentCallRow is one row returned by ListRecentCalls.
type RecentCallRow struct {
	ID           string
	CallerUserID string
	CalleeUserID string
	Kind         CallKind
	State        CallState
	EndedReason  *string
	StartedAt    int64
	ConnectedAt  *int64
	EndedAt      *int64
}

// ListRecentCalls returns calls in DESC started_at order, paginated by
// BeforeStartedAt. Limit is clamped to [1, 500]; default 50.
func (m *Manager) ListRecentCalls(ctx context.Context, req ListRecentCallsRequest) ([]RecentCallRow, error) {
	limit := req.Limit
	if limit <= 0 {
		limit = 50
	}
	if limit > 500 {
		limit = 500
	}

	var rows []RecentCallRow
	var err error

	if req.BeforeStartedAt == nil {
		var dbRows *sql.Rows
		dbRows, err = m.DB.QueryContext(ctx,
			`SELECT id, caller_user_id, callee_user_id, kind, state, ended_reason,
			        started_at, connected_at, ended_at
			 FROM calls ORDER BY started_at DESC LIMIT ?`,
			limit,
		)
		if err != nil {
			return nil, err
		}
		rows, err = scanRecentCallRows(dbRows)
	} else {
		var dbRows *sql.Rows
		dbRows, err = m.DB.QueryContext(ctx,
			`SELECT id, caller_user_id, callee_user_id, kind, state, ended_reason,
			        started_at, connected_at, ended_at
			 FROM calls WHERE started_at < ?
			 ORDER BY started_at DESC LIMIT ?`,
			*req.BeforeStartedAt, limit,
		)
		if err != nil {
			return nil, err
		}
		rows, err = scanRecentCallRows(dbRows)
	}
	return rows, err
}

// ListRecentCallsRaw returns calls as a slice of map[string]any, suitable
// for marshaling directly to the control-socket response. It implements
// control.CallsLister without importing the control package.
func (m *Manager) ListRecentCallsRaw(ctx context.Context, limit int, beforeStartedAt *int64) ([]map[string]any, error) {
	rows, err := m.ListRecentCalls(ctx, ListRecentCallsRequest{
		Limit:           limit,
		BeforeStartedAt: beforeStartedAt,
	})
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		row := map[string]any{
			"id":             r.ID,
			"caller_user_id": r.CallerUserID,
			"callee_user_id": r.CalleeUserID,
			"kind":           string(r.Kind),
			"state":          string(r.State),
			"started_at":     r.StartedAt,
		}
		if r.EndedReason != nil {
			row["ended_reason"] = *r.EndedReason
		}
		if r.ConnectedAt != nil {
			row["connected_at"] = *r.ConnectedAt
		}
		if r.EndedAt != nil {
			row["ended_at"] = *r.EndedAt
		}
		out = append(out, row)
	}
	return out, nil
}

// ----- helpers -----

// fetchCall loads a single call row by ID, returning ErrNotFound on miss.
func fetchCall(tx *storage.Tx, callID string) (*CallRow, error) {
	var row CallRow
	var (
		endedReason sql.NullString
		connectedAt sql.NullInt64
		endedAt     sql.NullInt64
		missedNotif int
	)
	err := tx.QueryRow(
		`SELECT id, caller_user_id, callee_user_id, kind, state, ended_reason,
		        started_at, connected_at, ended_at, missed_notified
		 FROM calls WHERE id = ?`,
		callID,
	).Scan(
		&row.ID, &row.CallerUserID, &row.CalleeUserID,
		(*string)(&row.Kind), (*string)(&row.State),
		&endedReason, &row.StartedAt, &connectedAt, &endedAt, &missedNotif,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if endedReason.Valid {
		s := endedReason.String
		row.EndedReason = &s
	}
	if connectedAt.Valid {
		v := connectedAt.Int64
		row.ConnectedAt = &v
	}
	if endedAt.Valid {
		v := endedAt.Int64
		row.EndedAt = &v
	}
	row.MissedNotified = missedNotif != 0
	return &row, nil
}

func scanRecentCallRows(dbRows *sql.Rows) ([]RecentCallRow, error) {
	defer dbRows.Close()
	var out []RecentCallRow
	for dbRows.Next() {
		var r RecentCallRow
		var (
			endedReason sql.NullString
			connectedAt sql.NullInt64
			endedAt     sql.NullInt64
		)
		if err := dbRows.Scan(
			&r.ID, &r.CallerUserID, &r.CalleeUserID,
			(*string)(&r.Kind), (*string)(&r.State),
			&endedReason, &r.StartedAt, &connectedAt, &endedAt,
		); err != nil {
			return nil, err
		}
		if endedReason.Valid {
			s := endedReason.String
			r.EndedReason = &s
		}
		if connectedAt.Valid {
			v := connectedAt.Int64
			r.ConnectedAt = &v
		}
		if endedAt.Valid {
			v := endedAt.Int64
			r.EndedAt = &v
		}
		out = append(out, r)
	}
	return out, dbRows.Err()
}
