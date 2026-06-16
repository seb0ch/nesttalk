package messages_test

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/messages"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// testUID returns a deterministic UUID string for a small integer n.
func testUID(n int) string {
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", n, 0, 0, 0, n)
}

// newSession creates and registers a session on hub, returning it.
func newSession(hub *ws.Hub, uid, did string) *ws.Session {
	sess := &ws.Session{UserID: uid, DeviceID: did, Out: make(chan []byte, 32)}
	hub.Register(sess)
	return sess
}

// drainTyping reads all buffered events from sess.Out and returns them as
// flat JSON maps.
func drainTyping(t *testing.T, sess *ws.Session) []map[string]any {
	t.Helper()
	var out []map[string]any
	for {
		select {
		case body, ok := <-sess.Out:
			if !ok {
				return out
			}
			var ev map[string]any
			require.NoError(t, json.Unmarshal(body, &ev))
			out = append(out, ev)
		default:
			return out
		}
	}
}

func countType(evs []map[string]any, typ string) int {
	n := 0
	for _, ev := range evs {
		if ev["type"] == typ {
			n++
		}
	}
	return n
}

// ----- C2 tests -----

// TestTypingTracker_CoalescesStartWithin3Seconds: 5 rapid-fire starts within
// 3 seconds must emit exactly 1 outbound typing_start to the recipient.
func TestTypingTracker_CoalescesStartWithin3Seconds(t *testing.T) {
	clk := &advanceClock{t: 1_000_000}
	hub := ws.NewHub()

	const sender = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	rcptUID := testUID(1)
	rcptDID := testUID(101)
	rSess := newSession(hub, rcptUID, rcptDID)

	tracker := messages.NewTypingTrackerTestable(hub, clk.NowMillis)

	// 5 calls spaced 300ms apart → 1200ms total, well under the 3000ms coalesce window.
	for i := 0; i < 5; i++ {
		tracker.HandleTypingStart(sender, rcptUID)
		clk.t += 300
	}

	evs := drainTyping(t, rSess)
	assert.Equal(t, 1, countType(evs, "typing_start"),
		"5 rapid-fire starts within 3s must produce exactly 1 typing_start")
}

// TestTypingTracker_EmitsImplicitStopAfter5Seconds: after one start, advancing
// the injected clock past 5s and calling FlushScheduledStops must emit
// exactly one typing_stop to the recipient.
func TestTypingTracker_EmitsImplicitStopAfter5Seconds(t *testing.T) {
	clk := &advanceClock{t: 1_000_000}
	hub := ws.NewHub()

	const sender = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	rcptUID := testUID(1)
	rcptDID := testUID(101)
	rSess := newSession(hub, rcptUID, rcptDID)

	tracker := messages.NewTypingTrackerTestable(hub, clk.NowMillis)
	tracker.HandleTypingStart(sender, rcptUID)

	// Drain the typing_start so we have a clean slate.
	startEvs := drainTyping(t, rSess)
	require.Equal(t, 1, countType(startEvs, "typing_start"))

	// Advance past 5000ms stop delay + 1ms, then flush.
	clk.t += 5001
	tracker.FlushScheduledStops(clk.t)

	evs := drainTyping(t, rSess)
	assert.Equal(t, 1, countType(evs, "typing_stop"),
		"implicit typing_stop must fire after 5s+1ms")

	for _, ev := range evs {
		if ev["type"] == "typing_stop" {
			assert.Equal(t, sender, ev["from"])
			assert.Equal(t, rcptUID, ev["to"])
		}
	}
}

// TestTypingTracker_RateLimit10PerMinute: 12 starts to 12 different recipients
// within a clock-frozen window must emit exactly 10 events; the last 2 are
// silently dropped.
func TestTypingTracker_RateLimit10PerMinute(t *testing.T) {
	const sender = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

	clk := &advanceClock{t: 1_000_000}
	hub := ws.NewHub()

	// Pre-create 12 recipient sessions.
	sessions := make([]*ws.Session, 12)
	rcptUIDs := make([]string, 12)
	for i := 0; i < 12; i++ {
		uid := testUID(i + 1)
		did := testUID(i + 100)
		rcptUIDs[i] = uid
		sessions[i] = newSession(hub, uid, did)
	}

	tracker := messages.NewTypingTrackerTestable(hub, clk.NowMillis)

	// Clock is frozen; all 12 events fall within the same rate-limit window.
	for _, rcpt := range rcptUIDs {
		tracker.HandleTypingStart(sender, rcpt)
	}

	totalStarts := 0
	for _, sess := range sessions {
		evs := drainTyping(t, sess)
		totalStarts += countType(evs, "typing_start")
	}
	assert.Equal(t, 10, totalStarts,
		"rate limit must cap at exactly 10 typing_start events per minute; last 2 dropped")
}

// TestTypingTracker_OnSessionCloseBroadcastsStop: after typing_start toward
// two recipients, OnSessionClose must immediately broadcast typing_stop to
// both recipients with the sender's UID.
func TestTypingTracker_OnSessionCloseBroadcastsStop(t *testing.T) {
	const sender = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

	clk := &advanceClock{t: 1_000_000}
	hub := ws.NewHub()

	rcptA := testUID(1)
	rcptB := testUID(2)
	sessA := newSession(hub, rcptA, testUID(101))
	sessB := newSession(hub, rcptB, testUID(102))

	tracker := messages.NewTypingTrackerTestable(hub, clk.NowMillis)
	tracker.HandleTypingStart(sender, rcptA)
	tracker.HandleTypingStart(sender, rcptB)

	// Drain start events so the channels are clean.
	drainTyping(t, sessA)
	drainTyping(t, sessB)

	tracker.OnSessionClose(sender)

	evsA := drainTyping(t, sessA)
	evsB := drainTyping(t, sessB)

	assert.Equal(t, 1, countType(evsA, "typing_stop"),
		"recipientA must receive typing_stop when sender closes")
	assert.Equal(t, 1, countType(evsB, "typing_stop"),
		"recipientB must receive typing_stop when sender closes")

	for _, ev := range append(evsA, evsB...) {
		if ev["type"] == "typing_stop" {
			assert.Equal(t, sender, ev["from"],
				"typing_stop from field must carry the sender UID")
		}
	}
}
