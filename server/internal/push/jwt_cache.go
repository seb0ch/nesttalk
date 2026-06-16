// Package push provides Apple Push Notification Service integration for
// VoIP-class pushes that wake a terminated iOS app to ring CallKit.
package push

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/sync/singleflight"
)

// providerTokenTTL is the effective TTL we sign tokens with. Apple
// hard-caps provider tokens at 1 hour; we sign for 50 minutes to give
// ourselves ample headroom before refresh.
const providerTokenTTL = 50 * time.Minute

// JWTCache holds the most recent APNs provider JWT and regenerates it
// on demand. Concurrent Get() calls coalesce through a singleflight
// group so a token-expiry stampede produces exactly one signing call.
type JWTCache struct {
	keyID    string
	teamID   string
	signer   *ecdsa.PrivateKey
	now      func() time.Time
	mu       sync.RWMutex
	token    string
	notAfter time.Time
	sf       singleflight.Group
}

// NewJWTCache parses the .p8 key bytes and returns a cache.
//
//	keyP8: PEM-encoded EC private key contents (the file Apple gives
//	       you in App Store Connect).
//	keyID: 10-character key ID.
//	teamID: 10-character team ID.
func NewJWTCache(keyP8 []byte, keyID, teamID string) (*JWTCache, error) {
	if len(keyP8) == 0 {
		return nil, errors.New("apns: empty .p8 key")
	}
	if len(keyID) != 10 {
		return nil, fmt.Errorf("apns: key id must be 10 chars, got %d", len(keyID))
	}
	if len(teamID) != 10 {
		return nil, fmt.Errorf("apns: team id must be 10 chars, got %d", len(teamID))
	}
	block, _ := pem.Decode(keyP8)
	if block == nil {
		return nil, errors.New("apns: not PEM-encoded")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("apns: parse pkcs8: %w", err)
	}
	ec, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("apns: not an EC private key")
	}
	return &JWTCache{
		keyID:  keyID,
		teamID: teamID,
		signer: ec,
		now:    time.Now,
	}, nil
}

// Get returns the cached token if still fresh, else (singleflight)
// signs a new one. Safe for concurrent use.
func (c *JWTCache) Get() (string, error) {
	now := c.now()
	c.mu.RLock()
	if c.token != "" && now.Before(c.notAfter) {
		t := c.token
		c.mu.RUnlock()
		return t, nil
	}
	c.mu.RUnlock()

	v, err, _ := c.sf.Do("jwt", func() (any, error) {
		// Re-check under the singleflight closure — another caller may
		// have already refreshed.
		c.mu.RLock()
		if c.token != "" && c.now().Before(c.notAfter) {
			t := c.token
			c.mu.RUnlock()
			return t, nil
		}
		c.mu.RUnlock()

		issued := c.now()
		claims := jwt.MapClaims{
			"iss": c.teamID,
			"iat": issued.Unix(),
		}
		t := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
		t.Header["kid"] = c.keyID
		signed, err := t.SignedString(c.signer)
		if err != nil {
			return "", fmt.Errorf("apns: sign jwt: %w", err)
		}
		c.mu.Lock()
		c.token = signed
		c.notAfter = issued.Add(providerTokenTTL)
		c.mu.Unlock()
		return signed, nil
	})
	if err != nil {
		return "", err
	}
	return v.(string), nil
}

// ForceRefresh invalidates the cached token. Used when APNs returns
// `ExpiredProviderToken` or `BadDeviceToken` so the very next Get()
// signs a fresh one.
func (c *JWTCache) ForceRefresh() {
	c.mu.Lock()
	c.token = ""
	c.notAfter = time.Time{}
	c.mu.Unlock()
}

// SetNow overrides the clock for tests.
func (c *JWTCache) SetNow(fn func() time.Time) { c.now = fn }
