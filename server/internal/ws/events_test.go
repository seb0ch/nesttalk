package ws_test

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/seb0ch/nesttalk/server/internal/ws"
)

// marshal renders an event through Event.MarshalJSON and returns the flat map.
func marshal(t *testing.T, e ws.Event) map[string]any {
	t.Helper()
	b, err := json.Marshal(e)
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal(b, &m))
	return m
}

func TestEventConstructors(t *testing.T) {
	reason := "timeout"
	cases := []struct {
		name      string
		event     ws.Event
		wantType  string
		wantField string
		wantValue any
	}{
		{"message", ws.MessageEvent("m1", "a", "b", []byte("x"), 1, 2, nil), "message", "id", "m1"},
		{"message_delivered", ws.MessageDelivered("m1"), "message_delivered", "message_id", "m1"},
		{"message_read", ws.MessageRead("m1"), "message_read", "message_id", "m1"},
		{"reaction", ws.ReactionEvent("m1", "r1", "a", []byte("x"), 1, 2), "reaction", "reaction_id", "r1"},
		{"typing_start", ws.TypingStart("a", "b", 5), "typing_start", "from", "a"},
		{"typing_stop", ws.TypingStop("a", "b", 5), "typing_stop", "to", "b"},
		{"incoming_call", ws.IncomingCall("c1", "a", "audio", 5), "incoming_call", "call_id", "c1"},
		{"call_signal", ws.CallSignal("c1", map[string]any{"sdp": "x"}, 5), "call_signal", "call_id", "c1"},
		{"call_signal_ack", ws.CallSignalAck("c1", "s1", 5), "call_signal_ack", "signal_id", "s1"},
		{"call_missed", ws.CallMissed("c1", "a", 5), "call_missed", "call_id", "c1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := marshal(t, tc.event)
			assert.Equal(t, tc.wantType, m["type"])
			assert.Equal(t, tc.wantValue, m[tc.wantField])
		})
	}

	// CallStateChanged: ended state carries the reason; non-ended nils it.
	ended := marshal(t, ws.CallStateChanged("c1", "ended", false, &reason, 5))
	assert.Equal(t, "call_state_changed", ended["type"])
	assert.Equal(t, "timeout", ended["ended_reason"])

	ringing := marshal(t, ws.CallStateChanged("c1", "ringing", true, nil, 5))
	assert.Nil(t, ringing["ended_reason"])
	assert.Equal(t, true, ringing["stale"])
}

func TestNow(t *testing.T) {
	assert.Positive(t, ws.Now())
}
