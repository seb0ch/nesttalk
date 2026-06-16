// Package calls implements the v0.2.0 audio/video call lifecycle FSM.
//
// State machine transitions:
//
//	ringing  → connected (accept arrives within ringing window + 3s grace)
//	ringing  → declined  (callee declines)
//	ringing  → cancelled (caller cancels)
//	ringing  → missed    (server 33s timer fires before accept/decline/cancel)
//	connected → ended    (either party ends; ended_reason="normal")
//	connected → ended    (caller cancels after connect race; ended_reason="auto_ended_from_cancel")
//
// Sentinel errors are translated to HTTP status codes by mapCallsErr in routes.go.
package calls

import "errors"

// Sentinel errors returned by Manager methods.
var (
	// ErrGlare is returned when POST /calls finds an existing ringing or
	// connected call between the same user pair. The caller receives 409 with
	// the existing call metadata.
	ErrGlare = errors.New("glare: active call already exists")

	// ErrBusy is returned when POST /calls finds that either participant is
	// already in a ringing or connected call with a THIRD party. The
	// single-active-call-per-user invariant is enforced at the trust boundary,
	// independent of any client-side CallKit/CallCoordinator gating. The caller
	// receives 409 with the busy participant and existing call metadata.
	ErrBusy = errors.New("busy: a participant is already in an active call")

	// ErrNotFound is returned when the call_id does not exist.
	ErrNotFound = errors.New("call not found")

	// ErrNotAuthorized is returned when the session user is neither caller nor
	// callee on the call.
	ErrNotAuthorized = errors.New("not authorized for this call")

	// ErrWrongState is returned for a transition that is illegal from the
	// current state (e.g. accept on a missed call).
	ErrWrongState = errors.New("call is in wrong state for this action")

	// ErrCalleeOnly is returned when a caller-only action is attempted by the
	// callee, or vice versa.
	ErrCalleeOnly = errors.New("only the callee may perform this action")

	// ErrCallerOnly is returned when a callee-only action is attempted by the
	// caller.
	ErrCallerOnly = errors.New("only the caller may perform this action")

	// ErrSignalQueueFull is returned by RelaySignal when the peer is offline
	// and its per-call replay queue is saturated, so the signal could be
	// neither delivered nor queued. The WS handler must NOT ack a signal
	// that hit this — the sender keeps its copy and retries on reconnect.
	ErrSignalQueueFull = errors.New("call signal replay queue is full")

	// ErrSignalTooLarge is returned by RelaySignal when a single call_signal
	// payload exceeds maxSignalPayloadBytes. A legitimate SDP/ICE frame is
	// well under this; an oversized one is rejected (and NOT ack'd) so it can
	// neither be relayed nor parked in the per-call replay queue, bounding the
	// memory an authenticated participant can pin.
	ErrSignalTooLarge = errors.New("call signal payload too large")
)

// CallKind describes the call media type.
type CallKind string

const (
	KindAudio CallKind = "audio"
	KindVideo CallKind = "video"
)

// CallState represents the state-machine state of a call.
type CallState string

const (
	StateRinging   CallState = "ringing"
	StateConnected CallState = "connected"
	StateDeclined  CallState = "declined"
	StateCancelled CallState = "cancelled"
	StateMissed    CallState = "missed"
	StateEnded     CallState = "ended"
)

// IsTerminal reports whether s is a terminal (non-transitioning) state.
func (s CallState) IsTerminal() bool {
	switch s {
	case StateDeclined, StateCancelled, StateMissed, StateEnded:
		return true
	}
	return false
}

// EndedReason describes why a call ended.
type EndedReason string

const (
	ReasonNormal              EndedReason = "normal"
	ReasonAutoEndedFromCancel EndedReason = "auto_ended_from_cancel"
	ReasonStaleSweep          EndedReason = "stale_sweep"
)

// CallRow is a database row from the calls table.
type CallRow struct {
	ID             string
	CallerUserID   string
	CalleeUserID   string
	Kind           CallKind
	State          CallState
	EndedReason    *string // nil for non-ended states
	StartedAt      int64
	ConnectedAt    *int64
	EndedAt        *int64
	MissedNotified bool
}

// GlareInfo is embedded in the ErrGlare error response.
type GlareInfo struct {
	ExistingCallID       string    `json:"existing_call_id"`
	ExistingCallerUserID string    `json:"existing_caller_user_id"`
	ExistingCallKind     CallKind  `json:"existing_call_kind"`
	ExistingState        CallState `json:"existing_call_state"`
}

// GlareError carries the glare detail alongside the sentinel.
type GlareError struct {
	Info GlareInfo
}

func (e *GlareError) Error() string        { return ErrGlare.Error() }
func (e *GlareError) Is(target error) bool { return target == ErrGlare }

// BusyError carries the busy participant and the existing call that blocks a
// new Create when either party is already on an active call with a third user.
type BusyError struct {
	BusyUserID string
	Info       GlareInfo
}

func (e *BusyError) Error() string        { return ErrBusy.Error() }
func (e *BusyError) Is(target error) bool { return target == ErrBusy }

// WrongStateError carries the current state alongside the sentinel.
type WrongStateError struct {
	Current CallState
}

func (e *WrongStateError) Error() string        { return ErrWrongState.Error() }
func (e *WrongStateError) Is(target error) bool { return target == ErrWrongState }

// RelayCredentials contains time-limited TURN credentials for a client.
type RelayCredentials struct {
	Username   string   `json:"username"`
	Password   string   `json:"password"`
	TTLSeconds int      `json:"ttl_seconds"`
	URLs       []string `json:"urls"`
}
