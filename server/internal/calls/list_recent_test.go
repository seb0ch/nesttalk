package calls_test

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/calls"
	"github.com/seb0ch/nesttalk/server/internal/storage"
)

func TestListRecentCalls_WithData(t *testing.T) {
	db := newTestDB(t, &storage.FixedClock{T: 1_700_000_000_000})
	seedUsers(t, db, callerID, calleeID)
	m := newManager(t, db, nil)
	ctx := context.Background()

	// Create + decline so there is a terminal-state row to list.
	created, err := m.Create(ctx, calls.CreateRequest{
		CallerUserID: callerID, CalleeUserID: calleeID, Kind: calls.KindVideo,
	})
	require.NoError(t, err)
	_, err = m.Decline(ctx, calls.DeclineRequest{CallID: created.CallID, SessionUserID: calleeID})
	require.NoError(t, err)

	// First page (BeforeStartedAt == nil).
	rows, err := m.ListRecentCalls(ctx, calls.ListRecentCallsRequest{Limit: 10})
	require.NoError(t, err)
	require.Len(t, rows, 1)
	assert.Equal(t, created.CallID, rows[0].ID)
	assert.Equal(t, calls.KindVideo, rows[0].Kind)

	// Raw form (the map shape served over the admin RPC).
	raw, err := m.ListRecentCallsRaw(ctx, 10, nil)
	require.NoError(t, err)
	require.Len(t, raw, 1)
	assert.Equal(t, created.CallID, raw[0]["id"])

	// Paginated page (BeforeStartedAt set) past the only row → empty.
	before := int64(1)
	rows, err = m.ListRecentCalls(ctx, calls.ListRecentCallsRequest{Limit: 10, BeforeStartedAt: &before})
	require.NoError(t, err)
	assert.Empty(t, rows)
}
