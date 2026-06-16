# AGENTS.md

Guidance for AI agents (Claude Code, Codex, …) and developers working in this
repository. Claude Code reads this via `CLAUDE.md`; Codex and other tools read
`AGENTS.md` directly — one source of truth for both.

## Project Overview

NestTalk is a private, family-first 1:1 messenger: end-to-end encrypted
messages and audio/video calls, a zero-knowledge server, and camouflaged
transport for restricted networks. The client is a native Swift/SwiftUI app for
iOS, iPadOS, and macOS (under `apple/`); the backend is a Go server deployed as
a Podman pod with a sing-box REALITY ingress and a coturn relay.

## Distribution

**Not the App Store.** Distribution is via:
- Apple Developer-signed direct builds (notarized `.app` / IPA)
- TestFlight beta (90-day rotation for family)
- AltStore / sideload for macOS

This keeps the GPL-3 transport dependency (libbox / sing-box) acceptable in the
shipped binary while first-party code stays MIT.

## Version Baselines

(Dependency/toolchain versions — the product itself is unversioned in docs.)

- **Swift**: 5.9+ (Xcode 16+ toolchain)
- **Xcode**: 16+ (Xcode 16 toolchain or newer)
- **Apple deployment target**: iOS 26.0 / macOS 26.0. Pinned because the
  production hybrid crypto uses CryptoKit's `MLKEM768` (ML-KEM-768), an
  iOS 26 / macOS 26 API — the messaging stack cannot start on older OS, so the
  app must not advertise a lower minimum.
- **Go (server)**: 1.26.1
- **Container base**: Alpine 3.23 (pinned to a minor tag, never floating `:latest`)
- **Host OS**: Ubuntu Server 24.04 LTS
- **Containers**: Podman (not Docker)
- **WebRTC**: `stasel/WebRTC` pinned at 140.0.0 (the only line whose macOS slice
  ships the headers plus `RTCMTLNSVideoView` / `RTCCameraVideoCapturer`). Do not
  bump without re-checking macOS video render + capture.

## Build Policy

- All server-side binaries (first-party and third-party like sing-box and
  coturn) build from source in multi-stage containers from pinned upstream
  tags/commits. No pre-compiled container images.
- The Apple client bundles a pre-built `Libbox.xcframework` under
  `apple/ThirdParty/` — NOT committed (~468 MB; gitignored), version pinned via
  `libbox-version.txt`. Do not auto-upgrade without a documented decision.
- Alpine 3.23 as the default base image for server/infra; document every
  exception.

## Architecture

**Server (Go):** Minimal client-facing REST API + WebSocket. Packages split
into: auth, roster, messages, reactions, calls, keys, control, backup, push,
trace, storage, ws. Database is server-owned SQLite with a single-writer model;
CLI admin operations go through a Unix-socket RPC surface.

**Admin:** CLI-only, executed via `podman exec <cli-container> <command>`. No
admin endpoints are ever network-exposed. The CLI sidecar runs outside the
server pod with `--network none`; it reaches the server via a shared volume
mount of the Unix socket.

**Apple Client (Swift/SwiftUI):** iOS, iPadOS, macOS targets in a single Xcode
project under `apple/`. Transport is `Libbox.xcframework` on all three platforms
(command-server mode on a localhost TCP port). Device identity uses CryptoKit
Ed25519 keys persisted in the Keychain. Local message history is stored in GRDB
(SQLite) with message bodies AEAD-sealed at rest. Calls use WebRTC.framework
directly, with CallKit + PushKit VoIP integration for incoming-call-while-app-
closed.

**Android:** a separate native client is out of scope for this repository.

**Infrastructure:**
- sing-box REALITY — camouflaged ingress (default target `cloudflare.com:443`,
  configurable)
- coturn — TURN relay for media (relay-only, no direct ICE candidates)
- Control signaling via WebSocket (`/api/v1/ws/control`)

## Client API (20 REST + 1 WebSocket)

Auth:
- `POST /api/v1/auth/enroll/start`
- `POST /api/v1/auth/enroll/complete`
- `POST /api/v1/auth/connect/challenge`
- `POST /api/v1/auth/connect/complete`

Roster:
- `GET /api/v1/roster`

Messages:
- `POST /api/v1/messages`
- `GET /api/v1/messages/pending`
- `POST /api/v1/messages/{id}/ack`
- `GET /api/v1/messages/{id}/status`

Reactions:
- `PUT /api/v1/messages/{id}/reactions`
- `GET /api/v1/reactions/since`

Calls:
- `POST /api/v1/calls`
- `POST /api/v1/calls/{id}/accept`
- `POST /api/v1/calls/{id}/decline`
- `POST /api/v1/calls/{id}/cancel`
- `POST /api/v1/calls/{id}/end`

Relay:
- `GET /api/v1/relay/session`

Keys:
- `GET /api/v1/keys/message/{userId}`

Devices:
- `POST /api/v1/devices/push-token`

Health:
- `GET /api/v1/health`

Signaling:
- `WS /api/v1/ws/control`

Invite scheme: `nesttalk://i/<base64url(zlib(JSON))>`.

## Key Constraints

- No group chats or group calls (1:1 only)
- No permanent message/call storage on server; the offline spool expires after a
  configurable TTL (default 30 days)
- Server stores only ciphertext envelopes — message content is never plaintext
  server-side
- Admin-issued enrollment; all enrolled non-revoked users appear in the roster
  automatically
- One active device per user; re-enroll revokes the prior device
- Reinstall or secure-storage loss creates a new device identity requiring a
  fresh admin-issued enrollment link (`enroll-existing`)
- Apple-first; a native Android client would be a separate codebase
- No App Store. Sideload / TestFlight / Developer-signed direct builds only.

## Testing

- Use `testify` for all Go tests (never stdlib-only assertions).
- Apple client tests: XCTest for the model/service layer. Run via
  `xcodebuild test -scheme NestTalk-macOS -destination 'platform=macOS'`.
- Before marking client work complete, build and run at minimum the macOS
  target: `xcodebuild -scheme NestTalk-macOS -destination 'platform=macOS' build`
  and launch the resulting `.app`. Where iOS-specific behavior matters (CallKit,
  PushKit, background), test on a physical device, not just the Simulator.
- Run the server locally for dev/test with Podman: `./deploy/up.sh` (see
  `README.md`).

## Repository Structure

```
apple/                         # Swift/SwiftUI client
  project.yml                  # xcodegen config (iOS + macOS targets)
  NestTalk.xcodeproj           # generated by xcodegen — gitignored
  branding/                    # icon.png + icon-hero.png (icon/hero sources)
  scripts/render-app-icon.sh   # regenerates the app icon + hero asset sets
  NestTalk/                    # app sources
    Shared/                    # code shared across iOS + macOS
    iOS/                       # iOS/iPadOS-only sources
    macOS/                     # macOS-only sources
  NestTalkTests/               # XCTest unit + integration tests
  ThirdParty/
    Libbox.xcframework         # REALITY transport (not committed; pinned)
    libbox-version.txt
server/                        # Go server
  cmd/nesttalk-server/         # API server + WebSocket hub
  cmd/cli/                     # Admin CLI
  internal/                    # auth, roster, messages, reactions, calls, keys,
                               # control, backup, storage, ws, push, …
deploy/                        # Podman pod template, sing-box/coturn configs,
                               # render-pod.sh, up.sh, clean.sh
test/                          # interop vectors + e2e/transport harnesses
scripts/                       # dev tooling (pre-commit hook)
```

## Visual Identity

The icon/hero source images live under `apple/branding/` (`icon.png`,
`icon-hero.png`); `apple/scripts/render-app-icon.sh` regenerates the app icon
and welcome-hero asset sets from them. The "Hearth" design language lives in the
client: palette tokens and fonts (Fraunces serif for headlines/names, Inter for
UI/body, JetBrains Mono for small/debug tags) ship in-bundle under
`apple/NestTalk/Shared/Resources/` (no runtime font download), and the SwiftUI
component primitives + screens live under `apple/NestTalk/Shared/UI/`. Tone:
calm, safe, family-friendly — let the icon tell the security story rather than
repeating it in text.

## Admin CLI Subcommands

All commands except `emergency-shell` route through Unix-socket RPC
(`control.Server.Dispatch`); `emergency-shell` bypasses the socket and opens a
raw sqlite3 shell directly:

| Subcommand | RPC | Notes |
|-----------|-----|-------|
| `enroll <name>` | `enroll_user` | Issues new enrollment link |
| `enroll-existing --user <id>` | `enroll_existing_user` | Re-enroll existing user |
| `revoke <user_id>` | `revoke_user` | Revoke user + active device |
| `revoke-device <device_id>` | `revoke_device` | Revoke specific device |
| `list-users` | `list_users` | All users including revoked |
| `list-enrollment-links` | `list_enrollment_links` | Outstanding links |
| `reconcile-device --pubkey <hex>` | `reconcile_device` | Look up device by pubkey |
| `reload-config` | `reload_config` | Hot-reload server config |
| `backup-to --to <path>` | `backup_to` | Online `VACUUM INTO` snapshot |
| `restore-from --from <path>` | `restore_from` | DESTRUCTIVE: swap live DB |
| `list-recent-calls` | `list_recent_calls` | Paginated call history |
| `vacuum` | `vacuum` | SQLite `VACUUM` (back up first!) |
| `emergency-shell` | (none — bypasses socket) | Last-resort sqlite3 shell |

## Licensing

- First-party NestTalk code is MIT (see `LICENSE`).
- The shipped Apple binary links GPL-3.0-or-later components (`Libbox.xcframework`
  → sing-box). Because distribution is sideload / TestFlight / Developer-signed
  builds (not the App Store), GPL-3 on the final binary is acceptable: the
  installing user retains the redistribution/inspection rights GPL requires. App
  Store distribution would require replacing the transport.

## Checks before pushing

There are no committed CI workflows; run the gates locally:

- `make analyze` / `go vet ./...` — server static analysis
- `go test ./...` (from `server/`) — server tests
- `xcodebuild test -scheme NestTalk-macOS -destination 'platform=macOS'` — Apple
  client tests
- `make check-interop` — cross-language envelope-vector gate (run before crypto
  changes; `make install-hooks` installs the `go vet` pre-commit hook)
