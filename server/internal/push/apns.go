package push

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"golang.org/x/net/http2"
)

// APNS endpoints. The dev sandbox accepts dev-build tokens; production
// accepts ad-hoc / TestFlight / Developer-ID tokens. Mismatch returns
// HTTP 400 BadDeviceToken.
const (
	APNSDevHost  = "api.sandbox.push.apple.com:443"
	APNSProdHost = "api.push.apple.com:443"
)

// VoIPPayload is the body shipped to APNs for a VoIP push.
//
// Apple requires `content-available: 1` and an empty alert so CallKit
// can take over without showing a banner. Custom keys (call_uuid,
// from_user_id, from_name) are at the top level alongside `aps`.
type VoIPPayload struct {
	CallUUID   string `json:"call_uuid"`
	FromUserID string `json:"from_user_id"`
	FromName   string `json:"from_name"`
	// Kind ("audio"|"video") lets a lock-screen answer set up the right
	// media. Critical on the lock screen: synthesizing an audio call as
	// video would try to open the camera, which iOS blocks while locked,
	// dropping the call.
	Kind string `json:"kind"`
	APS  struct {
		Alert            string `json:"alert"`
		ContentAvailable int    `json:"content-available"`
	} `json:"aps"`
}

func NewVoIPPayload(callUUID, fromUserID, fromName, kind string) VoIPPayload {
	p := VoIPPayload{
		CallUUID:   callUUID,
		FromUserID: fromUserID,
		FromName:   fromName,
		Kind:       kind,
	}
	p.APS.Alert = ""
	p.APS.ContentAvailable = 1
	return p
}

// Client sends VoIP pushes through the HTTP/2 APNs surface.
type Client struct {
	httpClient *http.Client
	jwt        *JWTCache
	host       string // dev or prod
	topic      string // <bundle-id>.voip
}

// NewClient configures an APNs HTTP/2 client. host = APNSDevHost or
// APNSProdHost; topic = "<bundle>.voip" (e.g. "com.nesttalk.ios.voip").
func NewClient(jwt *JWTCache, host, topic string) (*Client, error) {
	if jwt == nil {
		return nil, errors.New("apns: jwt cache required")
	}
	hc := &http.Client{}
	if err := http2.ConfigureTransport(&http.Transport{}); err != nil {
		// http2.ConfigureTransport fails only when the package was
		// removed; treat as fatal.
		return nil, fmt.Errorf("apns: http2 transport: %w", err)
	}
	return &Client{
		httpClient: hc,
		jwt:        jwt,
		host:       host,
		topic:      topic,
	}, nil
}

// SendResult captures the APNs response so callers can react to 410
// (Unregistered → clear token) and 403 (provider-token issue → retry).
type SendResult struct {
	StatusCode int
	APNSID     string
	Reason     string // APNs-specific machine-readable reason key
}

// Send dispatches one VoIP payload to the supplied device token. On
// HTTP 403 (ExpiredProviderToken / BadDeviceToken), forces a JWT
// refresh and retries once.
func (c *Client) Send(ctx context.Context, deviceToken string, payload VoIPPayload) (*SendResult, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("apns: marshal payload: %w", err)
	}

	send := func() (*SendResult, error) {
		token, err := c.jwt.Get()
		if err != nil {
			return nil, fmt.Errorf("apns: jwt: %w", err)
		}
		url := fmt.Sprintf("https://%s/3/device/%s", c.host, deviceToken)
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
		if err != nil {
			return nil, fmt.Errorf("apns: build req: %w", err)
		}
		req.Header.Set("authorization", "bearer "+token)
		req.Header.Set("apns-push-type", "voip")
		req.Header.Set("apns-priority", "10")
		req.Header.Set("apns-topic", c.topic)
		req.Header.Set("apns-expiration", "0")
		req.Header.Set("apns-collapse-id", "voip-"+payload.CallUUID)
		req.Header.Set("content-type", "application/json")

		resp, err := c.httpClient.Do(req)
		if err != nil {
			return nil, fmt.Errorf("apns: do: %w", err)
		}
		defer resp.Body.Close()

		var rb struct {
			Reason string `json:"reason"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&rb)
		return &SendResult{
			StatusCode: resp.StatusCode,
			APNSID:     resp.Header.Get("apns-id"),
			Reason:     rb.Reason,
		}, nil
	}

	res, err := send()
	if err != nil {
		return nil, err
	}
	if res.StatusCode == http.StatusForbidden && (res.Reason == "ExpiredProviderToken" || res.Reason == "BadDeviceToken") {
		c.jwt.ForceRefresh()
		return send()
	}
	return res, nil
}
