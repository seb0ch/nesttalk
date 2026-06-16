// Package ws hosts the WebSocket session map and broadcast hub.
// Slice 1a ships the hub primitive only — message/call/typing event
// producers land in Slices 2+. The hub is interface-clean now so those
// slices wire in without restructuring.
package ws

import (
	"encoding/base64"
	"encoding/json"
	"time"
)

// Event is any payload broadcast through the hub. Concrete event payloads
// (message, reaction, presence_changed, ...) carry a "type" field per spec
// section "Call signaling messages over WS".
type Event struct {
	Type    string         `json:"type"`
	Payload map[string]any `json:"-"`
}

// MarshalJSON inlines Payload at the top level so consumers see flat events.
func (e Event) MarshalJSON() ([]byte, error) {
	out := map[string]any{"type": e.Type}
	for k, v := range e.Payload {
		out[k] = v
	}
	return json.Marshal(out)
}

// PresenceChanged builds a presence_changed event.
func PresenceChanged(userID string, online bool, atMillis int64) Event {
	return Event{Type: "presence_changed", Payload: map[string]any{
		"user_id": userID,
		"online":  online,
		"at":      atMillis,
	}}
}

// ServerRestored signals JWT-kid rotation after a backup restore.
func ServerRestored(generation int64, jwtKid string, atMillis int64) Event {
	return Event{Type: "server_restored", Payload: map[string]any{
		"generation": generation,
		"jwt_kid":    jwtKid,
		"at":         atMillis,
	}}
}

// MessageEvent builds the "message" event delivered to the recipient on POST /messages.
// id == messages.id (the delivery-handle invariant from spec line 397).
func MessageEvent(id, from, to string, envelope []byte, sentAt, receivedAt int64, replyToID *string) Event {
	p := map[string]any{
		"id":          id,
		"from":        from,
		"to":          to,
		"envelope":    base64.StdEncoding.EncodeToString(envelope),
		"sent_at":     sentAt,
		"received_at": receivedAt,
		"reply_to_id": replyToID,
	}
	return Event{Type: "message", Payload: p}
}

// MessageDelivered builds the "message_delivered" ack event sent to the sender.
func MessageDelivered(messageID string) Event {
	return Event{Type: "message_delivered", Payload: map[string]any{
		"message_id": messageID,
	}}
}

// MessageRead builds the "message_read" ack event sent to the sender.
func MessageRead(messageID string) Event {
	return Event{Type: "message_read", Payload: map[string]any{
		"message_id": messageID,
	}}
}

// ReactionEvent builds the "reaction" event delivered to the recipient on
// PUT /messages/{id}/reactions. The wrapper id is the parent message_id so
// the client can correlate the event with the correct thread without an
// extra fetch. The reaction_id is the server-assigned canonical UUID.
func ReactionEvent(messageID, reactionID, senderUserID string, envelope []byte, sentAt, receivedAt int64) Event {
	return Event{Type: "reaction", Payload: map[string]any{
		"id":             messageID,
		"reaction_id":    reactionID,
		"sender_user_id": senderUserID,
		"envelope":       base64.StdEncoding.EncodeToString(envelope),
		"sent_at":        sentAt,
		"received_at":    receivedAt,
	}}
}

// TypingStart builds the outbound "typing_start" event.
func TypingStart(from, to string, atMillis int64) Event {
	return Event{Type: "typing_start", Payload: map[string]any{
		"from": from,
		"to":   to,
		"at":   atMillis,
	}}
}

// TypingStop builds the outbound "typing_stop" event.
func TypingStop(from, to string, atMillis int64) Event {
	return Event{Type: "typing_stop", Payload: map[string]any{
		"from": from,
		"to":   to,
		"at":   atMillis,
	}}
}

// IncomingCall builds the "incoming_call" event sent to the callee.
// Retransmitted every 3s during the ringing window (spec line 807).
func IncomingCall(callID, fromUserID, kind string, atMillis int64) Event {
	return Event{Type: "incoming_call", Payload: map[string]any{
		"call_id":      callID,
		"from_user_id": fromUserID,
		"kind":         kind,
		"at":           atMillis,
	}}
}

// CallSignal builds the "call_signal" event used for WebRTC offer/answer/ICE exchange.
func CallSignal(callID string, payload map[string]any, atMillis int64) Event {
	return Event{Type: "call_signal", Payload: map[string]any{
		"call_id": callID,
		"payload": payload,
		"at":      atMillis,
	}}
}

// CallSignalAck confirms to the SENDER that the server accepted (relayed
// or queued) a call_signal it identified by signal_id. The client retains
// each signal until this ack arrives and re-sends un-acked signals on
// reconnect, so a disconnect between the client's local write and the
// server's read can't silently lose an offer/answer/ICE candidate.
func CallSignalAck(callID, signalID string, atMillis int64) Event {
	return Event{Type: "call_signal_ack", Payload: map[string]any{
		"call_id":   callID,
		"signal_id": signalID,
		"at":        atMillis,
	}}
}

// CallStateChanged builds the "call_state_changed" event.
// stale is true when emitted on WS reconnect for calls that were active
// before the disconnect. endedReason is nil for non-ended states.
func CallStateChanged(callID, state string, stale bool, endedReason *string, atMillis int64) Event {
	p := map[string]any{
		"call_id": callID,
		"state":   state,
		"stale":   stale,
		"at":      atMillis,
	}
	if endedReason != nil {
		p["ended_reason"] = *endedReason
	} else {
		p["ended_reason"] = nil
	}
	return Event{Type: "call_state_changed", Payload: p}
}

// CallMissed builds the "call_missed" event sent to the callee when the
// ringing timer expires without accept/decline/cancel.
func CallMissed(callID, fromUserID string, atMillis int64) Event {
	return Event{Type: "call_missed", Payload: map[string]any{
		"call_id":      callID,
		"from_user_id": fromUserID,
		"at":           atMillis,
	}}
}

// Now returns current unix-millis. Wrapped so tests can override via the hub.
func Now() int64 { return time.Now().UnixMilli() }
