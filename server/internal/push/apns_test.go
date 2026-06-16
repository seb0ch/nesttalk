package push

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestVoIPPayload_ShapeMatchesCallKitExpectations(t *testing.T) {
	p := NewVoIPPayload("uuid-1", "user-mom", "Mom", "video")
	out, err := json.Marshal(p)
	assert.NoError(t, err)

	var asMap map[string]interface{}
	assert.NoError(t, json.Unmarshal(out, &asMap))

	assert.Equal(t, "uuid-1", asMap["call_uuid"])
	assert.Equal(t, "user-mom", asMap["from_user_id"])
	assert.Equal(t, "Mom", asMap["from_name"])
	aps := asMap["aps"].(map[string]interface{})
	assert.Equal(t, "", aps["alert"])
	assert.Equal(t, float64(1), aps["content-available"])
}

func TestNewClient_RejectsNilJWT(t *testing.T) {
	_, err := NewClient(nil, APNSDevHost, "com.nesttalk.ios.voip")
	assert.Error(t, err)
}
