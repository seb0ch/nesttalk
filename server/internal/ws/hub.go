package ws

import (
	"encoding/json"
	"sync"
)

// Session is one connected device. Send is the per-session outbound channel;
// the hub owns it and the WebSocket reader/writer pair drains/produces it.
type Session struct {
	UserID   string
	DeviceID string
	Out      chan []byte
	closed   bool
	mu       sync.Mutex

	// OnClose, when set, severs the underlying network connection
	// immediately on Close — closing the outbound channel alone only stops
	// the writer; the reader goroutine would otherwise keep accepting
	// inbound typing / call_signal frames under the socket's upgrade-time
	// claims until its next read errors or the 30s revalidation tick fires.
	// Set it BEFORE the session is registered, so a revoke/re-enroll racing
	// registration still tears the connection down. Invoked exactly once,
	// outside the session lock (it may call back into the WebSocket conn).
	OnClose func()
}

// Close marks the session as closed so the hub's next fan-out drops it, and
// severs the underlying connection via OnClose so a revoked socket can't keep
// reading inbound frames. Safe to call concurrently and idempotent.
func (s *Session) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	close(s.Out)
	hook := s.OnClose
	s.mu.Unlock()
	if hook != nil {
		hook()
	}
}

// IsClosed reports whether Close has been called.
func (s *Session) IsClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}

// Hub is the in-memory WebSocket session map.
//
// v0.2.0 has at most one active device per user, so the map is keyed by
// device_id and a parallel "by user_id" lookup is exposed for fan-out.
type Hub struct {
	mu       sync.RWMutex
	sessions map[string]*Session // device_id -> session
	byUser   map[string]*Session // user_id -> session (single-device invariant)

	// OnRegister, when set, fires after a session registers — used to
	// replay queued call signals to a freshly-connected user. Invoked
	// outside the hub lock; must not call back into Register/Unregister.
	OnRegister func(userID string)
}

// NewHub constructs a Hub.
func NewHub() *Hub {
	return &Hub{
		sessions: make(map[string]*Session),
		byUser:   make(map[string]*Session),
	}
}

// Register adds a session to the hub. If another session for the same
// device_id is present, the prior session is closed first (re-handshake on
// the same device).
func (h *Hub) Register(s *Session) {
	h.mu.Lock()
	// Collect priors to close, but close them AFTER unlocking: Close now
	// invokes OnClose → conn.Close, which can block on the WebSocket close
	// handshake / goroutine teardown. Holding h.mu across that would let one
	// slow socket stall every other send, register, and connectivity check.
	var toClose []*Session
	if prior, ok := h.sessions[s.DeviceID]; ok {
		toClose = append(toClose, prior)
	}
	if prior, ok := h.byUser[s.UserID]; ok && prior != s {
		toClose = append(toClose, prior)
	}
	h.sessions[s.DeviceID] = s
	h.byUser[s.UserID] = s
	cb := h.OnRegister
	h.mu.Unlock()
	for _, prior := range toClose {
		prior.Close()
	}
	if cb != nil {
		// Async: Register returns immediately so the caller's drain
		// loop (`for body := range sess.Out`) starts consuming before
		// the replay enqueues. Running it synchronously here filled the
		// 64-slot outbound channel before anything drained it, starving
		// the queued call offer at the tail.
		go cb(s.UserID)
	}
}

// Unregister removes a session and closes its outbound channel.
func (h *Hub) Unregister(s *Session) {
	h.mu.Lock()
	if cur, ok := h.sessions[s.DeviceID]; ok && cur == s {
		delete(h.sessions, s.DeviceID)
	}
	if cur, ok := h.byUser[s.UserID]; ok && cur == s {
		delete(h.byUser, s.UserID)
	}
	h.mu.Unlock()
	// Close (→ OnClose → conn.Close) can block on the socket close
	// handshake; run it after releasing h.mu so a stuck socket can't stall
	// the whole hub. Mirrors DisconnectUser/DisconnectDevice/CloseAll.
	s.Close()
}

// SendToUser delivers ev to the user's active session, if connected.
// Returns true if the session was found and the event was queued.
// Delivery distinguishes WHY a SendToUser didn't land, so callers can tell an
// offline peer (durable replay on reconnect is appropriate) from a live but
// backpressured one (parking for reconnect-flush would strand the frame because
// no reconnect fires — the caller must retry instead).
type Delivery int

const (
	DeliveryDelivered     Delivery = iota // queued to the live session's channel
	DeliveryNoSession                     // no live session for the user
	DeliveryBackpressured                 // live session, but its channel is full / closing
)

func (h *Hub) SendToUser(userID string, ev Event) bool {
	return h.SendToUserResult(userID, ev) == DeliveryDelivered
}

// SendToUserResult is SendToUser with the failure reason exposed.
func (h *Hub) SendToUserResult(userID string, ev Event) Delivery {
	h.mu.RLock()
	s := h.byUser[userID]
	h.mu.RUnlock()
	if s == nil {
		return DeliveryNoSession
	}
	if enqueue(s, ev) {
		return DeliveryDelivered
	}
	return DeliveryBackpressured
}

// SendToDevice delivers ev to a specific device's session, if connected.
func (h *Hub) SendToDevice(deviceID string, ev Event) bool {
	h.mu.RLock()
	s := h.sessions[deviceID]
	h.mu.RUnlock()
	if s == nil {
		return false
	}
	return enqueue(s, ev)
}

// Broadcast fans the event out to every connected session.
func (h *Hub) Broadcast(ev Event) int {
	h.mu.RLock()
	snapshot := make([]*Session, 0, len(h.sessions))
	for _, s := range h.sessions {
		snapshot = append(snapshot, s)
	}
	h.mu.RUnlock()
	delivered := 0
	for _, s := range snapshot {
		if enqueue(s, ev) {
			delivered++
		}
	}
	return delivered
}

// CloseAll terminates every registered session and clears the session
// maps. Used by the backup service after broadcasting server_restored so
// clients are forced to re-handshake against the freshly-rotated jwt_kid.
//
// Returns the number of sessions that were closed.
func (h *Hub) CloseAll() int {
	h.mu.Lock()
	snapshot := make([]*Session, 0, len(h.sessions))
	for _, s := range h.sessions {
		snapshot = append(snapshot, s)
	}
	h.sessions = make(map[string]*Session)
	h.byUser = make(map[string]*Session)
	h.mu.Unlock()
	for _, s := range snapshot {
		s.Close()
	}
	return len(snapshot)
}

// DisconnectUser closes any live session for userID. Called after the
// user is revoked so an already-connected WebSocket — whose claims were
// validated only at the upgrade — stops receiving events and can't keep
// sending typing / call signaling until its socket happens to drop.
// Returns the number of sessions closed.
func (h *Hub) DisconnectUser(userID string) int {
	h.mu.Lock()
	s := h.byUser[userID]
	if s != nil {
		delete(h.byUser, userID)
		delete(h.sessions, s.DeviceID)
	}
	h.mu.Unlock()
	if s == nil {
		return 0
	}
	s.Close()
	return 1
}

// DisconnectDevice closes the live session for deviceID, if any.
func (h *Hub) DisconnectDevice(deviceID string) int {
	h.mu.Lock()
	s := h.sessions[deviceID]
	if s != nil {
		delete(h.sessions, deviceID)
		if cur, ok := h.byUser[s.UserID]; ok && cur == s {
			delete(h.byUser, s.UserID)
		}
	}
	h.mu.Unlock()
	if s == nil {
		return 0
	}
	s.Close()
	return 1
}

// SessionCount returns the number of connected sessions.
func (h *Hub) SessionCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.sessions)
}

// IsConnected reports whether a session for user_id is currently registered.
func (h *Hub) IsConnected(userID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.byUser[userID]
	return ok
}

func enqueue(s *Session, ev Event) bool {
	body, err := json.Marshal(ev)
	if err != nil {
		return false
	}
	// Hold the session mutex across the IsClosed check and the channel
	// send so Close() (which takes the same mutex before closing s.Out)
	// cannot race with us. This eliminates the TOCTOU between checking
	// closed and sending; no recover() games required.
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return false
	}
	select {
	case s.Out <- body:
		return true
	default:
		// Backpressure: drop the message — Slice 2+ may revise this
		// policy. For now, signal failure to deliver.
		return false
	}
}
