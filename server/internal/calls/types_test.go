package calls

import (
	"errors"
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestErrorTypes covers the Error()/Is() methods on the typed call errors so
// errors.Is dispatch against the sentinels works as the HTTP layer relies on.
func TestErrorTypes(t *testing.T) {
	glare := &GlareError{Info: GlareInfo{ExistingCallID: "c1"}}
	assert.Equal(t, ErrGlare.Error(), glare.Error())
	assert.True(t, errors.Is(glare, ErrGlare))
	assert.False(t, errors.Is(glare, ErrBusy))

	busy := &BusyError{BusyUserID: "u1"}
	assert.Equal(t, ErrBusy.Error(), busy.Error())
	assert.True(t, errors.Is(busy, ErrBusy))
	assert.False(t, errors.Is(busy, ErrGlare))

	ws := &WrongStateError{Current: StateEnded}
	assert.Equal(t, ErrWrongState.Error(), ws.Error())
	assert.True(t, errors.Is(ws, ErrWrongState))
	assert.False(t, errors.Is(ws, ErrNotFound))
}
