// Package trace carries a per-request correlation id (W3C traceparent
// trace-id) through context so every log line for one request can be tied
// together — and to the client that originated it. Metadata only; no message
// content ever flows through here.
package trace

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log"
	"strings"
)

type ctxKey struct{}

// debug gates Logf so release deployments stay quiet; set from NESTTALK_DEBUG.
var debug bool

// SetDebug toggles trace logging (call once at startup).
func SetDebug(on bool) { debug = on }

// New mints a fresh 16-byte (32 hex) W3C trace-id.
func New() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// FromTraceparent extracts the trace-id from a W3C `traceparent` header value
// (`version-traceid-spanid-flags`). Returns ("", false) when absent,
// malformed, non-hex, or the all-zero (invalid) trace-id.
func FromTraceparent(header string) (string, bool) {
	// Reject oversized headers BEFORE splitting — withTrace runs before auth
	// on every route, so an unauthenticated client must not be able to force a
	// large allocation with a giant garbage value. A valid v00 traceparent is
	// 55 chars; cap generously for future versions.
	if len(header) > 128 {
		return "", false
	}
	parts := strings.Split(strings.TrimSpace(header), "-")
	if len(parts) != 4 {
		return "", false
	}
	id := parts[1]
	if len(id) != 32 || strings.Trim(id, "0") == "" {
		return "", false
	}
	if _, err := hex.DecodeString(id); err != nil {
		return "", false
	}
	return id, true
}

// WithID stores the trace-id in the context.
func WithID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, ctxKey{}, id)
}

// ID returns the context's trace-id, or "" if unset.
func ID(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKey{}).(string); ok {
		return v
	}
	return ""
}

// Logf logs a trace-tagged line when debug logging is enabled.
func Logf(ctx context.Context, format string, args ...any) {
	if !debug {
		return
	}
	id := ID(ctx)
	if id == "" {
		id = "-"
	}
	log.Printf("[trace=%s] "+format, append([]any{id}, args...)...)
}
