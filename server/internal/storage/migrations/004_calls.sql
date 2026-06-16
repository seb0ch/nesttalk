-- v0.2.0 call spool table.
-- See spec section "Audio Call Lifecycle FSM (Slice 4)".
--
-- Each row represents one call attempt. Calls are non-persistent beyond the
-- configurable TTL. The server never stores media; it only tracks call state
-- for signaling and missed-call delivery.
--
-- State machine:
--   ringing  → connected (accept)
--   ringing  → declined  (callee declines)
--   ringing  → cancelled (caller cancels)
--   ringing  → missed    (server 33s timer)
--   connected → ended    (either party, ended_reason='normal')
--   connected → ended    (caller cancels after connect, ended_reason='auto_ended_from_cancel')
--
-- missed_notified tracks whether the missed-call WS event has been delivered
-- to the callee. 0 = pending delivery; 1 = delivered.

CREATE TABLE calls (
  id                TEXT PRIMARY KEY,
  caller_user_id    TEXT NOT NULL REFERENCES users(id),
  callee_user_id    TEXT NOT NULL REFERENCES users(id),
  kind              TEXT NOT NULL,            -- 'audio' or 'video'
  state             TEXT NOT NULL,            -- 'ringing' | 'connected' | 'declined' | 'cancelled' | 'missed' | 'ended'
  ended_reason      TEXT,                     -- 'normal' | 'auto_ended_from_cancel' | 'stale_sweep' | NULL
  started_at        INTEGER NOT NULL,
  connected_at      INTEGER,
  ended_at          INTEGER,
  missed_notified   INTEGER NOT NULL DEFAULT 0
);

-- Partial index for fast glare-detection: only active (non-terminal) calls
-- are relevant when checking whether a user pair already has a call in progress.
CREATE INDEX calls_active_by_pair
  ON calls(caller_user_id, callee_user_id, state) WHERE state IN ('ringing', 'connected');
