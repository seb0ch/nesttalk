package push

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// generatePEMP8 produces a fresh EC P-256 private key in PEM/PKCS8 form
// — same shape as the .p8 file App Store Connect emits.
func generatePEMP8(t *testing.T) []byte {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	require.NoError(t, err)
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func TestJWTCache_RejectsBadInput(t *testing.T) {
	_, err := NewJWTCache(nil, "ABCDEFGHIJ", "1234567890")
	assert.Error(t, err)

	pemBytes := generatePEMP8(t)
	_, err = NewJWTCache(pemBytes, "tooshort", "1234567890")
	assert.Error(t, err)
	_, err = NewJWTCache(pemBytes, "ABCDEFGHIJ", "tooshort")
	assert.Error(t, err)
	_, err = NewJWTCache([]byte("not pem"), "ABCDEFGHIJ", "1234567890")
	assert.Error(t, err)
}

func TestJWTCache_GetReturnsTokenAndCachesUntilTTL(t *testing.T) {
	c, err := NewJWTCache(generatePEMP8(t), "ABCDEFGHIJ", "1234567890")
	require.NoError(t, err)

	now := time.Date(2026, 4, 29, 12, 0, 0, 0, time.UTC)
	c.SetNow(func() time.Time { return now })

	tok1, err := c.Get()
	require.NoError(t, err)
	assert.NotEmpty(t, tok1)

	// Second call within TTL returns the same bytes (cache hit).
	tok2, err := c.Get()
	require.NoError(t, err)
	assert.Equal(t, tok1, tok2)

	// Advance past the cache window — fresh token.
	c.SetNow(func() time.Time { return now.Add(51 * time.Minute) })
	tok3, err := c.Get()
	require.NoError(t, err)
	assert.NotEqual(t, tok1, tok3)
}

func TestJWTCache_ForceRefreshClearsCache(t *testing.T) {
	c, err := NewJWTCache(generatePEMP8(t), "ABCDEFGHIJ", "1234567890")
	require.NoError(t, err)
	tok1, _ := c.Get()
	c.ForceRefresh()
	tok2, _ := c.Get()
	// New iat → different JWT bytes (unless wall clock didn't tick;
	// retry once if we hit the same second).
	if tok1 == tok2 {
		time.Sleep(time.Second + 10*time.Millisecond)
		tok2, _ = c.Get()
	}
	assert.NotEqual(t, tok1, tok2)
}

func TestJWTCache_SingleflightCoalescesConcurrentRefresh(t *testing.T) {
	c, err := NewJWTCache(generatePEMP8(t), "ABCDEFGHIJ", "1234567890")
	require.NoError(t, err)
	c.ForceRefresh()

	const N = 64
	var wg sync.WaitGroup
	wg.Add(N)
	tokens := make([]string, N)
	for i := 0; i < N; i++ {
		go func(i int) {
			defer wg.Done()
			t, _ := c.Get()
			tokens[i] = t
		}(i)
	}
	wg.Wait()

	// All concurrent callers receive the same coalesced token.
	first := tokens[0]
	var different int32
	for _, t := range tokens {
		if t != first {
			atomic.AddInt32(&different, 1)
		}
	}
	assert.Zero(t, different, "singleflight must coalesce")
}
