package main

import (
	"bufio"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/trace"
)

func TestWithTrace_MintsWhenNoHeader(t *testing.T) {
	var ctxID string
	// logRequests=true so the request-log branch is exercised too.
	h := withTrace(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctxID = trace.ID(r.Context())
		w.WriteHeader(http.StatusTeapot)
	}), true)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/x", nil))

	assert.Equal(t, http.StatusTeapot, rec.Code)
	minted := rec.Header().Get("X-NT-Trace-Id")
	assert.NotEmpty(t, minted)
	assert.Equal(t, minted, ctxID, "context id must match the echoed header")
}

func TestWithTrace_PropagatesTraceparent(t *testing.T) {
	h := withTrace(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}), false)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
	h.ServeHTTP(rec, req)

	assert.Equal(t, "0af7651916cd43dd8448eb211c80319c", rec.Header().Get("X-NT-Trace-Id"))
}

// hijackFlushRW supports both optional interfaces so the success branches of
// statusRecorder.Hijack/Flush are covered.
type hijackFlushRW struct {
	http.ResponseWriter
	flushed  bool
	hijacked bool
}

func (f *hijackFlushRW) Flush() { f.flushed = true }
func (f *hijackFlushRW) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	f.hijacked = true
	return nil, nil, nil
}

// bareRW implements only http.ResponseWriter (no Flusher/Hijacker), so the
// fallback branches of statusRecorder.Hijack/Flush are covered.
type bareRW struct{ hdr http.Header }

func (b *bareRW) Header() http.Header {
	if b.hdr == nil {
		b.hdr = http.Header{}
	}
	return b.hdr
}
func (b *bareRW) Write(p []byte) (int, error) { return len(p), nil }
func (b *bareRW) WriteHeader(int)             {}

func TestStatusRecorder_DelegatesOptionalInterfaces(t *testing.T) {
	base := &hijackFlushRW{ResponseWriter: httptest.NewRecorder()}
	rec := &statusRecorder{ResponseWriter: base, status: http.StatusOK}

	rec.WriteHeader(http.StatusCreated)
	assert.Equal(t, http.StatusCreated, rec.status)
	assert.Equal(t, base, rec.Unwrap())

	rec.Flush()
	assert.True(t, base.flushed)

	_, _, err := rec.Hijack()
	require.NoError(t, err)
	assert.True(t, base.hijacked)
}

func TestStatusRecorder_FallbackWhenUnsupported(t *testing.T) {
	rec := &statusRecorder{ResponseWriter: &bareRW{}, status: http.StatusOK}

	rec.Flush() // no-op; covers the !Flusher branch

	_, _, err := rec.Hijack()
	assert.Error(t, err, "Hijack must error when the underlying writer is not a Hijacker")
}
