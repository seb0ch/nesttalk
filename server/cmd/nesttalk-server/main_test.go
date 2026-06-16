package main

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestEnvOrDefault(t *testing.T) {
	t.Setenv("NT_TEST_ENV_KEY", "")
	assert.Equal(t, "fallback", envOrDefault("NT_TEST_ENV_KEY", "fallback"))
	t.Setenv("NT_TEST_ENV_KEY", "explicit")
	assert.Equal(t, "explicit", envOrDefault("NT_TEST_ENV_KEY", "fallback"))
}

func TestParseAllowedOrigins(t *testing.T) {
	// Empty → loopback + dev-domain defaults.
	def := parseAllowedOrigins("")
	assert.Contains(t, def, "127.0.0.1:*")
	assert.Contains(t, def, "*.nesttalk.local")

	// CSV with whitespace and empty entries is trimmed.
	got := parseAllowedOrigins(" https://a.example , ,https://b.example ")
	assert.Equal(t, []string{"https://a.example", "https://b.example"}, got)

	// Whitespace-only collapses to the default set.
	assert.NotEmpty(t, parseAllowedOrigins("   "))
}

func TestBuildAPNsClients(t *testing.T) {
	// Clear every APNs env var so the test is hermetic regardless of host.
	for _, k := range []string{
		"NESTTALK_APNS_KEY_ID", "NESTTALK_APNS_TEAM_ID", "NESTTALK_APNS_TOPIC_VOIP",
		"NESTTALK_APNS_KEY_P8_PATH", "NESTTALK_APNS_KEY_P8",
	} {
		t.Setenv(k, "")
	}

	// Fully unconfigured → opt-in feature off, no error.
	dev, prod, err := buildAPNsClients()
	require.NoError(t, err)
	assert.Nil(t, dev)
	assert.Nil(t, prod)

	// Partial config → error.
	t.Setenv("NESTTALK_APNS_KEY_ID", "ABCDE12345")
	_, _, err = buildAPNsClients()
	require.Error(t, err)
	assert.Contains(t, err.Error(), "partial APNs config")

	// All identifiers set but no key material → error.
	t.Setenv("NESTTALK_APNS_TEAM_ID", "Q2GZ8F5NV5")
	t.Setenv("NESTTALK_APNS_TOPIC_VOIP", "com.nesttalk.ios.voip")
	_, _, err = buildAPNsClients()
	require.Error(t, err)
	assert.Contains(t, err.Error(), "required")

	// Unreadable key path → error.
	t.Setenv("NESTTALK_APNS_KEY_P8_PATH", "/nonexistent/key.p8")
	_, _, err = buildAPNsClients()
	require.Error(t, err)
	assert.Contains(t, err.Error(), "read APNs .p8")
}

func TestParentDir(t *testing.T) {
	assert.Equal(t, "/a/b", parentDir("/a/b/c"))
	assert.Equal(t, "/a", parentDir("/a/b"))
	assert.Equal(t, ".", parentDir("noslash"))
	assert.Equal(t, "", parentDir("/top"))
}

func TestVoIPTokenLifecycle(t *testing.T) {
	s := newFullStack(t)
	hexToken := strings.Repeat("ab", 32)

	// Register a token through the public handler.
	resp := s.do(t, http.MethodPost, "/api/v1/devices/push-token", s.alice.Token, map[string]string{
		"token": hexToken, "env": "prod",
	})
	require.Equal(t, http.StatusNoContent, resp.StatusCode)

	// lookupVoIPToken returns the freshly-registered token + env.
	ctx := context.Background()
	tok, env, err := lookupVoIPToken(ctx, s.deps.DB, s.alice.UserID)
	require.NoError(t, err)
	assert.Equal(t, hexToken, tok)
	assert.Equal(t, "prod", env)

	// clearVoIPToken drops it; the row stays but the token is nulled.
	require.NoError(t, clearVoIPToken(ctx, s.deps.DB, s.alice.UserID, hexToken))
	tok, _, err = lookupVoIPToken(ctx, s.deps.DB, s.alice.UserID)
	require.NoError(t, err)
	assert.Empty(t, tok)
}
