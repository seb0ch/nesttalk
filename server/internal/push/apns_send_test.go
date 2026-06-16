package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// testJWTCache builds a JWTCache backed by a freshly generated P-256 key so
// Get() can actually sign an ES256 token.
func testJWTCache(t *testing.T) *JWTCache {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	der, err := x509.MarshalPKCS8PrivateKey(key)
	require.NoError(t, err)
	pemBytes := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	cache, err := NewJWTCache(pemBytes, "ABCDE12345", "Q2GZ8F5NV5")
	require.NoError(t, err)
	return cache
}

// clientTo wires a Client at the given TLS test server, trusting its cert.
func clientTo(t *testing.T, ts *httptest.Server) *Client {
	t.Helper()
	return &Client{
		httpClient: ts.Client(),
		jwt:        testJWTCache(t),
		host:       strings.TrimPrefix(ts.URL, "https://"),
		topic:      "com.nesttalk.ios.voip",
	}
}

func TestSend_Success(t *testing.T) {
	ts := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// The required APNs headers must all be present.
		assert.Equal(t, "voip", r.Header.Get("apns-push-type"))
		assert.Equal(t, "com.nesttalk.ios.voip", r.Header.Get("apns-topic"))
		assert.True(t, strings.HasPrefix(r.Header.Get("authorization"), "bearer "))
		w.Header().Set("apns-id", "apns-xyz")
		w.WriteHeader(http.StatusOK)
	}))
	defer ts.Close()

	c := clientTo(t, ts)
	res, err := c.Send(context.Background(), "devtoken", NewVoIPPayload("call-1", "u1", "Alice", "audio"))
	require.NoError(t, err)
	assert.Equal(t, http.StatusOK, res.StatusCode)
	assert.Equal(t, "apns-xyz", res.APNSID)
}

func TestSend_RefreshesAndRetriesOn403(t *testing.T) {
	var calls atomic.Int32
	ts := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 1 {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"reason":"ExpiredProviderToken"}`))
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer ts.Close()

	c := clientTo(t, ts)
	res, err := c.Send(context.Background(), "devtoken", NewVoIPPayload("call-2", "u1", "Alice", "video"))
	require.NoError(t, err)
	assert.Equal(t, http.StatusOK, res.StatusCode)
	assert.Equal(t, int32(2), calls.Load(), "must retry exactly once after a refresh")
}

func TestSend_NoRetryOnOther403(t *testing.T) {
	var calls atomic.Int32
	ts := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"reason":"TopicDisallowed"}`))
	}))
	defer ts.Close()

	c := clientTo(t, ts)
	res, err := c.Send(context.Background(), "devtoken", NewVoIPPayload("call-3", "u1", "Alice", "audio"))
	require.NoError(t, err)
	assert.Equal(t, http.StatusForbidden, res.StatusCode)
	assert.Equal(t, "TopicDisallowed", res.Reason)
	assert.Equal(t, int32(1), calls.Load(), "a non-token 403 must not retry")
}

func TestNewClient(t *testing.T) {
	_, err := NewClient(nil, APNSDevHost, "topic")
	require.Error(t, err)

	c, err := NewClient(testJWTCache(t), APNSProdHost, "com.nesttalk.ios.voip")
	require.NoError(t, err)
	assert.Equal(t, APNSProdHost, c.host)
}
