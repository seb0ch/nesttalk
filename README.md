# NestTalk

A private family-first messenger built for synchronous sessions: end-to-end encrypted messages and calls, zero-knowledge server architecture, and camouflaged transport for restricted networks. Native Apple client (iOS / iPadOS / macOS) backed by a Go server.

## What's inside

A native Swift/SwiftUI Apple client (iOS / iPadOS / macOS) backed by a Go server, deployed as a Podman pod with a sing-box REALITY ingress and a coturn relay.

- **1:1 messaging** — hybrid post-quantum ML-KEM 768 E2EE; server stores only ciphertext envelopes.
- **1:1 voice/video calls** — WebRTC over WebSocket signaling; relay-only via coturn (no direct ICE candidates, no public TURN ports).
- **Encrypted local history** — GRDB.swift per-device message log with message bodies AEAD-sealed at rest (app-level column encryption under the Keychain wrap key); full-file SQLCipher is an optional layer behind a build flag.
- **REALITY transport** — single-port `:443` camouflaged TLS ingress; external observer sees `cloudflare.com:443` only. iOS/iPadOS/macOS all use the same in-bundle `Libbox.xcframework`.
- **Apple-native UX** — SwiftUI throughout; iOS uses CallKit + PushKit for incoming-calls-while-locked; macOS uses NavigationSplitView. Requires **iOS 26 / macOS 26** (the hybrid PQC envelope uses CryptoKit's ML-KEM-768, an iOS/macOS 26 API).
- **Admin CLI** — 13 subcommands; all but the last-resort `emergency-shell` go through a Unix socket sidecar; no admin HTTP endpoints.

See **[AGENTS.md](AGENTS.md)** for the developer-facing overview (architecture, API surface, constraints, build policy).

## Distribution

**Not the App Store.** Distribution is via:
- Apple Developer-signed direct builds (notarized `.app` / IPA)
- TestFlight beta (90-day rotation for family)
- AltStore / sideload for macOS

This unblocks GPL-3 transport dependencies (libbox / sing-box) for the final binary while the first-party code stays MIT.

A native Android client would be a separate codebase (not in this repository).

## Deploy

Target: Ubuntu 24.04+ with Podman. For a **fresh VPS** (package install, firewall, source copy, gotchas) follow the full **[Fresh Host Deployment](#fresh-host-deployment)** runbook below. Quick form once the host is prepared and the source is on it:

```bash
cd /opt/nesttalk
./deploy/up.sh --server-addr YOUR_HOST_OR_IP:443   # first run
./deploy/up.sh                                     # subsequent (reuses .env)
```

See `ADMIN_GUIDE.md` for full operator runbook (user enrollment, backup cadence, vacuum, emergency-shell, licensing posture).

## Admin docs

See **`ADMIN_GUIDE.md`** — covers:
- User and device lifecycle
- Backup cadence (daily minimum) and restore runbook
- SQLite encryption posture (filesystem encryption + E2EE; not SQLCipher server-side)
- VACUUM runbook
- Reconcile-device flow
- Emergency shell (last-resort recovery)
- Pilot-family handoff checklist
- Embedded libbox GPL-3 licensing and distribution posture

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Apple Client (Swift / SwiftUI — iOS / iPadOS / macOS)          │
│                                                                 │
│  ┌──────────┐  ┌───────────┐  ┌──────────────────────────────┐  │
│  │ Keychain  │  │ ML-KEM   │  │  Libbox.xcframework          │  │
│  │ + GRDB    │  │ 768 E2EE │  │  (sing-box REALITY,           │  │
│  │ +AEAD body│  │ (CryptoKit│  │   command-server mode)       │  │
│  └──────────┘  └───────────┘  │                              │  │
│                                │  ┌─────────┐  ┌───────────┐ │  │
│                                │  │ API     │  │ TURN      │ │  │
│                                │  │ inbound │  │ inbound   │ │  │
│                                │  │ :random │  │ :random   │ │  │
│                                │  └────┬────┘  └─────┬─────┘ │  │
│                                └───────┼─────────────┼───────┘  │
└────────────────────────────────────────┼─────────────┼──────────┘
                                         │             │
                                         └──────┬──────┘
                                                │ VLESS/REALITY :443
                                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  Podman Pod (Ubuntu 24.04 LTS)                                  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  sing-box REALITY server — :443 (only exposed port)     │    │
│  │  Camouflaged TLS ingress, SNI target: cloudflare.com    │    │
│  │                                                          │    │
│  │  Route by user UUID:                                     │    │
│  │    REALITY_API_UUID  → freedom → Go Server :8080         │    │
│  │    REALITY_TURN_UUID → freedom → coturn    :3478         │    │
│  └────────────────────────┬──────────────┬──────────────────┘    │
│                           │              │                       │
│              ┌────────────▼──┐     ┌─────▼──────────────────┐    │
│              │  Go Server    │     │  coturn (TURN relay)   │    │
│              │  :8080        │     │  :3478 TCP listener    │    │
│              │  REST API     │     │  UDP relay internal    │    │
│              │  + WS hub     │     │  allow-loopback-peers  │    │
│              └───────┬───────┘     └────────────────────────┘    │
│                      │                                           │
│           ┌──────────▼──────────┐   ┌─────────────────────────┐  │
│           │  SQLite (WAL mode)  │   │ Admin CLI (podman exec) │  │
│           │  + goose migrations │   │ 13 cmds — never exposed │  │
│           └─────────────────────┘   └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘

External observer sees: TLS connections to cloudflare.com:443. Nothing else.
```

### Components

| Component | Role |
|---|---|
| **Server (Go 1.26)** | REST API + WebSocket hub, SQLite, enrollment, device auth, global roster, offline ciphertext spool, TURN credential minting (HMAC credentials for coturn) |
| **Admin CLI (Go)** | Server-local only via `podman exec`, 13 subcommands (all but the last-resort `emergency-shell` routed through a Unix-socket sidecar); no admin HTTP surface |
| **Apple Client (Swift)** | iOS/iPadOS/macOS native app — enrollment, device-key auth, Keychain identity, GRDB local history with AEAD-sealed bodies at rest, ML-KEM 768 E2EE, in-bundle REALITY transport, CallKit/PushKit/WebRTC for calls, SwiftUI Hearth design language |
| **sing-box REALITY** | Single-port camouflaged TLS ingress (`:443`). Routes API and TURN traffic by VLESS UUID. SNI target: `cloudflare.com` |
| **coturn** | TURN relay for media — TCP listener (pod-internal only), UDP relay on loopback, `allow-loopback-peers`. No public ports. |

### Single-Port Design

All NestTalk traffic flows through the single REALITY port (`:443`). There are no exposed TURN ports — coturn is reachable only within the pod via REALITY freedom routing.

- Two server-wide UUIDs: `REALITY_API_UUID` (API/WS) and `REALITY_TURN_UUID` (TURN). Shared by all clients.
- The Apple client embeds `Libbox.xcframework` and runs the REALITY client locally on two random loopback ports — one for API, one for TURN.
- The server returns TURN `username` / `credential` / `policy`; the client constructs the `turn:` URL pointing at its local loopback port.

### Message Flow

```
  Sender                        Server                      Recipient
    │                             │                             │
    │  GET /keys/message/{user}   │                             │
    │────────────────────────────►│                             │
    │  ◄── recipient public keys  │                             │
    │                             │                             │
    │  ML-KEM 768 seal per device │                             │
    │  POST /messages             │                             │
    │────────────────────────────►│  store ciphertext envelopes │
    │                             │──────────────────────────►  │
    │                             │  WS: new_message event      │
    │                             │─────────────────────────────►
    │                             │                             │
    │                             │  GET /messages/pending      │
    │                             │◄─────────────────────────────
    │                             │  ──► ciphertext envelopes   │
    │                             │                             │
    │                             │  ML-KEM 768 open per device │
    │                             │  POST /messages/{id}/ack    │
    │                             │◄─────────────────────────────
```

### Status — components

- Text messages are end-to-end encrypted per recipient device using ML-KEM 768 (hybrid post-quantum KEM). The server stores only ciphertext envelopes.
- The WebSocket hub routes events per-device (`map[userID]map[deviceID]*conn`); message ack is device-scoped. Revoking a user/device (or a same-user re-enroll/re-handshake) severs the live control socket at the protocol level immediately — closing the outbound channel alone would let the reader goroutine keep relaying typing / call_signal under the socket's upgrade-time claims until its next read errors or the 30s revalidation tick; a per-session close hook tears the connection down so a revoked device can no longer send.
- macOS client: data-protection Keychain via `kSecUseDataProtectionKeychain` so identity survives Debug re-signs (the legacy login keychain is ACL-tied to the signing identity and breaks across builds).
- Single-port REALITY architecture: only `:443` exposed for all NestTalk services (API, WebSocket, TURN relay).
- The Apple binary embeds `Libbox.xcframework` rebuilt from a pinned sing-box tag; this brings GPL-3.0-or-later upstream licensing into the shipped binary. Distribution posture (sideload / TestFlight / Developer-signed) is the reason this is acceptable. See `ADMIN_GUIDE.md`.
- 1:1 calls are wired end-to-end: the server relays `call_signal` WS frames (WebRTC offer/answer/ICE) between call participants, and the client composes signaling + peer connection + ring surfaces (CallKit on iOS, in-app sheet on macOS) via `CallCoordinator`. The VoIP-push and WS ring paths converge on one CallKit call (UUID derived from the server call id), with lock-screen answer/decline buffered across app cold-launch. If a push rings CallKit and the call is then cancelled/missed before the socket registers — so the server replays only a terminal `call_state_changed` (no `incoming_call`) — the terminal/missed handlers still derive that deterministic CallKit UUID, end the system ring, and drain its buffered answer/end intents, so the lock screen doesn't keep ringing a dead call. The VoIP push token is registered with the server after connection and re-registered on every refresh (the token APNs hands at launch is retained until a session exists), so terminated iOS clients actually receive the incoming-call wake. The server's per-call signal-dedup state is bounded (FIFO-evicted) so a connected participant can't exhaust memory with unlimited signal ids, and call_signal payloads are byte-bounded on both legs: the control WebSocket sets an explicit per-frame read limit, an oversized single payload is rejected (and not ack'd) before it can be relayed or queued, and the per-call offline replay queue is capped by total bytes as well as count — so an authenticated participant can't pin unbounded memory with a few large SDP/ICE frames. The client mirrors this: signals buffered at a ringing callee before media is ready are bounded per call by both count and total bytes, and remote ICE candidates buffered before the remote SDP lands are bounded by count — so a caller can't flood a ringing device into memory exhaustion before the user even answers. Signal delivery is confirmed end-to-end: each `call_signal` carries a `signal_id`; the client retains it until the server replies `call_signal_ack` and re-sends un-acked signals on reconnect (and a single send is marked sent only AFTER the WS frame actually succeeds — a transient send failure leaves it retryable and a coalesced backoff re-pump re-sends it even without a reconnect, instead of stranding it as falsely-sent; and a successfully-sent-but-unacked signal is re-sent on an ack deadline by a watchdog — the server deliberately withholds `call_signal_ack` when it can't deliver/queue under peer backpressure or a full replay queue, expecting a retry, so without a timer that signal would otherwise sit unacked on a live connection until an unrelated reconnect), while the server dedups by `signal_id` (idempotent replay) and salvages frames that entered a dead-but-registered session channel — so neither the client→server nor the server→client leg can silently drop an offer/answer/ICE. Salvage and reconnect-flush both re-check the call is still live (exists, ringing/connected, target is a participant) before re-queuing or delivering a `call_signal`: a frame that lost the race with a cancel/end is dropped (and its residue purged) instead of resurrecting stale SDP/ICE for a dead call or jumping ahead of the terminal snapshot on the peer's reconnect. That check is tri-state — only a confirmed gone/non-participant/terminal call drops the signal; a transient DB error (e.g. a closed handle mid restore/vacuum) keeps it, so a still-live call's already-acked offer/answer/ICE is never lost. The salvage queue is also aggregate-bounded by count and bytes (oldest-first eviction), so repeated write-failure → salvage cycles can't grow per-call memory past the caps even though salvage bypasses the live per-frame cap. The single-active-call-per-user invariant is enforced server-side: `POST /calls` rejects a new call when either participant is already ringing or connected — with a third party (`busy`, 409) or the same peer (`glare`, 409) — so a direct REST client can't put a user into two concurrent calls even though CallKit and the `CallCoordinator` phase already gate to one. The two 409s are deliberately asymmetric: a `glare` body carries the existing call's id/caller/state because the requester is a participant and needs them to reconcile the race, whereas a cross-pair `busy` body returns only `busy_user_id` (always self or the dialed peer) — never the blocking call's id or the third-party caller — so it can't be used to probe another user's activity. The client decodes strictly on the `error` discriminator, so a busy result is a terminal dial-failure and is never mistaken for a recoverable glare pivot — and the glare pivot fails closed, synthesizing an incoming ring only when `existing_call_state` is explicitly `ringing` (a missing/unknown state, e.g. from an older server, never pivots). Terminal call actions (end/cancel/decline) are driven durably: the local UI tears down immediately while the server teardown retries transient failures with backoff (stopping on success or a 4xx wrong-state/not-found), so a dropped `/end` can't leave a `connected` row that glare-blocks every follow-up call until the sweep. A 401 during that retry is treated as auth churn (not a terminal call state): it triggers a session refresh and retries with the fresh token, so a hang-up racing a token rotation still tears the row down. Only a 404/409/403 (proven non-recoverable call-state error) stops the retry. The glare pivot preserves any offer/ICE already buffered for the call it pivots to (the local teardown would otherwise discard the only server-accepted offer and stall the call), and a locally-initiated terminal action (end/cancel/decline) purges that call's un-acked signals after the REST action succeeds — and also when it stops on a terminal 4xx (hang-up racing the server's missed/timeout transition) or when a `call_missed` event arrives — so a lost ack can't leave a stale offer replaying on every reconnect, while a retryable failure still never abandons signals the server considers live. Missed-call delivery marks `missed_notified` BEFORE enqueue (undoing it if the enqueue doesn't land), so the writer's salvage reset for an unwritten frame always wins the race instead of being overwritten by a late mark. If accept setup fails before `/accept` connects the call (e.g. relay credentials fail), the still-ringing row is cleaned up with `/decline` rather than `/end` (which the server rejects for a ringing call), so the caller doesn't ring until the missed sweep. VoIP pushes inspect the APNs response status (not just transport errors): a non-2xx rejection is logged, and a token Apple reports as permanently dead (410 Unregistered / BadDeviceToken / topic mismatch) is cleared so the server stops waking a dead token and the client re-registers on next launch. An incoming call during outgoing-call setup is refused as busy so it can't orphan the dial; a saturated peer replay queue returns an error so the sender keeps retrying rather than dropping its only copy on a false ack; a peer that is LIVE but backpressured (its outbound channel full) is distinguished from an offline one — instead of parking the frame for a reconnect-flush that will never fire, the server withholds the ack and the client retries once the channel drains; and call events ingested before the coordinator subscribes are buffered, not lost. The periodic stale-call sweep ends a >4h `connected` row only when BOTH participants stay absent from the control hub for a grace window — a single instantaneous absence is unreliable (a server restart, network handoff, app background, or transient WS error briefly unregisters a still-active peer, and the 5s sweep could otherwise catch both mid-reconnect and force-hang a healthy long call); a reappearing peer resets the grace, and only sustained double-absence ("clients vanished") is swept.
- Message E2EE runs the real hybrid path in-app: `HybridCryptoService` (X25519 + ML-KEM-768 → HKDF → ChaCha20-Poly1305) over Keychain-held device keys, with recipient keys resolved and cached via `GET /api/v1/keys/message/{userId}`. The HKDF `info` and AEAD AAD are the 96-byte routing blob (`"nesttalk-msg-v1" || version || sender_user || sender_device || recipient_user || recipient_device || message_id`), byte-identical to the Go reference in `server/test/crypto-interop/go_roundtrip_test.go`, so a re-routed or re-attributed envelope fails authentication and a conforming peer interoperates. `CryptoInteropVectorsTests` gates this against `test/crypto-interop/vectors.json`. The zero-key debug stub survives only behind `#if DEBUG` for the fake-session developer path. Inbound authenticity is enforced: with verification configured (always in production), a forged-signature or unparseable envelope is rejected outright — ack'd-and-dropped, never inserted — so a compromised relay can't even inject a placeholder row into a thread. The receiver also binds the SIGNED message id to the outer server handle: an envelope delivered under a different `id` than its signed `message_id` is rejected, so a tampering/skewed relay can't make the client store and ack a row under the wrong handle (desyncing receipts, reactions, and sender status). A rejected envelope is also **tombstoned** (`rejected_messages`) so a later reaction targeting that never-to-arrive parent is dead-lettered instead of wedging reaction catch-up behind it forever.
- Encrypted local history at rest: message bodies are never written to the on-device SQLite file in cleartext. With a Keychain wrap key present, each body is AEAD-sealed (ChaCha20-Poly1305 under a dedicated AAD) into `messages.ciphertext` while the `plaintext` column stays NULL; `MessageStore` seals on write and opens on read so the rest of the app still sees `Message.plaintext` transparently (record fetches and the raw-SQL chat-list preview alike). A different wrap key recovers nothing. This protects message *content*; row metadata (peer id, timestamps, state) stays cleartext until optional full-file SQLCipher (build flag `NESTTALK_SQLCIPHER`) is enabled. Mirrors the existing `pending_queue.plaintext_wrapped` outbox seal.
- Per-account data isolation: each enrolled identity gets its own encrypted message DB. The un-namespaced legacy DB from an early build is attributed to its real owner — recorded at app launch from the identity already enrolled, before any re-enroll can swap it — and migration **fails closed**: a legacy DB with no recorded owner, or one owned by a different account, is quarantined (the new user gets a fresh DB) rather than risk surfacing the prior account's history or queued outbox. The schema-v3 `server_id` backfill is owner-aware too: it stamps `server_id = id` only on rows whose id genuinely IS the server id (incoming messages and already-accepted outgoing ones), while an outgoing row the server never accepted is keyed by `local_id` (and its pending row tied by `message_id`) so a later retry binds the REAL server id instead of completing against a fake one. Subsequent schema migrations backfill from the matching message too — e.g. the v5 `pending_queue` columns (`original_sent_at`, `reply_to_id`) are populated for rows already queued at upgrade time, so a queued reply keeps its original ordering timestamp and reply linkage instead of being re-sent with a substituted `now()`.
- The full messaging surface is wired end-to-end: offline-send retries (`OutboxService` with device-rotation re-seal, re-pinned to the freshly-resolved device rather than the 403's stale hint; a same-user re-enrollment that rotates the LOCAL sender device id re-seals + re-signs the queued envelope under the current device instead of discarding it — gated on the persisted envelope's sender device id actually differing, so a genuinely-unauthorized 403 still settles as permanent and a recoverable one (wrapped plaintext present) is preserved; a 401 retains the durable row and retries after re-auth instead of discarding the message; the first POST and the outbox can race on the same durable row, so a late failure from the original POST is a CAS guarded on `server_id IS NULL` — it never downgrades a message the outbox already sent; the original `sent_at` and reply target are persisted and reused on every retry so ordering and reply threading survive; a permanent seal failure deletes the durable row so a message the user was told failed can never be silently re-sealed and sent by the outbox), read receipts (server acks + double-check bubble states, reconciled against `GET /messages/{id}/status` on startup and every reconnect so receipts that landed while offline aren't lost; inbound read-acks are durable — a failed POST stays `acked = 0` in `read_receipts` and is retried on reconnect/foreground/relaunch, with failures classified so one dead id can't wedge the queue: a permanent 4xx (purged/unauthorized id) is dropped, a 401 refreshes the session, and only a retryable 5xx/transport failure stops the deterministic flush), typing indicators (debounced WS frames out, live "typing…" in the thread header and chat list), and reactions (long-press picker, optimistic chips, WS sync + catch-up polling). Both message and reaction catch-up persist the **full composite cursor** `(received_at, id)` and resume from it across restarts, so a same-millisecond burst is never replayed (and can't starve newer rows behind the page cap) on the next reconnect. Reactions are authorization-scoped server-side: only a parent message's two participants may react, and only to each other, and the signed message id inside the reaction envelope must equal the parent id named on the path — a mismatch is rejected outright, so a skewed client can't get a 200 for a reaction the recipient (which binds on the signed id) would silently drop. A committed `message_id` is **immutable**: a duplicate POST is always an idempotent echo and never rewrites the stored ciphertext — and the echo is bound to the row's own sender **and** recipient first, so a user who learns a foreign message UUID can't reuse it under their own authorized-sender envelope to probe another conversation's metadata. The same ownership bind applies after the message is purged: the delivery-tombstone (410) path checks the `message_acks` row's own sender + recipient, so a foreign sender reusing a purged UUID gets `not_authorized` rather than a 410 that would confirm the id was once a real message. Ciphertext sealed for a device the recipient has rotated away from (a rare in-flight re-enroll) is simply unreadable by the new device and surfaces as an undecryptable placeholder — an inherent property of E2EE re-enrollment; the sender resends as a new message if needed. (NestTalk does not mutate delivered/committed rows to "recover" such messages — an earlier in-place rewrite path was removed because it could never be made both safe and complete: the server is zero-knowledge about decryptability, and in the common case the sender has no retry record left to re-seal anyway.)
- Session recovery: a `server_restored` event (backup restore rotates the JWT signing key and closes sockets) triggers an immediate re-handshake through `SessionRefresher.refreshNow()` (single-flight) instead of waiting out the ~hour expiry-based refresh. A client that was OFFLINE for that event recovers the same way — a 401 on the cold-launch catch-up propagates into `refreshNow()` — so it doesn't sit on a rejected token for the rest of the TTL.
- Settings (gear in the chat list): palette switcher (Auto / Daylight / Nightlight dark mode / Paper), log export (7-day merged text, no message content), app version, and device re-enroll.
- WebRTC is pinned to `stasel/WebRTC 140.0.0` — the only release line whose macOS slice ships both the headers and the `RTCMTLNSVideoView` / `RTCCameraVideoCapturer` symbols, so video render + capture work on macOS as well as iOS. Do not bump past 140 without re-checking macOS video render + capture.

## Development

### Prerequisites

- Go 1.26.1+ (server)
- Xcode 16+ — tested with Xcode 26.4.1 (Apple client)
- xcodegen 2.45+ (regenerates `apple/NestTalk.xcodeproj` from `apple/project.yml`)
- Podman (local server)

### Server

```bash
cd server
mkdir -p bin
go build -o bin/nesttalk-server ./cmd/nesttalk-server/
go build -o bin/nesttalk-cli ./cmd/cli/
go test ./...
```

### Apple client

```bash
cd apple
xcodegen generate
xcodebuild test -scheme NestTalk-macOS -destination 'platform=macOS'
xcodebuild -scheme NestTalk-macOS -destination 'platform=macOS' build
xcodebuild -scheme NestTalk-iOS -destination 'generic/platform=iOS' \
  -configuration Debug -allowProvisioningUpdates build
```

iOS-specific behavior (CallKit while locked, PushKit incoming calls, background) must be exercised on a physical device, not just Simulator.

### Convenience Makefile (server)

The repo root ships a `Makefile` with the day-to-day server targets:

```bash
make help              # list targets
make analyze           # go vet across the workspace
make test              # go test matrix
make check-interop     # cross-language envelope-vector gate
make regen-vectors     # regenerate test/crypto-interop/vectors.json
make install-hooks     # symlink scripts/pre-commit into .git/hooks
```

`make check-interop` runs the cross-language envelope-vector gate (server-side reference).

### Pre-commit hook

`scripts/pre-commit` runs `go vet ./...` on the server module when `server/` files change. Install once:

```bash
make install-hooks
```

The slower `make check-interop` is intentionally NOT in the hook — invoke it manually before pushing crypto changes.

### Container Builds

Development-only manual builds:

```bash
podman build -f deploy/Containerfile.server -t nesttalk-server .
podman build -f deploy/Containerfile.cli -t nesttalk-cli .
podman build -f deploy/Containerfile.singbox -t nesttalk-singbox deploy/
podman build -f deploy/Containerfile.coturn -t nesttalk-coturn deploy/
```

### Fresh Host Deployment

Target: a fresh **Ubuntu 24.04+** VPS (tested on 24.04 and 26.04), root access. All steps below were validated end-to-end on a clean host. Run them on the **server**; the source tree is pushed from a dev machine.

**1. Install packages (standard repo only).** Only Podman is missing on a stock Ubuntu; `envsubst` (gettext-base), `rsync`, `git`, `curl` are normally preinstalled.

```bash
apt-get update && apt-get install -y podman
# verify: podman --version ; command -v envsubst rsync
```

**2. Host firewall.** The pod binds only `:443` (sing-box) and `:22` (SSH) externally; the server (`:8080`) and coturn (`:3478`) stay pod-internal on loopback. **Production hosts run with `ufw` disabled**, relying on the cloud provider's security group for inbound filtering — simplest, and it sidesteps two Podman/ufw pitfalls:

```bash
ufw disable     # production posture. Ensure the cloud security group allows inbound 22 + 443.
```

If you must keep `ufw` **active**, both of these are required or pod containers silently lose internet/DNS — sing-box's REALITY handshake then fails (`lookup cloudflare.com: context deadline exceeded`) and clients can't enroll:

```bash
ufw allow OpenSSH && ufw allow 443/tcp
# (a) allow container egress (forwarded traffic):
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
# (b) allow pod containers to reach aardvark-dns on the host (an INPUT, not forwarded):
SUBNET=$(podman network inspect podman-default-kube-network -f '{{range .Subnets}}{{.Subnet}}{{end}}' 2>/dev/null || echo 10.89.0.0/16)
ufw allow in proto udp from "$SUBNET" to any port 53
ufw allow in proto tcp from "$SUBNET" to any port 53
ufw reload
# sanity: podman exec nesttalk-nesttalk-singbox getent hosts cloudflare.com
```

**3. Copy the source to the host** (from a dev checkout). Anchor the binary exclude so the `cmd/nesttalk-server/` dir is NOT skipped:

```bash
# from the repo root on your dev machine:
rsync -az --exclude '*.db' --exclude 'server/nesttalk-server' --exclude '.env' \
  server deploy USER@HOST:/opt/nesttalk/
```

**4. APNs VoIP push (optional).** Incoming-call-while-closed needs the app's APNs key. After the first `up.sh` run generates `deploy/.env`, set `NESTTALK_APNS_KEY_ID` + `NESTTALK_APNS_TEAM_ID` there (`TOPIC_VOIP` has a default; the server runs both sandbox and production APNs clients and routes each push by the device's signing environment automatically), and supply the `.p8` key as a **podman secret** (never committed, never a host file mount):

```bash
podman secret create nesttalk-apns-p8 deploy/.apns.p8   # AuthKey_XXXX.p8 from App Store Connect
```

`render-pod.sh` reads that podman secret and emits a `kind: Secret` doc into the (gitignored, root-only) rendered manifest — `play kube` cannot mount a pre-created podman secret directly. The pod mounts it read-only at `/etc/nesttalk/apns-key.p8`. Omit the secret (and leave `KEY_ID`/`TEAM_ID` empty) to deploy without push — the server still starts and calls work while the app is foregrounded.

**5. Deploy** (builds sing-box/coturn/server/cli from source — several minutes on a cold host):

```bash
cd /opt/nesttalk
./deploy/up.sh --server-addr YOUR_PUBLIC_IP_OR_DOMAIN:443
```

`up.sh` on first run: builds all images from source, generates `deploy/.env` (REALITY keypair + short id, API/TURN UUIDs, TURN secret, and `NESTTALK_DEBUG=1`), renders `deploy/pod.rendered.yaml`, starts the `nesttalk` pod + the local-only `nesttalk-cli` sidecar.

**6. Verify + enroll** (see *Verify Deployment* below):

```bash
podman exec nesttalk-nesttalk-server wget -qO- http://127.0.0.1:8080/api/v1/health
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock enroll <name>
```

Subsequent deploys from updated source: re-`rsync` (step 3), then `cd /opt/nesttalk && ./deploy/up.sh` (reuses `.env`; add `--skip-build` to skip the image rebuild). To regenerate the server config from scratch, remove `deploy/.env` and re-run with `--server-addr`.

**Debug logging** is on by default (`NESTTALK_DEBUG=1` → `[req] trace=<id> METHOD PATH -> STATUS`, metadata only). For a release deploy: `NESTTALK_DEBUG= ./deploy/up.sh --skip-build` (regenerates the pod with logging off), or set it empty in `deploy/.env` and re-render.

### Cleanup

```bash
chmod +x deploy/clean.sh
./deploy/clean.sh
```

Removes:
- the `nesttalk` pod
- `nesttalk-cli`
- any leftover standalone `nesttalk-server`, `nesttalk-singbox`, and `nesttalk-coturn` containers

Full reset, including generated settings, host data, and local images:

```bash
./deploy/clean.sh --all
```

Selective flags: `--with-settings`, `--with-data`, `--with-images`.

### Verify Deployment

```bash
# No public TURN ports
ss -tulpn | grep -E '3478|5349'   # should return nothing

# Only NestTalk port is 443
ss -tulpn | grep 443              # should show sing-box

# Health (server container is pod-prefixed: nesttalk-nesttalk-server)
podman exec nesttalk-nesttalk-server wget -qO- http://127.0.0.1:8080/api/v1/health

# Admin CLI (Unix-socket sidecar)
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock list-users
```

The server container does not publish `8080` on the host; under Podman's default OCI image format, image-level `HEALTHCHECK` metadata is ignored, so use the `podman exec ... /health` command above as the operator health check. Tail request logs with `podman logs -f nesttalk-nesttalk-server | grep '\[req\]'`.

## Project Structure

```
AGENTS.md              Developer / agent overview (authoritative)
CLAUDE.md              Pointer that imports AGENTS.md for Claude Code
ADMIN_GUIDE.md         Server-local admin operations guide
README.md              This file
server/
  cmd/nesttalk-server/ API server + WebSocket hub
  cmd/cli/             Admin CLI
  internal/auth/       Enrollment + device auth + sessions
  internal/roster/     Global roster and user directory
  internal/messages/   Per-device encrypted message spool
  internal/reactions/  Reactions
  internal/calls/      Call lifecycle FSM + signaling relay
  internal/keys/       Per-device message key publication
  internal/control/    Unix-socket admin RPC
  internal/backup/     Online backup / restore
  internal/push/       APNs VoIP push
  internal/ws/         WebSocket hub
  internal/storage/    SQLite + migrations
apple/
  project.yml          xcodegen config (iOS + macOS targets)
  NestTalk.xcodeproj   generated by xcodegen — gitignored
  branding/            icon.png + icon-hero.png (icon/hero sources; see scripts/render-app-icon.sh)
  NestTalk/
    Shared/            cross-platform Swift sources
      App/             AppRouter, AppState, NestTalkApp entry point
      Identity/        DeviceIdentity, KeychainBlob, KeychainWipe, EnrolledIdentityStore
      Messaging/       MessageStore (GRDB), send/receive services
      Transport/       ControlWebSocket, libbox bridge
      Crypto/          ML-KEM 768 + X25519 hybrid AEAD
      UI/              SwiftUI views (ChatList, ChatThread, Onboarding, …)
      Resources/       Hearth palette tokens, Fraunces/Inter/JetBrainsMono fonts
    iOS/               iOS-only sources (PushKit, CallKit handler, Info.plist)
    macOS/             macOS-only sources (NavigationSplitView shell)
  NestTalkTests/       XCTest unit + integration tests
  ThirdParty/
    Libbox.xcframework REALITY transport (not committed; pinned sing-box build)
    libbox-version.txt pinned upstream tag
deploy/
  Containerfile.*      Multi-stage container builds
  pod.yaml             Podman pod template (only :443 exposed)
  render-pod.sh        Renders pod.rendered.yaml from environment variables
  up.sh / clean.sh     Build + deploy / teardown
  singbox-server.json.tmpl  sing-box REALITY template (dual UUID, UUID-based routing)
  turnserver.conf      coturn template (TCP-only, pod-internal, loopback relay)
test/                  Interop vectors + e2e/transport harnesses
scripts/               Dev tooling (pre-commit hook)
```

## License

MIT for first-party NestTalk code (see `LICENSE`). The shipped Apple binary links GPL-3.0-or-later components via `Libbox.xcframework`; sideload / TestFlight / Developer-signed distribution preserves the GPL inspection-and-redistribution rights for the installing user.
