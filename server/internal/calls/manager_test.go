package calls_test

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/calls"
	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// ---- test helpers ----

func newTestDB(t *testing.T, clock storage.Clock) *storage.DB {
	t.Helper()
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "calls_test.db"), clock)
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// seedUsers inserts minimal user rows so FK constraints are satisfied.
func seedUsers(t *testing.T, db *storage.DB, userIDs ...string) {
	t.Helper()
	for i, uid := range userIDs {
		_, err := db.ExecContext(context.Background(),
			`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, ?, ?)`,
			uid, "User"+string(rune('A'+i)), i, 1000,
		)
		require.NoError(t, err)
	}
}

const (
	callerID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	calleeID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
	thirdID  = "cccccccc-cccc-cccc-cccc-cccccccccccc"
)

func newManager(t *testing.T, db *storage.DB, hub *ws.Hub) *calls.Manager {
	t.Helper()
	m := calls.New(db, hub)
	return m
}

// ---- Create ----

func TestCreate_Success(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	result, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)
	assert.NotEmpty(t, result.CallID)
	assert.Equal(t, calls.StateRinging, result.State)
}

func TestCreate_Glare_ExistingRinging(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	// First call succeeds.
	_, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	// Second call from same pair → glare 409.
	_, err = m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.Error(t, err)
	var glareErr *calls.GlareError
	require.True(t, errors.As(err, &glareErr), "expected GlareError, got %T: %v", err, err)
	assert.Equal(t, callerID, glareErr.Info.ExistingCallerUserID)
}

func TestCreate_Glare_ReverseDirection(t *testing.T) {
	// Glare check covers both (a→b) and (b→a) orderings within the same user pair.
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	// Caller calls callee first.
	_, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	// Callee tries to call caller in the opposite direction — should still glare.
	_, err = m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: calleeID,
		CalleeUserID: callerID,
		Kind:         calls.KindAudio,
	})
	var glareErr *calls.GlareError
	require.True(t, errors.As(err, &glareErr), "expected GlareError for reverse-direction call, got %T: %v", err, err)
}

// TestCreate_Busy_ThirdPartyRinging covers the round-32 invariant: a user
// already ringing/connected with one peer cannot be pulled into a second call
// by a different caller. Enforced server-side regardless of client gating.
func TestCreate_Busy_ThirdPartyRinging(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID, thirdID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	// caller↔callee ringing.
	first, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	// third tries to ring callee (already busy) → busy 409, NOT glare.
	_, err = m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: thirdID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	var busyErr *calls.BusyError
	require.True(t, errors.As(err, &busyErr), "expected BusyError, got %T: %v", err, err)
	assert.False(t, errors.As(err, new(*calls.GlareError)), "a cross-pair conflict must not be reported as glare")
	assert.Equal(t, calleeID, busyErr.BusyUserID)
	assert.Equal(t, first.CallID, busyErr.Info.ExistingCallID)

	// The busy caller side is also protected: third rings the busy caller.
	_, err = m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: thirdID,
		CalleeUserID: callerID,
		Kind:         calls.KindAudio,
	})
	require.True(t, errors.As(err, &busyErr), "ringing a busy caller must also be rejected")
	assert.Equal(t, callerID, busyErr.BusyUserID)

	// And the busy user cannot originate a second outbound call either.
	_, err = m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: calleeID,
		CalleeUserID: thirdID,
		Kind:         calls.KindAudio,
	})
	require.True(t, errors.As(err, &busyErr), "a busy user must not originate a second call")
}

func TestCreate_Glare_ExistingConnected(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	firstResult, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	// Accept → connected.
	_, err = m.Accept(context.Background(), calls.AcceptRequest{
		CallID:        firstResult.CallID,
		SessionUserID: calleeID,
	})
	require.NoError(t, err)

	// New call from same pair while connected → glare.
	_, err = m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	var glareErr *calls.GlareError
	require.True(t, errors.As(err, &glareErr))
	// Round-25: the glare must carry the existing call's STATE so the client
	// can avoid "accepting" a connected call (which would tear it down).
	assert.Equal(t, calls.StateConnected, glareErr.Info.ExistingState)
}

// ---- Accept ----

func TestAccept_Success(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	acc, err := m.Accept(context.Background(), calls.AcceptRequest{
		CallID:        res.CallID,
		SessionUserID: calleeID,
	})
	require.NoError(t, err)
	assert.Equal(t, calls.StateConnected, acc.State)
}

func TestAccept_CallerCannotAccept(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	_, err = m.Accept(context.Background(), calls.AcceptRequest{
		CallID:        res.CallID,
		SessionUserID: callerID, // caller tries to accept own call
	})
	require.ErrorIs(t, err, calls.ErrCalleeOnly)
}

func TestAccept_Missed_Returns_WrongState(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	// Force the call to missed state by advancing the clock past 33s + 3s grace.
	clock.T += int64(37 * time.Second / time.Millisecond)
	_ = m.RunMissedSweep(context.Background())

	_, err = m.Accept(context.Background(), calls.AcceptRequest{
		CallID:        res.CallID,
		SessionUserID: calleeID,
	})
	var ws *calls.WrongStateError
	require.True(t, errors.As(err, &ws))
	assert.Equal(t, calls.StateMissed, ws.Current)
}

func TestAccept_Within_GraceWindow(t *testing.T) {
	// Accept arriving in [33s..36s] should still succeed (3s grace).
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	startedAt := clock.T
	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)
	_ = startedAt

	// Advance to 34s (within grace window — server timer is 33s, grace is 3s).
	clock.T += int64(34 * time.Second / time.Millisecond)

	// Sweep should NOT transition this call yet (it's within grace).
	_ = m.RunMissedSweep(context.Background())

	// Accept should still succeed.
	acc, err := m.Accept(context.Background(), calls.AcceptRequest{
		CallID:        res.CallID,
		SessionUserID: calleeID,
	})
	require.NoError(t, err, "accept within grace window should succeed")
	assert.Equal(t, calls.StateConnected, acc.State)
}

// ---- Decline ----

func TestDecline_Success(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	dec, err := m.Decline(context.Background(), calls.DeclineRequest{
		CallID:        res.CallID,
		SessionUserID: calleeID,
	})
	require.NoError(t, err)
	assert.Equal(t, calls.StateDeclined, dec.State)
}

func TestDecline_CallerCannotDecline(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	_, err = m.Decline(context.Background(), calls.DeclineRequest{
		CallID:        res.CallID,
		SessionUserID: callerID,
	})
	require.ErrorIs(t, err, calls.ErrCalleeOnly)
}

// ---- Cancel ----

func TestCancel_WhileRinging(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	can, err := m.Cancel(context.Background(), calls.CancelRequest{
		CallID:        res.CallID,
		SessionUserID: callerID,
	})
	require.NoError(t, err)
	assert.Equal(t, calls.StateCancelled, can.State)
	assert.Nil(t, can.EndedReason)
}

func TestCancel_AfterConnect_AutoEnds(t *testing.T) {
	// Cancel arriving after call is connected → auto-promote to ended.
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	_, err = m.Accept(context.Background(), calls.AcceptRequest{
		CallID:        res.CallID,
		SessionUserID: calleeID,
	})
	require.NoError(t, err)

	can, err := m.Cancel(context.Background(), calls.CancelRequest{
		CallID:        res.CallID,
		SessionUserID: callerID,
	})
	require.NoError(t, err)
	assert.Equal(t, calls.StateEnded, can.State)
	require.NotNil(t, can.EndedReason)
	assert.Equal(t, string(calls.ReasonAutoEndedFromCancel), *can.EndedReason)
}

func TestCancel_CalleeCannotCancel(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	_, err = m.Cancel(context.Background(), calls.CancelRequest{
		CallID:        res.CallID,
		SessionUserID: calleeID,
	})
	require.ErrorIs(t, err, calls.ErrCallerOnly)
}

// ---- End ----

func TestEnd_Success_Caller(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	_, err = m.Accept(context.Background(), calls.AcceptRequest{
		CallID:        res.CallID,
		SessionUserID: calleeID,
	})
	require.NoError(t, err)

	ended, err := m.End(context.Background(), calls.EndRequest{
		CallID:        res.CallID,
		SessionUserID: callerID,
	})
	require.NoError(t, err)
	assert.Equal(t, calls.StateEnded, ended.State)
	require.NotNil(t, ended.EndedReason)
	assert.Equal(t, string(calls.ReasonNormal), *ended.EndedReason)
}

func TestEnd_WhileRinging_Returns_WrongState(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	_, err = m.End(context.Background(), calls.EndRequest{
		CallID:        res.CallID,
		SessionUserID: callerID,
	})
	var ws *calls.WrongStateError
	require.True(t, errors.As(err, &ws))
	assert.Equal(t, calls.StateRinging, ws.Current)
}

func TestEnd_NotAuthorized(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID, thirdID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	_, err = m.Accept(context.Background(), calls.AcceptRequest{
		CallID:        res.CallID,
		SessionUserID: calleeID,
	})
	require.NoError(t, err)

	_, err = m.End(context.Background(), calls.EndRequest{
		CallID:        res.CallID,
		SessionUserID: thirdID,
	})
	require.ErrorIs(t, err, calls.ErrNotAuthorized)
}

// ---- Missed sweep ----

func TestMissedSweep_TransitionAfter33s(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	// Advance clock beyond 33s ringing timer + 3s grace.
	clock.T += int64(37 * time.Second / time.Millisecond)

	count, err := m.RunMissedSweepCount(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, count)

	// Now try to accept → should get WrongState(missed).
	_, err = m.Accept(context.Background(), calls.AcceptRequest{
		CallID:        res.CallID,
		SessionUserID: calleeID,
	})
	var ws *calls.WrongStateError
	require.True(t, errors.As(err, &ws))
	assert.Equal(t, calls.StateMissed, ws.Current)
}

func TestMissedSweep_NoTransitionWithinGrace(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	_, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	// Advance to 34s — within the 3s grace window (33s timer + 3s grace = 36s cutoff).
	clock.T += int64(34 * time.Second / time.Millisecond)

	count, err := m.RunMissedSweepCount(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 0, count, "call should not be missed yet within grace window")
}

// ---- Relay credentials ----

func TestRelayCredentials_Structure(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	hub := ws.NewHub()
	m := calls.New(db, hub)
	m.TURNSecret = "test-secret"
	m.TURNHost = "turn.example.com"

	creds, err := m.RelayCredentials(context.Background(), callerID)
	require.NoError(t, err)
	assert.NotEmpty(t, creds.Username)
	assert.NotEmpty(t, creds.Password)
	assert.Equal(t, 900, creds.TTLSeconds)
	require.Len(t, creds.URLs, 1)
	assert.Equal(t, "turn:turn.example.com:3478", creds.URLs[0])
}

// ---- Startup sweep (stale calls) ----

func TestStartupSweep_StaleRinging(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	// Create a call and then advance the clock by > 4h.
	_, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	clock.T += int64(5 * time.Hour / time.Millisecond)

	count, err := m.RunStartupSweep(context.Background())
	require.NoError(t, err)
	assert.GreaterOrEqual(t, count, 1)
}

func TestStartupSweep_StaleConnected(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	_, err = m.Accept(context.Background(), calls.AcceptRequest{
		CallID:        res.CallID,
		SessionUserID: calleeID,
	})
	require.NoError(t, err)

	clock.T += int64(5 * time.Hour / time.Millisecond)

	count, err := m.RunStartupSweep(context.Background())
	require.NoError(t, err)
	assert.GreaterOrEqual(t, count, 1)
}

// ---- Missed-call delivery ----

func TestMissedCallDelivery_QueuedAndDelivered(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	// Expire the call.
	clock.T += int64(37 * time.Second / time.Millisecond)
	_ = m.RunMissedSweep(context.Background())

	// The callee reconnects — only then can the missed event actually be
	// delivered (and marked notified).
	out := registerPeer(t, hub, calleeID)
	delivered, err := m.DeliverMissedCalls(context.Background(), calleeID)
	require.NoError(t, err)
	assert.Equal(t, 1, delivered)
	select {
	case body := <-out:
		assert.Contains(t, string(body), "call_missed")
		assert.Contains(t, string(body), res.CallID)
	default:
		t.Fatal("callee did not receive the call_missed event")
	}

	// Idempotent: a second delivery (already notified) emits nothing.
	again, err := m.DeliverMissedCalls(context.Background(), calleeID)
	require.NoError(t, err)
	assert.Equal(t, 0, again, "missed_notified must not re-deliver")
}

// TestMissedSweep_OnlineCallee_NotRedeliveredOnReconnect guards the round-59
// design-review fix: when the callee is ONLINE as the call times out, the 5s
// sweep delivers `call_missed` live AND marks it notified — so a later
// reconnect's DeliverMissedCalls must not emit the same missed call again
// (duplicate missed-call UI/push).
func TestMissedSweep_OnlineCallee_NotRedeliveredOnReconnect(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err)

	// Callee is ONLINE when the call times out and the sweep runs.
	out := registerPeer(t, hub, calleeID)
	clock.T += int64(37 * time.Second / time.Millisecond)
	_, err = m.RunMissedSweepCount(context.Background())
	require.NoError(t, err)

	// The sweep delivered the missed event live.
	select {
	case body := <-out:
		assert.Contains(t, string(body), "call_missed")
		assert.Contains(t, string(body), res.CallID)
	default:
		t.Fatal("online callee did not receive the live missed event from the sweep")
	}

	// Reconnect: DeliverMissedCalls must NOT re-deliver — the sweep already
	// marked it notified.
	again, err := m.DeliverMissedCalls(context.Background(), calleeID)
	require.NoError(t, err)
	assert.Equal(t, 0, again, "a live-delivered missed call must not be re-sent on reconnect")
}

// TestMissedCallDelivery_RetriesWhenOffline guards the round-26 fix: a
// missed call whose delivery couldn't be enqueued (callee offline) stays
// missed_notified=0 and is retried on the next register, rather than being
// marked delivered and lost.
func TestMissedCallDelivery_RetriesWhenOffline(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err)
	clock.T += int64(37 * time.Second / time.Millisecond)
	_ = m.RunMissedSweep(context.Background())

	// Callee still offline → nothing delivered, nothing marked.
	delivered, err := m.DeliverMissedCalls(context.Background(), calleeID)
	require.NoError(t, err)
	assert.Equal(t, 0, delivered, "offline callee: no delivery")

	// Now it reconnects → the still-pending missed call delivers.
	out := registerPeer(t, hub, calleeID)
	delivered, err = m.DeliverMissedCalls(context.Background(), calleeID)
	require.NoError(t, err)
	assert.Equal(t, 1, delivered, "retry after reconnect must deliver")
	select {
	case body := <-out:
		assert.Contains(t, string(body), res.CallID)
	default:
		t.Fatal("missed call was not retried after reconnect")
	}
}

// ---- ListRecentCalls ----

func TestListRecentCalls_Pagination(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	// Create 3 calls, cancelling each before creating the next.
	for i := 0; i < 3; i++ {
		clock.T += 1000
		res, err := m.Create(context.Background(), calls.CreateRequest{
			CallerUserID: callerID,
			CalleeUserID: calleeID,
			Kind:         calls.KindAudio,
		})
		require.NoError(t, err)
		// Cancel so glare check won't fire on next iteration.
		_, err = m.Cancel(context.Background(), calls.CancelRequest{
			CallID:        res.CallID,
			SessionUserID: callerID,
		})
		require.NoError(t, err)
	}

	rows, err := m.ListRecentCalls(context.Background(), calls.ListRecentCallsRequest{
		Limit: 2,
	})
	require.NoError(t, err)
	assert.Len(t, rows, 2)

	// Paginate using before_started_at.
	rows2, err := m.ListRecentCalls(context.Background(), calls.ListRecentCallsRequest{
		Limit:           2,
		BeforeStartedAt: &rows[len(rows)-1].StartedAt,
	})
	require.NoError(t, err)
	assert.Len(t, rows2, 1)
}

// ---- RelaySignal ----

// registerPeer attaches a live WS session for userID and returns its Out
// channel so tests can assert on relayed call_signal events.
func registerPeer(t *testing.T, hub *ws.Hub, userID string) chan []byte {
	t.Helper()
	out := make(chan []byte, 8)
	hub.Register(&ws.Session{UserID: userID, DeviceID: userID + "-dev", Out: out})
	return out
}

func TestRelaySignal_CallerToCallee_WhileRinging(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	calleeOut := registerPeer(t, hub, calleeID)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindVideo,
	})
	require.NoError(t, err)
	// Drain the incoming_call event Create fanned out to the callee.
	<-calleeOut

	err = m.RelaySignal(context.Background(), res.CallID, callerID, "", map[string]any{
		"kind": "offer", "sdp": "v=0 fake-offer",
	})
	require.NoError(t, err)

	select {
	case body := <-calleeOut:
		s := string(body)
		assert.Contains(t, s, `"type":"call_signal"`)
		assert.Contains(t, s, res.CallID)
		assert.Contains(t, s, "fake-offer")
	default:
		t.Fatal("callee did not receive the relayed call_signal")
	}
}

// TestRelaySignal_SalvagedOnWriteFailure_ReplaysOnReconnect guards the
// round-14 finding: SendToUser reports success when a frame enters the
// session channel, not when conn.Write succeeds. If the peer socket dies
// after enqueue, the writer fails to write and the SDP/ICE frame would be
// lost. The WS writer hands the buffered-but-unwritten frame to
// RequeueUndeliveredSignals, which must re-queue it so it replays on the
// peer's next registration.
func TestRelaySignal_SalvagedOnWriteFailure_ReplaysOnReconnect(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindVideo,
	})
	require.NoError(t, err)

	// The writer serialized this offer to the (now dead) callee socket and
	// conn.Write failed — hand the exact buffered frame to the salvage path.
	frame, err := json.Marshal(ws.CallSignal(res.CallID, map[string]any{
		"kind": "offer", "sdp": "v=0 salvaged-offer",
	}, clock.T))
	require.NoError(t, err)
	m.RequeueUndeliveredSignals(calleeID, [][]byte{frame})

	// Callee reconnects: the salvaged offer must replay to the fresh session.
	calleeOut := registerPeer(t, hub, calleeID)
	m.FlushPendingSignals(calleeID)

	select {
	case body := <-calleeOut:
		s := string(body)
		assert.Contains(t, s, `"type":"call_signal"`)
		assert.Contains(t, s, res.CallID)
		assert.Contains(t, s, "salvaged-offer")
	case <-time.After(time.Second):
		t.Fatal("salvaged signal did not replay on reconnect")
	}
}

// TestRequeueUndeliveredSignals_DropsTerminalCall covers the round-44 finding:
// a call_signal salvaged AFTER its call terminated (it was in a dead session's
// channel when cancel/end purged the queue, then the writer reported it on its
// next failed write) must not be resurrected. On the peer's reconnect it must
// receive NO call_signal for the dead call, while the terminal snapshot still
// replays.
func TestRequeueUndeliveredSignals_DropsTerminalCall(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	ctx := context.Background()

	res, err := m.Create(ctx, calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)

	// The call terminates (cancelled) and its replay queue is purged.
	_, err = db.ExecContext(ctx,
		`UPDATE calls SET state = 'cancelled', ended_at = ? WHERE id = ?`, clock.T, res.CallID)
	require.NoError(t, err)
	m.RequeueUndeliveredSignals(calleeID, [][]byte{mustSignalFrame(t, res.CallID, "v=0 stale-after-cancel", clock.T)})

	// Callee reconnects: OnWSRegister flushes pending signals + replays terminal
	// snapshots. It must get the cancelled snapshot but NO call_signal.
	calleeOut := registerPeer(t, hub, calleeID)
	m.OnWSRegister(calleeID)

	deadline := time.After(500 * time.Millisecond)
	sawTerminal := false
	for {
		select {
		case body := <-calleeOut:
			s := string(body)
			require.NotContains(t, s, `"type":"call_signal"`,
				"a terminal call's stale signal must never replay")
			if strings.Contains(s, "call_state_changed") && strings.Contains(s, "cancelled") {
				sawTerminal = true
			}
		case <-deadline:
			require.True(t, sawTerminal, "the terminal snapshot must still replay on reconnect")
			return
		}
	}
}

// TestRequeueUndeliveredSignals_PreservesByteBudget covers the round-47
// finding: a salvaged/requeued signal must carry its encoded size, or a later
// live RelaySignal — which enforces maxPendingSignalBytesPerCall by summing
// sizes — would see the salvaged frames as 0 bytes and blow past the budget.
func TestRequeueUndeliveredSignals_PreservesByteBudget(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	ctx := context.Background()

	res, err := m.Create(ctx, calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)

	// Callee stays offline. Salvage enough ~12 KiB frames to exceed the
	// 256 KiB per-call byte budget (22 * 12 KiB = 264 KiB), well under the
	// 64-count cap so the BYTE budget is what must bind next.
	blob := strings.Repeat("x", 12*1024)
	for i := 0; i < 22; i++ {
		m.RequeueUndeliveredSignals(calleeID, [][]byte{mustSignalFrame(t, res.CallID, blob, clock.T)})
	}

	// A live relay to the still-offline callee must now hit the byte budget —
	// proving the salvaged frames counted their real size, not zero.
	err = m.RelaySignal(ctx, res.CallID, callerID, "sig-over", map[string]any{"sdp": blob})
	require.ErrorIs(t, err, calls.ErrSignalQueueFull,
		"salvaged frames must count toward the byte budget")
}

// mustSignalFrame builds the wire bytes the WS writer would salvage for a
// call_signal offer.
func mustSignalFrame(t *testing.T, callID, sdp string, now int64) []byte {
	t.Helper()
	frame, err := json.Marshal(ws.CallSignal(callID, map[string]any{"kind": "offer", "sdp": sdp}, now))
	require.NoError(t, err)
	return frame
}

// TestRelaySignal_DedupsBySignalID guards the round-17 idempotency
// requirement: a client that didn't get the ack re-sends the same signal_id
// on reconnect. The server must relay it to the peer only ONCE — a second
// delivery would hand the peer a duplicate offer/answer.
func TestRelaySignal_RejectsOversizedSignalID(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	calleeOut := registerPeer(t, hub, calleeID)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)
	<-calleeOut // drain incoming_call

	// An oversized client-chosen signal_id must be rejected before it can be
	// stored in the bounded dedup set.
	huge := strings.Repeat("x", 65)
	err = m.RelaySignal(context.Background(), res.CallID, callerID, huge, map[string]any{"sdp": "x"})
	require.ErrorIs(t, err, calls.ErrSignalTooLarge)
}

func TestRelaySignal_DedupsBySignalID(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	calleeOut := registerPeer(t, hub, calleeID)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)
	<-calleeOut // drain incoming_call

	offer := map[string]any{"kind": "offer", "sdp": "v=0 once"}
	require.NoError(t, m.RelaySignal(context.Background(), res.CallID, callerID, "sig-A", offer))
	select {
	case body := <-calleeOut:
		assert.Contains(t, string(body), "v=0 once")
	default:
		t.Fatal("first relay must reach the callee")
	}

	// Same signal_id again (client retry after a lost ack) → no second relay.
	require.NoError(t, m.RelaySignal(context.Background(), res.CallID, callerID, "sig-A", offer))
	select {
	case body := <-calleeOut:
		t.Fatalf("duplicate signal_id must not re-deliver, got %s", string(body))
	default:
		// expected — deduped
	}
}

// TestRelaySignal_QueueFull_ReturnsError guards the round-18 finding: when
// the peer is offline and its replay queue saturates, RelaySignal must
// surface an error so the WS handler withholds the ack — otherwise the
// sender drops its only copy on a false success and the call strands.
func TestRelaySignal_QueueFull_ReturnsError(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	// Callee NEVER registers → every signal queues.
	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)

	// Fill the per-call queue (64). Distinct signal ids so none dedup.
	for i := 0; i < 64; i++ {
		require.NoError(t, m.RelaySignal(context.Background(), res.CallID, callerID,
			"sig-"+strconv.Itoa(i), map[string]any{"kind": "ice", "n": i}))
	}
	// The 65th can be neither delivered nor queued → error, no false ack.
	err = m.RelaySignal(context.Background(), res.CallID, callerID, "sig-overflow",
		map[string]any{"kind": "ice"})
	require.ErrorIs(t, err, calls.ErrSignalQueueFull)

	// The overflow signal must NOT have been recorded as seen: once the
	// peer is live, the client's retry of the SAME signal_id must relay,
	// not be falsely deduped into a no-op + ack.
	calleeOut := registerPeer(t, hub, calleeID)
	require.NoError(t, m.RelaySignal(context.Background(), res.CallID, callerID, "sig-overflow",
		map[string]any{"kind": "ice", "sdp": "v=0 overflow-retry"}))
	select {
	case body := <-calleeOut:
		assert.Contains(t, string(body), "overflow-retry", "retry of an un-acked overflow signal must relay")
	case <-time.After(time.Second):
		t.Fatal("overflow signal retry was falsely deduped")
	}
}

// TestRelaySignal_OversizedPayloadRejected covers the round-34 finding: a
// single call_signal payload over the byte cap is rejected (and not ack'd) so
// it can be neither relayed nor parked — bounding the memory a participant can
// pin. A normal-size payload still relays.
func TestRelaySignal_OversizedPayloadRejected(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)
	calleeOut := registerPeer(t, hub, calleeID)

	// ~64 KiB SDP blob — well over the 16 KiB cap.
	huge := strings.Repeat("v=0\r\n", 16*1024)
	err = m.RelaySignal(context.Background(), res.CallID, callerID, "sig-huge",
		map[string]any{"kind": "offer", "sdp": huge})
	require.ErrorIs(t, err, calls.ErrSignalTooLarge)
	select {
	case <-calleeOut:
		t.Fatal("an oversized signal must not be relayed")
	case <-time.After(100 * time.Millisecond):
	}

	// A normal payload still goes through.
	require.NoError(t, m.RelaySignal(context.Background(), res.CallID, callerID, "sig-ok",
		map[string]any{"kind": "ice", "sdp": "v=0 normal"}))
	select {
	case body := <-calleeOut:
		assert.Contains(t, string(body), "normal")
	case <-time.After(time.Second):
		t.Fatal("a normal-size signal must relay")
	}
}

// TestRelaySignal_PerCallByteBudgetBounded covers the round-34 byte-budget
// cap: even with payloads each under the single-frame limit, the TOTAL bytes
// parked in one call's offline replay queue are bounded independent of the
// 64-count cap.
func TestRelaySignal_PerCallByteBudgetBounded(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	// Callee NEVER registers → every signal queues.
	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)

	// Each ~12 KiB (< 16 KiB single-frame cap). The 256 KiB byte budget is hit
	// well before the 64-count cap, so an over-budget frame returns the
	// queue-full error (neither relayed nor parked, no false ack).
	blob := strings.Repeat("x", 12*1024)
	var lastErr error
	queued := 0
	for i := 0; i < 64; i++ {
		lastErr = m.RelaySignal(context.Background(), res.CallID, callerID,
			"sig-"+strconv.Itoa(i), map[string]any{"sdp": blob})
		if lastErr != nil {
			break
		}
		queued++
	}
	require.ErrorIs(t, lastErr, calls.ErrSignalQueueFull,
		"the byte budget must reject before the 64-count cap is reached")
	assert.Less(t, queued, 64, "byte budget should cap the queue below the count limit")
}

// TestRelaySignal_LiveBackpressure_WithholdsAckAndRetries covers the round-53
// finding: a peer with a LIVE session but a FULL outbound channel must NOT be
// treated as offline. Parking the signal would strand it (no reconnect flushes
// a still-connected peer), so RelaySignal returns queue-full — the handler
// withholds the ack — without permanently deduping the signal_id, so a retry
// once the channel drains delivers.
func TestRelaySignal_LiveBackpressure_WithholdsAckAndRetries(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	ctx := context.Background()
	res, err := m.Create(ctx, calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)

	// Callee is LIVE but its 1-slot outbound channel is already saturated.
	out := make(chan []byte, 1)
	hub.Register(&ws.Session{UserID: calleeID, DeviceID: calleeID + "-dev", Out: out})
	out <- []byte("prefill")

	// Backpressured → queue-full (ack withheld), not parked as offline.
	err = m.RelaySignal(ctx, res.CallID, callerID, "sig-1", map[string]any{"sdp": "v=0 offer"})
	require.ErrorIs(t, err, calls.ErrSignalQueueFull)

	// Drain, then retry the SAME signal_id → must deliver (not falsely deduped).
	<-out
	err = m.RelaySignal(ctx, res.CallID, callerID, "sig-1", map[string]any{"sdp": "v=0 offer-retry"})
	require.NoError(t, err)
	select {
	case body := <-out:
		assert.Contains(t, string(body), "offer-retry")
	case <-time.After(time.Second):
		t.Fatal("retry after drain must deliver — a backpressured signal_id was wrongly deduped")
	}
}

// TestRelaySignal_DedupStateIsBounded guards the round-20 finding: the
// per-call dedup set must be bounded so a connected participant can't
// exhaust server memory with unlimited unique signal ids. Past the cap the
// OLDEST id is evicted, so re-relaying it delivers again (rather than being
// deduped forever, which would imply unbounded retention).
func TestRelaySignal_DedupStateIsBounded(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	// Large channel so every relay delivers live (and is marked seen).
	out := make(chan []byte, 4096)
	hub.Register(&ws.Session{UserID: calleeID, DeviceID: calleeID + "-dev", Out: out})

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)
	<-out // drain incoming_call

	// Relay well past the dedup cap (512) with distinct ids.
	for i := 0; i < 700; i++ {
		require.NoError(t, m.RelaySignal(context.Background(), res.CallID, callerID,
			"sig-"+strconv.Itoa(i), map[string]any{"kind": "ice", "n": i}))
	}
	// Drain everything delivered so far.
	for len(out) > 0 {
		<-out
	}

	// The OLDEST id (sig-0) must have been evicted from the dedup set, so a
	// re-relay delivers again — proving retention is bounded, not infinite.
	require.NoError(t, m.RelaySignal(context.Background(), res.CallID, callerID,
		"sig-0", map[string]any{"kind": "ice", "sdp": "evicted-redelivery"}))
	select {
	case body := <-out:
		assert.Contains(t, string(body), "evicted-redelivery",
			"the oldest signal id must be evicted past the cap (bounded retention)")
	case <-time.After(time.Second):
		t.Fatal("oldest signal id was retained forever — dedup set is unbounded")
	}
}

// TestRequeueUndeliveredSignals_DoesNotDropAckedOverflow guards the
// round-25 finding: salvaged frames were already ACKed (SendToUser accepted
// them), so the writer-failure salvage must NOT drop them past the
// live-relay queue cap — that would permanently lose SDP/ICE. A full
// channel-drain worth of frames (more than maxPendingSignalsPerCall) must
// all replay on the peer's reconnect.
// TestRequeueUndeliveredSignals_KeepsAckedWithinBudget guards the round-27
// durability intent WITHIN the per-call budget: a realistic handshake's
// already-acked frames must all survive salvage + reconnect (none cap-dropped).
// The aggregate bound for abusive over-budget salvage is covered separately
// (TestRequeueUndeliveredSignals_BoundedAcrossSalvageCycles).
func TestRequeueUndeliveredSignals_KeepsAckedWithinBudget(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)

	const n = 60 // within maxPendingSignalsPerCall (64) — nothing evicted
	frames := make([][]byte, 0, n)
	for i := 0; i < n; i++ {
		body, mErr := json.Marshal(ws.CallSignal(res.CallID, map[string]any{
			"kind": "ice", "sdp": "salvage-" + strconv.Itoa(i),
		}, clock.T))
		require.NoError(t, mErr)
		frames = append(frames, body)
	}
	m.RequeueUndeliveredSignals(calleeID, frames)

	// Callee reconnects: every salvaged frame must replay, none dropped.
	out := make(chan []byte, 4096)
	hub.Register(&ws.Session{UserID: calleeID, DeviceID: calleeID + "-dev", Out: out})
	m.FlushPendingSignals(calleeID)

	delivered := 0
	deadline := time.After(2 * time.Second)
	for delivered < n {
		select {
		case <-out:
			delivered++
		case <-deadline:
			t.Fatalf("only %d/%d salvaged signals replayed — within-budget overflow was dropped", delivered, n)
		}
	}
}

// TestRequeueUndeliveredSignals_BoundedAcrossSalvageCycles covers the round-50
// finding: repeated salvage cycles (the queue persists across reconnects) must
// NOT grow per-call memory past the caps. Evicting the oldest frames keeps it
// bounded even when an abusive pair floods valid frames.
func TestRequeueUndeliveredSignals_BoundedAcrossSalvageCycles(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)

	// Five salvage cycles of 40 frames each (200 total) — far past the 64-count
	// cap. Without the aggregate bound the queue would hold all 200.
	for cycle := 0; cycle < 5; cycle++ {
		frames := make([][]byte, 0, 40)
		for i := 0; i < 40; i++ {
			body, _ := json.Marshal(ws.CallSignal(res.CallID, map[string]any{
				"kind": "ice", "sdp": "c" + strconv.Itoa(cycle) + "-" + strconv.Itoa(i),
			}, clock.T))
			frames = append(frames, body)
		}
		m.RequeueUndeliveredSignals(calleeID, frames)
	}

	// Drain on reconnect; the replayed count must be bounded by the cap.
	out := make(chan []byte, 4096)
	hub.Register(&ws.Session{UserID: calleeID, DeviceID: calleeID + "-dev", Out: out})
	m.FlushPendingSignals(calleeID)
	time.Sleep(200 * time.Millisecond)
	delivered := 0
	for {
		select {
		case <-out:
			delivered++
			continue
		default:
		}
		break
	}
	assert.LessOrEqual(t, delivered, 64,
		"salvage queue must stay bounded by the per-call count cap across cycles")
}

// TestFlushPendingSignals_RequeueDoesNotDropOnReplayFailure guards the
// round-27 finding (within the per-call budget): when a replay enqueue fails,
// the requeue must preserve EVERY already-accepted signal, or a second write
// failure after salvage permanently loses an offer/answer/ICE the sender
// already dropped. (Over-budget abuse is bounded separately, round-50.)
func TestFlushPendingSignals_RequeueDoesNotDropOnReplayFailure(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)

	const n = 60 // within maxPendingSignalsPerCall (64) — nothing evicted
	frames := make([][]byte, 0, n)
	for i := 0; i < n; i++ {
		body, mErr := json.Marshal(ws.CallSignal(res.CallID, map[string]any{
			"kind": "ice", "sdp": "f-" + strconv.Itoa(i),
		}, clock.T))
		require.NoError(t, mErr)
		frames = append(frames, body)
	}
	m.RequeueUndeliveredSignals(calleeID, frames) // pendingSignals: 70 (uncapped)

	// A flush against a CLOSED session fails every enqueue → all 70 must be
	// requeued, none cap-dropped.
	dead := &ws.Session{UserID: calleeID, DeviceID: calleeID + "-dead", Out: make(chan []byte, 1)}
	hub.Register(dead)
	dead.Close()
	m.FlushPendingSignals(calleeID)

	// A live session then receives every salvaged frame.
	out := make(chan []byte, 4096)
	hub.Register(&ws.Session{UserID: calleeID, DeviceID: calleeID + "-live", Out: out})
	m.FlushPendingSignals(calleeID)

	delivered := 0
	deadline := time.After(2 * time.Second)
	for delivered < n {
		select {
		case <-out:
			delivered++
		case <-deadline:
			t.Fatalf("only %d/%d signals survived a failed-replay requeue", delivered, n)
		}
	}
}

// TestRequeueUndeliveredSignals_ResetsMissedOnWriteFailure guards the
// round-27 finding: a call_missed frame marked notified on channel-accept
// but never written must reset missed_notified=0 so the next register
// re-delivers it.
func TestRequeueUndeliveredSignals_ResetsMissedOnWriteFailure(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err)
	clock.T += int64(37 * time.Second / time.Millisecond)
	_ = m.RunMissedSweep(context.Background())

	out := registerPeer(t, hub, calleeID)
	delivered, err := m.DeliverMissedCalls(context.Background(), calleeID)
	require.NoError(t, err)
	require.Equal(t, 1, delivered)
	<-out // the call_missed frame entered the channel...

	// ...but the write FAILED. The writer salvage hands the frame here.
	frame, err := json.Marshal(ws.CallMissed(res.CallID, callerID, clock.T))
	require.NoError(t, err)
	m.RequeueUndeliveredSignals(calleeID, [][]byte{frame})

	// missed_notified is reset → the next register re-delivers it.
	again, err := m.DeliverMissedCalls(context.Background(), calleeID)
	require.NoError(t, err)
	assert.Equal(t, 1, again, "undelivered call_missed must be retried after write failure")
}

func TestRelaySignal_CalleeToCaller_WhileConnected(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	callerOut := registerPeer(t, hub, callerID)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)
	_, err = m.Accept(context.Background(), calls.AcceptRequest{
		CallID:        res.CallID,
		SessionUserID: calleeID,
	})
	require.NoError(t, err)
	// Drain the call_state_changed(connected) event Accept sent the caller.
	<-callerOut

	err = m.RelaySignal(context.Background(), res.CallID, calleeID, "", map[string]any{
		"kind": "answer", "sdp": "v=0 fake-answer",
	})
	require.NoError(t, err)

	select {
	case body := <-callerOut:
		s := string(body)
		assert.Contains(t, s, `"type":"call_signal"`)
		assert.Contains(t, s, "fake-answer")
	default:
		t.Fatal("caller did not receive the relayed call_signal")
	}
}

func TestRelaySignal_NonParticipant_NotAuthorized(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID, thirdID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)

	err = m.RelaySignal(context.Background(), res.CallID, thirdID, "", map[string]any{"kind": "ice"})
	require.ErrorIs(t, err, calls.ErrNotAuthorized)
}

func TestRelaySignal_TerminalState_WrongState(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID,
		CalleeUserID: calleeID,
		Kind:         calls.KindAudio,
	})
	require.NoError(t, err)
	_, err = m.Cancel(context.Background(), calls.CancelRequest{
		CallID:        res.CallID,
		SessionUserID: callerID,
	})
	require.NoError(t, err)

	err = m.RelaySignal(context.Background(), res.CallID, callerID, "", map[string]any{"kind": "ice"})
	var wsErr *calls.WrongStateError
	require.True(t, errors.As(err, &wsErr), "expected WrongStateError, got %T: %v", err, err)
	assert.Equal(t, calls.StateCancelled, wsErr.Current)
}

func TestRelaySignal_UnknownCall_NotFound(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	err := m.RelaySignal(context.Background(), "no-such-call", callerID, "", map[string]any{"kind": "ice"})
	require.ErrorIs(t, err, calls.ErrNotFound)
}

// ---- Codex-review fixes: expired accept, retransmit, signal replay ----

func TestAccept_Expired_PersistsMissed_AndUnblocksGlare(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err)

	// Past the 33s window + 3s grace, no sweep has run.
	clock.T += 40_000
	_, err = m.Accept(context.Background(), calls.AcceptRequest{
		CallID: res.CallID, SessionUserID: calleeID,
	})
	var wsErr *calls.WrongStateError
	require.True(t, errors.As(err, &wsErr))
	assert.Equal(t, calls.StateMissed, wsErr.Current)

	// The transition must be PERSISTED — otherwise glare detection
	// blocks this pair from ever calling again until a sweep runs.
	res2, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err, "stale ringing row must not glare-block the next call")
	assert.Equal(t, calls.StateRinging, res2.State)
}

func TestRingRetransmit_RepeatsWhileRinging(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	m.RingRetransmitInterval = 20 * time.Millisecond
	calleeOut := registerPeer(t, hub, calleeID)

	_, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err)

	// Initial fan-out + at least two retransmissions.
	for i := 0; i < 3; i++ {
		select {
		case body := <-calleeOut:
			assert.Contains(t, string(body), `"type":"incoming_call"`)
		case <-time.After(2 * time.Second):
			t.Fatalf("expected incoming_call #%d (retransmit) within 2s", i+1)
		}
	}
}

func TestRelaySignal_QueuedForOfflinePeer_FlushedOnRegister(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	// Production wiring: replay queued signals on WS register.
	hub.OnRegister = m.OnWSRegister

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)

	// Callee offline — the offer must queue, not vanish.
	err = m.RelaySignal(context.Background(), res.CallID, callerID, "", map[string]any{
		"kind": "offer", "sdp": "v=0 queued-offer",
	})
	require.NoError(t, err)

	// Callee's WS registers → OnWSRegister replays the active ring
	// FIRST (so the client establishes call context), then the queued
	// signal. A client receiving the offer before the ring would drop
	// or mis-route it.
	calleeOut := registerPeer(t, hub, calleeID)
	var order []string
	for i := 0; i < 4; i++ {
		select {
		case body := <-calleeOut:
			s := string(body)
			switch {
			case strings.Contains(s, `"type":"incoming_call"`):
				order = append(order, "ring")
			case strings.Contains(s, `"type":"call_signal"`):
				require.Contains(t, s, "queued-offer")
				order = append(order, "signal")
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("expected ring + replayed signal, got %v", order)
		}
		if len(order) >= 2 {
			break
		}
	}
	require.GreaterOrEqual(t, len(order), 2)
	assert.Equal(t, "ring", order[0], "incoming_call must replay before the queued signal")
	assert.Equal(t, "signal", order[len(order)-1])
}

func TestRelaySignal_QueuePurgedOnTerminalState(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	hub.OnRegister = m.OnWSRegister

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err)
	require.NoError(t, m.RelaySignal(context.Background(), res.CallID, callerID, "", map[string]any{
		"kind": "offer", "sdp": "v=0 stale",
	}))
	_, err = m.Cancel(context.Background(), calls.CancelRequest{
		CallID: res.CallID, SessionUserID: callerID,
	})
	require.NoError(t, err)

	// Register AFTER cancel — the stale offer must not be replayed.
	// (State snapshots MAY replay — that's the reconnect-reconciliation
	// path — but no call_signal frames for a terminal call.)
	calleeOut := registerPeer(t, hub, calleeID)
	deadline := time.After(200 * time.Millisecond)
	for {
		select {
		case body := <-calleeOut:
			assert.NotContains(t, string(body), `"type":"call_signal"`,
				"terminal call's signals must be purged")
		case <-deadline:
			return
		}
	}
}

func TestOnWSRegister_ReplaysTerminalSnapshot_ForStuckPeer(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	hub.OnRegister = m.OnWSRegister

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err)
	_, err = m.Accept(context.Background(), calls.AcceptRequest{
		CallID: res.CallID, SessionUserID: calleeID,
	})
	require.NoError(t, err)
	// Caller goes offline; callee ends the call — the caller misses the
	// best-effort terminal event.
	_, err = m.End(context.Background(), calls.EndRequest{
		CallID: res.CallID, SessionUserID: calleeID,
	})
	require.NoError(t, err)

	// Caller reconnects → must receive a (stale) ended snapshot so its
	// UI exits the stuck active state.
	callerOut := registerPeer(t, hub, callerID)
	select {
	case body := <-callerOut:
		s := string(body)
		assert.Contains(t, s, `"type":"call_state_changed"`)
		assert.Contains(t, s, `"state":"ended"`)
		assert.Contains(t, s, `"stale":true`)
		assert.Contains(t, s, res.CallID)
	case <-time.After(2 * time.Second):
		t.Fatal("reconnect did not replay the terminal call state")
	}
}

func TestFlushPendingSignals_RequeuesOnSaturatedChannel(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err)
	require.NoError(t, m.RelaySignal(context.Background(), res.CallID, callerID, "", map[string]any{
		"kind": "offer", "sdp": "v=0 survive-saturation",
	}))

	// Register the callee with a ZERO-capacity outbound channel and
	// never drain it: every enqueue fails. The flush must requeue the
	// signal, not drop it.
	blocked := make(chan []byte)
	hub.Register(&ws.Session{UserID: calleeID, DeviceID: calleeID + "-dev", Out: blocked})
	m.FlushPendingSignals(calleeID)

	// Re-register with a usable channel: the requeued signal delivers.
	out := make(chan []byte, 8)
	hub.Register(&ws.Session{UserID: calleeID, DeviceID: calleeID + "-dev2", Out: out})
	m.FlushPendingSignals(calleeID)
	select {
	case body := <-out:
		assert.Contains(t, string(body), "survive-saturation")
	case <-time.After(2 * time.Second):
		t.Fatal("requeued signal was lost after a failed flush")
	}
}

func TestOnWSRegister_QueuedOfferSurvivesManyRecentCalls(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	hub.OnRegister = m.OnWSRegister

	// Churn 70 recent terminal calls for the callee — more than the
	// 64-slot outbound channel and the bounded terminal replay.
	for i := 0; i < 70; i++ {
		clock.T += 1000
		res, err := m.Create(context.Background(), calls.CreateRequest{
			CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
		})
		require.NoError(t, err)
		_, err = m.Cancel(context.Background(), calls.CancelRequest{
			CallID: res.CallID, SessionUserID: callerID,
		})
		require.NoError(t, err)
	}

	// A live call with a queued offer for the callee.
	clock.T += 1000
	live, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)
	require.NoError(t, m.RelaySignal(context.Background(), live.CallID, callerID, "", map[string]any{
		"kind": "offer", "sdp": "v=0 must-survive",
	}))

	// Callee registers with a generous buffer; the offer MUST arrive
	// despite the flood of terminal history.
	out := make(chan []byte, 256)
	hub.Register(&ws.Session{UserID: calleeID, DeviceID: calleeID + "-dev", Out: out})

	deadline := time.After(2 * time.Second)
	gotOffer := false
	for !gotOffer {
		select {
		case body := <-out:
			if strings.Contains(string(body), "must-survive") {
				gotOffer = true
			}
		case <-deadline:
			t.Fatal("queued offer was starved by terminal-history replay")
		}
	}
}

func TestMissedSweep_KeepsHealthyConnectedCall(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	// Both peers are live on the hub (buffered so fan-out never blocks).
	registerPeerBuffered(t, hub, callerID)
	registerPeerBuffered(t, hub, calleeID)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err)
	_, err = m.Accept(context.Background(), calls.AcceptRequest{CallID: res.CallID, SessionUserID: calleeID})
	require.NoError(t, err)

	// Advance well past the 4h stale threshold.
	clock.T += int64(5 * time.Hour / time.Millisecond)
	_, err = m.RunMissedSweepCount(context.Background())
	require.NoError(t, err)

	// A HEALTHY long call (both peers connected) must survive.
	var state string
	require.NoError(t, db.QueryRowContext(context.Background(),
		`SELECT state FROM calls WHERE id = ?`, res.CallID).Scan(&state))
	assert.Equal(t, "connected", state, "healthy 4h+ call must not be killed")
}

func TestMissedSweep_EndsAbandonedConnectedCall(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	// Connect then DISCONNECT both peers (clients vanished). Use buffered
	// channels so the manager's best-effort fan-out never blocks.
	registerPeerBuffered(t, hub, callerID)
	registerPeerBuffered(t, hub, calleeID)
	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err)
	_, err = m.Accept(context.Background(), calls.AcceptRequest{CallID: res.CallID, SessionUserID: calleeID})
	require.NoError(t, err)
	hub.DisconnectUser(callerID)
	hub.DisconnectUser(calleeID)

	clock.T += int64(5 * time.Hour / time.Millisecond)
	// A single instantaneous double-absence only STARTS the grace clock — it
	// must not end the call (could be a transient mid-reconnect blip).
	_, err = m.RunMissedSweepCount(context.Background())
	require.NoError(t, err)
	var midState string
	require.NoError(t, db.QueryRowContext(context.Background(),
		`SELECT state FROM calls WHERE id = ?`, res.CallID).Scan(&midState))
	require.Equal(t, "connected", midState, "one instantaneous absence must not end the call")

	// Both stay absent past the grace window → the next sweep ends it.
	clock.T += connectedCallAbsenceGraceTestMs
	_, err = m.RunMissedSweepCount(context.Background())
	require.NoError(t, err)

	var state string
	require.NoError(t, db.QueryRowContext(context.Background(),
		`SELECT state FROM calls WHERE id = ?`, res.CallID).Scan(&state))
	assert.Equal(t, "ended", state, "abandoned 4h+ call (both peers gone past grace) must be swept")
}

// connectedCallAbsenceGraceTestMs is a clock advance comfortably past the
// production grace window so a second sweep sees sustained absence.
const connectedCallAbsenceGraceTestMs = int64(3 * time.Minute / time.Millisecond)

// TestMissedSweep_KeepsCallThroughTransientReconnect guards the round-59 fix:
// a >4h connected call whose BOTH peers briefly drop (server restart, network
// handoff, app background) and then reconnect must NOT be force-hung by the
// periodic sweep's instantaneous liveness check.
func TestMissedSweep_KeepsCallThroughTransientReconnect(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	db := newTestDB(t, clock)
	seedUsers(t, db, callerID, calleeID)
	hub := ws.NewHub()
	m := newManager(t, db, hub)
	registerPeerBuffered(t, hub, callerID)
	registerPeerBuffered(t, hub, calleeID)

	res, err := m.Create(context.Background(), calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindAudio,
	})
	require.NoError(t, err)
	_, err = m.Accept(context.Background(), calls.AcceptRequest{CallID: res.CallID, SessionUserID: calleeID})
	require.NoError(t, err)

	clock.T += int64(5 * time.Hour / time.Millisecond)

	// Both peers briefly drop — the sweep starts the grace but must not end it.
	hub.DisconnectUser(callerID)
	hub.DisconnectUser(calleeID)
	_, err = m.RunMissedSweepCount(context.Background())
	require.NoError(t, err)

	// They reconnect shortly after (within the grace window).
	clock.T += int64(30 * time.Second / time.Millisecond)
	registerPeerBuffered(t, hub, callerID)
	registerPeerBuffered(t, hub, calleeID)

	// Even well past the original grace window, the reconnected call survives
	// — the grace was reset the moment a peer reappeared.
	clock.T += connectedCallAbsenceGraceTestMs
	_, err = m.RunMissedSweepCount(context.Background())
	require.NoError(t, err)

	var state string
	require.NoError(t, db.QueryRowContext(context.Background(),
		`SELECT state FROM calls WHERE id = ?`, res.CallID).Scan(&state))
	assert.Equal(t, "connected", state, "a call whose peers briefly reconnected must survive the sweep")
}

// registerPeerBuffered attaches a live session with a generous buffer so
// the manager's best-effort fan-out (incoming_call, state changes) never
// blocks the test even when nobody drains it.
func registerPeerBuffered(t *testing.T, hub *ws.Hub, userID string) chan []byte {
	t.Helper()
	out := make(chan []byte, 32)
	hub.Register(&ws.Session{UserID: userID, DeviceID: userID + "-dev", Out: out})
	return out
}
