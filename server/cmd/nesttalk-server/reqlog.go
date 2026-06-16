package main

import (
	"bufio"
	"fmt"
	"log"
	"net"
	"net/http"
	"time"

	"github.com/seb0ch/nesttalk/server/internal/trace"
)

// withTrace assigns every request a correlation trace-id — taken from the
// client's W3C `traceparent` header, or minted when absent — and threads it
// through the request context so handlers/packages can tag their logs via
// trace.Logf. The id is echoed in the `X-NT-Trace-Id` response header so the
// client can correlate its own log line with the server's.
//
// When logRequests is set (NESTTALK_DEBUG), it also logs one line per request:
// `[req] trace=<id> METHOD PATH -> STATUS (dur)`. Metadata ONLY — bodies are
// never read or logged, so message ciphertext/content never appears.
func withTrace(next http.Handler, logRequests bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, ok := trace.FromTraceparent(r.Header.Get("traceparent"))
		if !ok {
			id = trace.New()
		}
		w.Header().Set("X-NT-Trace-Id", id)
		r = r.WithContext(trace.WithID(r.Context(), id))

		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		if logRequests {
			log.Printf("[req] trace=%s %s %s -> %d (%s)", id, r.Method, r.URL.Path, rec.status, time.Since(start).Round(time.Millisecond))
		}
	})
}

// statusRecorder captures the response status while delegating the optional
// ResponseWriter interfaces — Hijacker (the /api/v1/ws/control WebSocket
// upgrade) and Flusher (streaming) — so wrapping the mux never breaks the
// control socket. Unwrap() also lets http.ResponseController reach the
// underlying writer on Go 1.20+.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func (s *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if hj, ok := s.ResponseWriter.(http.Hijacker); ok {
		return hj.Hijack()
	}
	return nil, nil, fmt.Errorf("nesttalk: underlying ResponseWriter does not support Hijack")
}

func (s *statusRecorder) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
