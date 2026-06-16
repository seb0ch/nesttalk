package storage

import "time"

// Clock returns the current time in unix milliseconds.
// Injected so tests can pin time for deterministic expiry behavior.
type Clock interface {
	NowMillis() int64
}

// SystemClock returns wall-clock time in unix milliseconds.
type SystemClock struct{}

func (SystemClock) NowMillis() int64 { return time.Now().UnixMilli() }

// FixedClock returns a constant for deterministic tests.
type FixedClock struct{ T int64 }

func (f *FixedClock) NowMillis() int64 { return f.T }
