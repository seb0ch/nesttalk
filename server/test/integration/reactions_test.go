// Integration tests for the reactions endpoints:
//
//	PUT  /api/v1/messages/{id}/reactions
//	GET  /api/v1/reactions/since
package integration_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ----- helper: PUT /messages/{id}/reactions -----

func putReaction(t *testing.T, srv *httptest.Server, msgID, envelopeB64 string, sentAt int64, out any, bearer string) int {
	t.Helper()
	jsBody, err := json.Marshal(map[string]any{
		"envelope": envelopeB64,
		"sent_at":  sentAt,
	})
	require.NoError(t, err)
	url := fmt.Sprintf("%s/api/v1/messages/%s/reactions", srv.URL, msgID)
	req, err := http.NewRequest("PUT", url, bytes.NewReader(jsBody))
	require.NoError(t, err)
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if out != nil {
		_ = json.Unmarshal(b, out)
	}
	return resp.StatusCode
}

// ----- tests -----

func TestReactions_PutAndSince_EndToEnd(t *testing.T) {
	srv, ctrl, _ := newStack(t)

	alice := enrollAndConnect(t, srv, ctrl, "alice", 1)
	bob := enrollAndConnect(t, srv, ctrl, "bob", 2)

	// Post a message alice → bob so the FK constraint is satisfied.
	msgID := "dddddddd-dddd-dddd-dddd-000000000001"
	msgEnvBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID, msgID, make([]byte, 32))
	code := postCode(t, srv, "/api/v1/messages", map[string]any{
		"envelope": base64.StdEncoding.EncodeToString(msgEnvBytes),
		"sent_at":  int64(1_700_000_000_000),
	}, nil, alice.Token)
	require.Equal(t, 200, code, "post message")

	// Build a reaction envelope (alice → bob, same wire layout as messages).
	// The signed message id must equal the parent id named on the path.
	rxnEnvBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID,
		msgID, make([]byte, 32))
	rxnEnvB64 := base64.StdEncoding.EncodeToString(rxnEnvBytes)

	// PUT reaction: alice reacts to msgID.
	var putResp struct {
		ID         string `json:"id"`
		ReceivedAt int64  `json:"received_at"`
	}
	code1 := putReaction(t, srv, msgID, rxnEnvB64, int64(1_700_000_000_100), &putResp, alice.Token)
	require.Equal(t, 200, code1)
	assert.NotEmpty(t, putResp.ID)

	// Idempotent second PUT: canonical id must stay the same.
	var putResp2 struct {
		ID string `json:"id"`
	}
	code2 := putReaction(t, srv, msgID, rxnEnvB64, int64(1_700_000_000_200), &putResp2, alice.Token)
	require.Equal(t, 200, code2)
	assert.Equal(t, putResp.ID, putResp2.ID, "canonical reaction id must not change on UPSERT")

	// GET /reactions/since as bob.
	var sinceResp struct {
		Reactions []struct {
			ID           string `json:"id"`
			MessageID    string `json:"message_id"`
			SenderUserID string `json:"sender_user_id"`
			ReceivedAt   int64  `json:"received_at"`
		} `json:"reactions"`
		NextCursor *struct {
			ReceivedAt int64  `json:"received_at"`
			ID         string `json:"id"`
		} `json:"next_cursor"`
	}
	codeGet := getCode(t, fmt.Sprintf("%s/api/v1/reactions/since?since_received_at=0&since_id=00000000-0000-0000-0000-000000000000&limit=10",
		srv.URL), &sinceResp, bob.Token)
	require.Equal(t, 200, codeGet)
	require.Len(t, sinceResp.Reactions, 1)
	assert.Equal(t, putResp.ID, sinceResp.Reactions[0].ID)
	assert.Equal(t, msgID, sinceResp.Reactions[0].MessageID)
	assert.Equal(t, alice.UserID, sinceResp.Reactions[0].SenderUserID)
}

func TestReactions_ParentPurged_410(t *testing.T) {
	// PUT against a message_id with no messages row → 410.
	srv, ctrl, _ := newStack(t)

	alice := enrollAndConnect(t, srv, ctrl, "alice", 1)
	bob := enrollAndConnect(t, srv, ctrl, "bob", 2)

	nonExistentMsgID := "ffffffff-ffff-ffff-ffff-000000000001"
	rxnEnvBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID,
		nonExistentMsgID, make([]byte, 32))

	var errResp map[string]any
	code := putReaction(t, srv, nonExistentMsgID,
		base64.StdEncoding.EncodeToString(rxnEnvBytes),
		int64(1_700_000_000_000), &errResp, alice.Token)
	assert.Equal(t, 410, code)
	assert.Equal(t, "parent message has been purged", errResp["error"])
}

func TestReactions_Unauthorized_403(t *testing.T) {
	// PUT where session user != envelope.sender_user_id → 403.
	srv, ctrl, _ := newStack(t)

	alice := enrollAndConnect(t, srv, ctrl, "alice", 1)
	bob := enrollAndConnect(t, srv, ctrl, "bob", 2)

	msgID := "dddddddd-dddd-dddd-dddd-000000000002"
	msgEnvBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID, msgID, make([]byte, 32))
	postCode(t, srv, "/api/v1/messages", map[string]any{
		"envelope": base64.StdEncoding.EncodeToString(msgEnvBytes),
		"sent_at":  int64(1_700_000_000_000),
	}, nil, alice.Token)

	// Alice's envelope but using bob's token → 403.
	rxnEnvBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID,
		msgID, make([]byte, 32))
	var errResp map[string]any
	code := putReaction(t, srv, msgID,
		base64.StdEncoding.EncodeToString(rxnEnvBytes),
		int64(1_700_000_000_000), &errResp, bob.Token) // bob's session
	assert.Equal(t, 403, code)
}

func TestReactions_Since_Pagination(t *testing.T) {
	// Two different messages, each gets a reaction from alice; bob pages through
	// with limit=1 and confirms two pages.
	srv, ctrl, _ := newStack(t)

	alice := enrollAndConnect(t, srv, ctrl, "alice", 1)
	bob := enrollAndConnect(t, srv, ctrl, "bob", 2)

	// Post two messages.
	msgIDs := []string{
		"eeeeeeee-eeee-eeee-eeee-000000000001",
		"eeeeeeee-eeee-eeee-eeee-000000000002",
	}
	for _, id := range msgIDs {
		envBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID, id, make([]byte, 32))
		code := postCode(t, srv, "/api/v1/messages", map[string]any{
			"envelope": base64.StdEncoding.EncodeToString(envBytes),
			"sent_at":  int64(1_700_000_000_000),
		}, nil, alice.Token)
		require.Equal(t, 200, code)
	}

	// React to both messages.
	for _, id := range msgIDs {
		rxnEnvBytes := buildEnvelope(0x01, alice.UserID, alice.DeviceID, bob.UserID, bob.DeviceID,
			id, make([]byte, 32))
		code := putReaction(t, srv, id,
			base64.StdEncoding.EncodeToString(rxnEnvBytes),
			int64(1_700_000_000_100), nil, alice.Token)
		require.Equal(t, 200, code)
	}

	// Page 1: limit=1.
	var page1 struct {
		Reactions []struct {
			ID string `json:"id"`
		} `json:"reactions"`
		NextCursor *struct {
			ReceivedAt int64  `json:"received_at"`
			ID         string `json:"id"`
		} `json:"next_cursor"`
	}
	url1 := fmt.Sprintf("%s/api/v1/reactions/since?since_received_at=0&since_id=00000000-0000-0000-0000-000000000000&limit=1", srv.URL)
	code1 := getCode(t, url1, &page1, bob.Token)
	require.Equal(t, 200, code1)
	require.Len(t, page1.Reactions, 1)
	require.NotNil(t, page1.NextCursor)

	// Page 2: use cursor from page 1.
	url2 := fmt.Sprintf("%s/api/v1/reactions/since?since_received_at=%d&since_id=%s&limit=1",
		srv.URL, page1.NextCursor.ReceivedAt, page1.NextCursor.ID)
	var page2 struct {
		Reactions []struct {
			ID string `json:"id"`
		} `json:"reactions"`
	}
	code2 := getCode(t, url2, &page2, bob.Token)
	require.Equal(t, 200, code2)
	require.Len(t, page2.Reactions, 1)
	// The two pages must have different reaction IDs.
	assert.NotEqual(t, page1.Reactions[0].ID, page2.Reactions[0].ID)
}
