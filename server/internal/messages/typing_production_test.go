package messages_test

import (
	"testing"

	"github.com/seb0ch/nesttalk/server/internal/messages"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// TestTypingTracker_ProductionMode drives the real-timer (time.AfterFunc) code
// path of NewTypingTracker — the test-mode constructor is exercised elsewhere,
// leaving the production branches of HandleTypingStart/OnSessionClose uncovered.
// A controllable clock lets us hit coalesce, re-emit, and rate-limit branches
// without sleeping; the scheduled stop timers fire harmlessly against a hub
// with no registered sessions.
func TestTypingTracker_ProductionMode(t *testing.T) {
	var nowMs int64 = 1_000_000
	clock := func() int64 { return nowMs }
	hub := ws.NewHub()
	tr := messages.NewTypingTracker(hub, clock)

	// First start: emit + schedule a stop timer.
	tr.HandleTypingStart("sender", "recipient")
	// Same instant: within the 3s coalesce window → reschedule, no emit.
	tr.HandleTypingStart("sender", "recipient")

	// Advance past the coalesce window repeatedly to drive the rate limiter
	// (count increments only on a real emit); the 11th emit is dropped.
	for i := 0; i < 15; i++ {
		nowMs += 3001
		tr.HandleTypingStart("sender", "recipient")
	}

	// Session close broadcasts typing_stop and clears the production timers.
	tr.OnSessionClose("sender")
	// Closing an unknown sender is a no-op.
	tr.OnSessionClose("never-typed")
}

// TestNewTypingTracker_NilClock covers the nil-clock default branch.
func TestNewTypingTracker_NilClock(t *testing.T) {
	tr := messages.NewTypingTracker(ws.NewHub(), nil)
	tr.HandleTypingStart("a", "b") // must not panic with the default clock
}
