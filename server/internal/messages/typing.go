package messages

import (
	"sync"
	"time"

	"github.com/seb0ch/nesttalk/server/internal/ws"
)

const (
	// typingCoalesceMs is the minimum gap between outbound typing_start broadcasts.
	typingCoalesceMs = 3000
	// typingStopDelayMs is how long after the last typing_start the server
	// broadcasts typing_stop (no further start arrived).
	typingStopDelayMs = 5000
	// typingRateLimitPerMin is the hard cap on typing events per sender per minute.
	typingRateLimitPerMin = 10
)

type typingState struct {
	lastEmitMs  int64
	stopTimer   *time.Timer // non-nil when using real time.AfterFunc
	stopFiresAt int64       // non-zero when using scheduled-stop list (test mode)
}

// perSenderState holds rate-limit counters for one sender.
type perSenderState struct {
	windowStart int64
	count       int
	recipients  map[string]*typingState
}

// scheduledStop is an entry in the test-mode stop list.
type scheduledStop struct {
	firesAt      int64
	senderUID    string
	recipientUID string
}

// TypingTracker manages per-(sender,recipient) coalescing, implicit stop
// timers, and per-sender rate limits.
//
// Clock injection: the tracker accepts a clock function so unit tests can
// control time without sleeping.
//
// Stop-timer strategy: in production the tracker uses real time.AfterFunc.
// When testStops is non-nil (set by tests via FlushScheduledStops calls),
// stops are recorded in a list and fired synchronously by FlushScheduledStops
// instead of using real timers — this avoids test sleeps entirely.
type TypingTracker struct {
	mu         sync.Mutex
	senders    map[string]*perSenderState
	hub        *ws.Hub
	clock      func() int64
	testStops  []scheduledStop // non-nil → test mode (no time.AfterFunc)
	useTestMode bool
}

// NewTypingTracker constructs a tracker backed by the given hub.
// clock may be nil, in which case time.Now().UnixMilli() is used.
func NewTypingTracker(hub *ws.Hub, clock func() int64) *TypingTracker {
	if clock == nil {
		clock = func() int64 { return time.Now().UnixMilli() }
	}
	return &TypingTracker{
		senders: make(map[string]*perSenderState),
		hub:     hub,
		clock:   clock,
	}
}

// NewTypingTrackerTestable constructs a tracker in test mode: implicit stop
// timers are recorded in an internal list instead of using time.AfterFunc.
// Call FlushScheduledStops(asOfMillis) to fire them synchronously.
func NewTypingTrackerTestable(hub *ws.Hub, clock func() int64) *TypingTracker {
	if clock == nil {
		clock = func() int64 { return time.Now().UnixMilli() }
	}
	return &TypingTracker{
		senders:     make(map[string]*perSenderState),
		hub:         hub,
		clock:       clock,
		testStops:   []scheduledStop{},
		useTestMode: true,
	}
}

// FlushScheduledStops fires all implicit stop timers whose fire time ≤ asOfMillis.
// Only effective in test mode (created via NewTypingTrackerTestable).
func (t *TypingTracker) FlushScheduledStops(asOfMillis int64) {
	t.mu.Lock()
	var remaining []scheduledStop
	var toFire []scheduledStop
	for _, s := range t.testStops {
		if s.firesAt <= asOfMillis {
			toFire = append(toFire, s)
		} else {
			remaining = append(remaining, s)
		}
	}
	t.testStops = remaining
	t.mu.Unlock()

	for _, s := range toFire {
		t.hub.SendToUser(s.recipientUID, ws.TypingStop(s.senderUID, s.recipientUID, asOfMillis))
	}
}

// HandleTypingStart processes an inbound typing_start from senderUID to recipientUID.
// Coalescing: at most one outbound event per 3 seconds per (sender, recipient).
// Rate limit: > 10 events/min per sender → silently drop.
func (t *TypingTracker) HandleTypingStart(senderUID, recipientUID string) {
	now := t.clock()

	t.mu.Lock()
	sender, ok := t.senders[senderUID]
	if !ok {
		sender = &perSenderState{
			windowStart: now,
			recipients:  make(map[string]*typingState),
		}
		t.senders[senderUID] = sender
	}

	// Fixed 60s window (resets when elapsed >= 60_000ms). Trade-off: up to 2×
	// spec cap straddling boundary; spec doesn't mandate sliding window so we
	// accept the simpler counter.
	if now-sender.windowStart >= 60_000 {
		sender.windowStart = now
		sender.count = 0
	}

	// Rate limit.
	if sender.count >= typingRateLimitPerMin {
		t.mu.Unlock()
		return
	}

	state, ok := sender.recipients[recipientUID]
	if !ok {
		state = &typingState{}
		sender.recipients[recipientUID] = state
	}

	// Coalesce: skip if we emitted within the last 3 seconds.
	if now-state.lastEmitMs < typingCoalesceMs {
		// Still within coalesce window — reschedule the stop deadline.
		if t.useTestMode {
			t.rescheduleTestStop(senderUID, recipientUID, now+typingStopDelayMs)
		} else if state.stopTimer != nil {
			state.stopTimer.Reset(typingStopDelayMs * time.Millisecond)
		}
		t.mu.Unlock()
		return
	}

	state.lastEmitMs = now
	sender.count++

	if t.useTestMode {
		// Remove any existing stop entry for this pair, then add a new one.
		t.rescheduleTestStop(senderUID, recipientUID, now+typingStopDelayMs)
		state.stopFiresAt = now + typingStopDelayMs
	} else {
		// Cancel existing stop timer.
		if state.stopTimer != nil {
			state.stopTimer.Stop()
		}
		// Schedule implicit stop.
		snd := senderUID
		rcpt := recipientUID
		hub := t.hub
		clk := t.clock
		state.stopTimer = time.AfterFunc(typingStopDelayMs*time.Millisecond, func() {
			hub.SendToUser(rcpt, ws.TypingStop(snd, rcpt, clk()))
		})
	}
	t.mu.Unlock()

	t.hub.SendToUser(recipientUID, ws.TypingStart(senderUID, recipientUID, now))
}

// rescheduleTestStop replaces any existing scheduled stop for (senderUID,recipientUID)
// with a new one firing at firesAt. Must be called with t.mu held.
func (t *TypingTracker) rescheduleTestStop(senderUID, recipientUID string, firesAt int64) {
	updated := t.testStops[:0]
	for _, s := range t.testStops {
		if s.senderUID == senderUID && s.recipientUID == recipientUID {
			continue // drop old entry
		}
		updated = append(updated, s)
	}
	t.testStops = append(updated, scheduledStop{
		firesAt:      firesAt,
		senderUID:    senderUID,
		recipientUID: recipientUID,
	})
}

// OnSessionClose is called when a WS session is closed. It immediately
// broadcasts typing_stop to every recipient that received a typing_start
// from this sender within the last minute, and clears all timers.
func (t *TypingTracker) OnSessionClose(senderUID string) {
	now := t.clock()

	t.mu.Lock()
	sender, ok := t.senders[senderUID]
	if !ok {
		t.mu.Unlock()
		return
	}
	// Collect recipients that are still within the emit window.
	var toNotify []string
	for rcpt, state := range sender.recipients {
		if t.useTestMode {
			// Remove any pending test-mode stop for this pair.
			var remaining []scheduledStop
			for _, s := range t.testStops {
				if s.senderUID == senderUID && s.recipientUID == rcpt {
					continue
				}
				remaining = append(remaining, s)
			}
			t.testStops = remaining
		} else if state.stopTimer != nil {
			state.stopTimer.Stop()
			state.stopTimer = nil
		}
		if now-state.lastEmitMs < 60_000 {
			toNotify = append(toNotify, rcpt)
		}
	}
	delete(t.senders, senderUID)
	t.mu.Unlock()

	for _, rcpt := range toNotify {
		t.hub.SendToUser(rcpt, ws.TypingStop(senderUID, rcpt, now))
	}
}
