package ws_test

import (
	"encoding/json"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/ws"
)

func TestHub_RegisterAndSendToUser(t *testing.T) {
	hub := ws.NewHub()
	sess := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 4)}
	hub.Register(sess)
	defer hub.Unregister(sess)

	delivered := hub.SendToUser("u1", ws.PresenceChanged("u1", true, 1))
	assert.True(t, delivered)
	body := <-sess.Out
	var got map[string]any
	require.NoError(t, json.Unmarshal(body, &got))
	assert.Equal(t, "presence_changed", got["type"])
}

func TestHub_SendToUnknownUser(t *testing.T) {
	hub := ws.NewHub()
	delivered := hub.SendToUser("ghost", ws.PresenceChanged("ghost", true, 1))
	assert.False(t, delivered)
}

func TestHub_BroadcastReachesEverySession(t *testing.T) {
	hub := ws.NewHub()
	a := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 4)}
	b := &ws.Session{UserID: "u2", DeviceID: "d2", Out: make(chan []byte, 4)}
	hub.Register(a)
	hub.Register(b)
	defer hub.Unregister(a)
	defer hub.Unregister(b)

	n := hub.Broadcast(ws.PresenceChanged("u3", true, 100))
	assert.Equal(t, 2, n)
	<-a.Out
	<-b.Out
}

func TestHub_SecondSessionForSameDeviceReplacesPrior(t *testing.T) {
	hub := ws.NewHub()
	a := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 4)}
	hub.Register(a)
	b := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 4)}
	hub.Register(b)
	defer hub.Unregister(b)

	assert.True(t, a.IsClosed(), "prior session must be closed when re-registering same device")
	assert.False(t, b.IsClosed())
}

func TestSession_SendAfterUnregisterDoesNotPanic(t *testing.T) {
	hub := ws.NewHub()
	sess := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 4)}
	hub.Register(sess)
	hub.Unregister(sess)

	// With the recover() crutch in place this would silently swallow
	// any panic; with the lock-based fix the broadcast deterministically
	// drops the message and returns 0 deliveries.
	assert.NotPanics(t, func() {
		n := hub.Broadcast(ws.PresenceChanged("u3", true, 1))
		assert.Equal(t, 0, n, "broadcast after unregister must deliver to no one")
	})
}

func TestHub_SessionCount(t *testing.T) {
	hub := ws.NewHub()
	assert.Equal(t, 0, hub.SessionCount())
	a := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 1)}
	hub.Register(a)
	assert.Equal(t, 1, hub.SessionCount())
	hub.Unregister(a)
	assert.Equal(t, 0, hub.SessionCount())
}

func TestServerRestoredEvent_HasCanonicalShape(t *testing.T) {
	ev := ws.ServerRestored(42, "kid-rotated", 1_700_000_000_000)
	body, err := json.Marshal(ev)
	require.NoError(t, err)
	var got map[string]any
	require.NoError(t, json.Unmarshal(body, &got))
	assert.Equal(t, "server_restored", got["type"])
	assert.Equal(t, float64(42), got["generation"])
	assert.Equal(t, "kid-rotated", got["jwt_kid"])
	assert.Equal(t, float64(1_700_000_000_000), got["at"])
}

func TestHub_CloseAll_ClosesEverySessionAndZeroesCount(t *testing.T) {
	hub := ws.NewHub()
	a := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 1)}
	b := &ws.Session{UserID: "u2", DeviceID: "d2", Out: make(chan []byte, 1)}
	hub.Register(a)
	hub.Register(b)

	closed := hub.CloseAll()
	assert.Equal(t, 2, closed)
	assert.Equal(t, 0, hub.SessionCount())
	assert.True(t, a.IsClosed())
	assert.True(t, b.IsClosed())
}

// TestHub_DisconnectUserSeversSocket guards the trust-boundary fix: revoking a
// user must sever the underlying connection (via OnClose), not merely drop the
// hub map entry. Without OnClose the reader goroutine keeps relaying inbound
// typing / call_signal under the revoked socket's upgrade-time claims until its
// next read errors or the 30s revalidation tick fires.
func TestHub_DisconnectUserSeversSocket(t *testing.T) {
	hub := ws.NewHub()
	var severed atomic.Int32
	sess := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 4)}
	sess.OnClose = func() { severed.Add(1) }
	hub.Register(sess)

	require.Equal(t, 1, hub.DisconnectUser("u1"))
	assert.Equal(t, int32(1), severed.Load(),
		"DisconnectUser must sever the connection, not just drop the map entry")
	assert.False(t, hub.IsConnected("u1"))

	// A follow-up Unregister (the handler's deferred cleanup) must not
	// re-fire the sever hook — Close is idempotent.
	hub.Unregister(sess)
	assert.Equal(t, int32(1), severed.Load(), "OnClose must fire exactly once")
}

// TestHub_DisconnectDeviceSeversSocket is the device-revoke counterpart.
func TestHub_DisconnectDeviceSeversSocket(t *testing.T) {
	hub := ws.NewHub()
	var severed atomic.Int32
	sess := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 4)}
	sess.OnClose = func() { severed.Add(1) }
	hub.Register(sess)

	require.Equal(t, 1, hub.DisconnectDevice("d1"))
	assert.Equal(t, int32(1), severed.Load(),
		"DisconnectDevice must sever the connection, not just drop the map entry")
}

// TestHub_RehandshakeSeversPriorSocket covers re-enrollment / same-device
// re-handshake: registering a replacement session must sever the prior one's
// socket immediately.
func TestHub_RehandshakeSeversPriorSocket(t *testing.T) {
	hub := ws.NewHub()
	var priorSevered atomic.Int32
	prior := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 4)}
	prior.OnClose = func() { priorSevered.Add(1) }
	hub.Register(prior)

	next := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 4)}
	hub.Register(next) // same device → prior must be severed
	defer hub.Unregister(next)

	assert.Equal(t, int32(1), priorSevered.Load(),
		"re-handshake on the same device must sever the prior socket")
}

// TestHub_BlockingOnCloseDoesNotHoldLock guards the availability fix: Close
// now severs the socket via OnClose (a potentially blocking conn.Close), so
// Register/Unregister must NOT hold the hub mutex across it — otherwise one
// stuck socket stalls every other send, register, and connectivity check.
func TestHub_BlockingOnCloseDoesNotHoldLock(t *testing.T) {
	hub := ws.NewHub()
	release := make(chan struct{})
	slow := &ws.Session{UserID: "u1", DeviceID: "d1", Out: make(chan []byte, 1)}
	slow.OnClose = func() { <-release } // blocks inside Close until released
	hub.Register(slow)

	other := &ws.Session{UserID: "u2", DeviceID: "d2", Out: make(chan []byte, 1)}
	hub.Register(other)

	// Unregister the slow session; its OnClose blocks inside Close.
	unregDone := make(chan struct{})
	go func() { hub.Unregister(slow); close(unregDone) }()

	// While that close is blocked, an unrelated hub op must complete
	// promptly — proving the hub mutex is not held across the blocking close.
	opDone := make(chan bool, 1)
	go func() { opDone <- hub.SendToUser("u2", ws.PresenceChanged("u2", true, 1)) }()
	select {
	case ok := <-opDone:
		assert.True(t, ok, "send to an unrelated user must succeed while a close blocks")
	case <-time.After(2 * time.Second):
		t.Fatal("hub op blocked while a socket close was in progress — Close held the hub lock")
	}

	close(release) // let the blocked close finish
	<-unregDone
	hub.Unregister(other)
}
