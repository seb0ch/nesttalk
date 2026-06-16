package main

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"encoding/json"
	"io"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Verifies the invite-URL builder produces a zlib+base64url JSON blob the
// Dart canonical decoder will accept (see client/test/enrollment_payload_test.dart).
func TestBuildInviteURL_EmitsZlibBase64URLJSON(t *testing.T) {
	t.Setenv("REALITY_SERVER_ADDR", "nest.example.com:443")
	t.Setenv("REALITY_PUBLIC_KEY", "canonical-pk")
	t.Setenv("REALITY_SHORT_ID", "cafebabe")
	t.Setenv("REALITY_SNI", "cloudflare.com")
	t.Setenv("REALITY_API_UUID", "api-uuid-value")
	t.Setenv("REALITY_TURN_UUID", "turn-uuid-value")

	url, err := buildInviteURL("canonical-code")
	require.NoError(t, err)
	require.True(t, strings.HasPrefix(url, "nesttalk://i/"), url)

	encoded := strings.TrimPrefix(url, "nesttalk://i/")
	compressed, err := base64.RawURLEncoding.DecodeString(encoded)
	require.NoError(t, err)

	zr, err := zlib.NewReader(bytes.NewReader(compressed))
	require.NoError(t, err)
	defer zr.Close()
	jsonBytes, err := io.ReadAll(zr)
	require.NoError(t, err)

	var payload struct {
		V         int                    `json:"v"`
		Code      string                 `json:"code"`
		Transport map[string]interface{} `json:"transport"`
	}
	require.NoError(t, json.Unmarshal(jsonBytes, &payload))
	assert.Equal(t, 1, payload.V)
	assert.Equal(t, "canonical-code", payload.Code)
	assert.Equal(t, "reality", payload.Transport["kind"])
	assert.Equal(t, "nest.example.com:443", payload.Transport["server_addr"])
	assert.Equal(t, "canonical-pk", payload.Transport["public_key"])
	assert.Equal(t, "cafebabe", payload.Transport["short_id"])
	assert.Equal(t, "cloudflare.com", payload.Transport["sni"])
	assert.Equal(t, "api-uuid-value", payload.Transport["api_uuid"])
	assert.Equal(t, "turn-uuid-value", payload.Transport["turn_uuid"])

	// The 800-byte spec cap is generous; assert at least the encoded blob
	// is well under that for a minimal payload.
	assert.LessOrEqual(t, len(encoded), 800, "encoded invite must fit the 800-byte budget")
}

// Locked canonical byte vector. MUST stay in lock-step with
// client/test/enrollment_payload_test.dart "decodes locked canonical
// zlib byte vector". If Go's json/zlib behaviour changes and this
// assertion breaks, update BOTH test vectors together or the Dart↔Go
// invite-blob contract is broken.
func TestBuildInviteURL_MatchesLockedCanonicalVector(t *testing.T) {
	t.Setenv("REALITY_SERVER_ADDR", "nest.example.com:443")
	t.Setenv("REALITY_PUBLIC_KEY", "canonical-pk")
	t.Setenv("REALITY_SHORT_ID", "cafebabe")
	t.Setenv("REALITY_SNI", "cloudflare.com")
	t.Setenv("REALITY_API_UUID", "api-uuid-value")
	t.Setenv("REALITY_TURN_UUID", "turn-uuid-value")

	url, err := buildInviteURL("canonical-code")
	require.NoError(t, err)

	const locked = "nesttalk://i/" +
		"eJxUjlFqwCAQRO8y3yZQmi8vIxvdUIlRWTU0hNy9bKDQ_g2P2Z13w5fAsPCUS46e0vQCgy6UWy3SYW9QjW6MGGA1Thqnk9LQ4h6zcmFKsV8wqGNN0budr39_6w6DxnKyOApBYJG59Zm_6aiJZ18OuyyfWvoq0t275mnjlVbdaTkqSGWELZG8B-o5JP-6af4r9xicsB_PTwAAAP__1itO9Q"
	assert.Equal(t, locked, url,
		"Go-side encoder drifted from the locked invite-blob byte vector; "+
			"update this test AND client/test/enrollment_payload_test.dart "+
			"together or the wire contract is broken.")
}
