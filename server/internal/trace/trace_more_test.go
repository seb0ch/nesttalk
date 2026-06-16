package trace

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestSetDebugAndLogf(t *testing.T) {
	t.Cleanup(func() { SetDebug(false) })

	// Disabled: Logf is a no-op and must not panic.
	SetDebug(false)
	Logf(context.Background(), "should not log %d", 1)

	// Enabled: both the with-id and empty-id branches run.
	SetDebug(true)
	Logf(WithID(context.Background(), "trace-123"), "hello %s", "world")
	Logf(context.Background(), "no id %d", 2) // id == "" → "-"
}

func TestIDRoundTrip(t *testing.T) {
	assert.Empty(t, ID(context.Background()))
	ctx := WithID(context.Background(), "abc")
	assert.Equal(t, "abc", ID(ctx))
}

func TestNewMintsDistinctHexIDs(t *testing.T) {
	a, b := New(), New()
	assert.Len(t, a, 32)
	assert.NotEqual(t, a, b)
}
