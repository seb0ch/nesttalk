-- v0.4.0 — VoIP push tokens per device.
--
-- Apple PushKit (.voIP) is the only push class that can wake a
-- terminated app to ring CallKit on iOS lock screen. Storing one token
-- per device with its environment (dev / prod) means we route to the
-- right APNs endpoint regardless of which build the user installed.
--
-- HTTP/2 APNs requests are sent from server/internal/push/apns.go.
-- The provider JWT cache lives in server/internal/push/jwt_cache.go
-- and is regenerated every 50 minutes (Apple caps provider tokens at
-- 1 hour). On HTTP 410 we clear the token (Apple has marked it
-- unregistered); on 403 with ExpiredProviderToken / BadDeviceToken we
-- regenerate the JWT once and retry.
--
-- The push payload is intentionally tiny: call_uuid, from_user_id,
-- from_name, alert="" + content-available=1. CallKit doesn't read
-- the alert text (it builds its own ring UI from the call_uuid +
-- handle reported by the client side via reportNewIncomingCall).

ALTER TABLE devices ADD COLUMN voip_push_token TEXT;
ALTER TABLE devices ADD COLUMN voip_push_env   TEXT
    CHECK (voip_push_env IS NULL OR voip_push_env IN ('dev', 'prod'));
CREATE INDEX IF NOT EXISTS idx_devices_voip_push_token
    ON devices(voip_push_token)
    WHERE voip_push_token IS NOT NULL;
