package trace

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestFromTraceparent(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
		ok   bool
	}{
		{"valid", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "4bf92f3577b34da6a3ce929d0e0e4736", true},
		{"trimmed", "  00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01 ", "4bf92f3577b34da6a3ce929d0e0e4736", true},
		{"empty", "", "", false},
		{"garbage", "garbage", "", false},
		{"all-zero traceid", "00-00000000000000000000000000000000-00f067aa0ba902b7-01", "", false},
		{"short traceid", "00-4bf92f-00f067aa0ba902b7-01", "", false},
		{"non-hex traceid", "00-4bf92f3577b34da6a3ce929d0e0e473g-00f067aa0ba902b7-01", "", false},
		{"too few parts", "00-4bf92f3577b34da6a3ce929d0e0e4736-01", "", false},
		{"oversized garbage", "00-" + strings.Repeat("-", 100000), "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := FromTraceparent(c.in)
			assert.Equal(t, c.ok, ok)
			assert.Equal(t, c.want, got)
		})
	}
}

func TestNewIsParseableTraceID(t *testing.T) {
	id := New()
	require.Len(t, id, 32)
	got, ok := FromTraceparent("00-" + id + "-0000000000000001-01")
	assert.True(t, ok)
	assert.Equal(t, id, got)
}

func TestIDContextRoundTrip(t *testing.T) {
	ctx := WithID(context.Background(), "abc123")
	assert.Equal(t, "abc123", ID(ctx))
	assert.Equal(t, "", ID(context.Background()))
}
