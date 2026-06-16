package calls

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/storage"
	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// TestClassifySignalCall_TriState covers the round-45 finding: a transient DB
// error must NOT be collapsed into "drop". Only a confirmed no-row,
// non-participant, or terminal state may drop a salvaged/queued call_signal; a
// transient lookup failure (e.g. a closed handle during restore/vacuum) returns
// Unknown so a still-live call's already-acked SDP/ICE is kept, not lost.
//
// Internal test (package calls) so it can assert the unexported tri-state.
func TestClassifySignalCall_TriState(t *testing.T) {
	clock := &storage.FixedClock{T: 1_700_000_000_000}
	dir := t.TempDir()
	db, err := storage.OpenWithClock(filepath.Join(dir, "classify.db"), clock)
	require.NoError(t, err)
	defer func() { _ = db.Close() }()
	ctx := context.Background()

	for _, u := range []string{"caller", "callee", "third"} {
		_, err := db.ExecContext(ctx,
			`INSERT INTO users (id, display_name, color_hint, enrolled_at) VALUES (?, ?, 0, 1)`, u, u)
		require.NoError(t, err)
	}
	_, err = db.ExecContext(ctx,
		`INSERT INTO calls (id, caller_user_id, callee_user_id, kind, state, started_at)
		 VALUES ('call1', 'caller', 'callee', 'video', 'ringing', 1)`)
	require.NoError(t, err)

	m := New(db, ws.NewHub())

	// Ringing call, participant → active.
	assert.Equal(t, signalCallActive, m.classifySignalCall("call1", "callee"))
	// Existing call, NON-participant → terminal (never deliver).
	assert.Equal(t, signalCallTerminal, m.classifySignalCall("call1", "third"))
	// Unknown call id (no row) → terminal.
	assert.Equal(t, signalCallTerminal, m.classifySignalCall("nope", "callee"))

	// Terminal state → terminal.
	_, err = db.ExecContext(ctx, `UPDATE calls SET state = 'ended', ended_at = ? WHERE id = 'call1'`, clock.T)
	require.NoError(t, err)
	assert.Equal(t, signalCallTerminal, m.classifySignalCall("call1", "callee"))

	// Transient DB failure (closed handle) → UNKNOWN, never terminal.
	require.NoError(t, db.Close())
	assert.Equal(t, signalCallUnknown, m.classifySignalCall("call1", "callee"))
}
