# NestTalk Admin Guide

Day-to-day server administration. All admin actions are **CLI-only** and run
server-locally — there are no admin HTTP endpoints, and nothing here is
reachable over the network. Every command but the last-resort `emergency-shell`
(which opens a raw sqlite3 shell directly) talks to the server over a
Unix-socket sidecar.

## CLI pattern

The admin CLI runs inside the `nesttalk-cli` sidecar container and talks to the
server over the control socket (`/var/run/nesttalk/control.sock`):

```bash
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock <command> [flags]
```

`--socket` defaults to `/var/run/nesttalk/control.sock`, so it can be omitted
when the default mount is used. The full command set:

| Command | Purpose |
|---|---|
| `enroll <name>` | Issue a new-user enrollment link |
| `enroll-existing --user <user_id>` | Issue a re-enrollment link for an existing user |
| `revoke <user_id>` | Revoke a user and their active device |
| `revoke-device <device_id>` | Revoke one device without revoking the user |
| `list-users` | List every user (enrolled and revoked) |
| `list-enrollment-links [--include-used]` | List outstanding (and optionally consumed) links |
| `reconcile-device --pubkey <hex>` | Look up a device by its Ed25519 fingerprint |
| `reload-config` | Tell the server to reload its on-disk configuration |
| `list-recent-calls [--limit N]` | List recent calls (newest first; default 50, max 500) |
| `backup-to --to <path>` | Take an online SQLite snapshot |
| `restore-from --from <path>` | **DESTRUCTIVE**: replace the live DB with a backup |
| `vacuum` | Run SQLite `VACUUM` against the live DB (online, blocking) |
| `emergency-shell` | DANGER: open a raw sqlite3 shell (daemon must be stopped) |

The server container is `nesttalk-nesttalk-server`; the CLI sidecar is
`nesttalk-cli`.

## User & device model

- **Admin-issued enrollment.** There is no self-signup and **no pending /
  approve / reject flow**. You issue an enrollment link; the user opens it in
  the app to enroll. Every enrolled, non-revoked user appears in every other
  user's roster automatically.
- **One active device per user.** Enrolling (or re-enrolling) a user installs a
  new active device and revokes the prior one. A reinstall or secure-storage
  loss produces a new device identity that needs a fresh enrollment link.
- **Enrollment links are one-time and short-lived** (consumed on completion;
  they also expire). Re-issue if a link is lost or expired.

### Add a new family member

```bash
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock enroll alice
```

Prints an invite URL (`nesttalk://i/…`). Share it with the user over a secure
channel; they paste/scan it in the app. Confirm with `list-users`.

### Re-enroll an existing user (new phone, reinstall, lost device)

```bash
# Find the user_id:
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock list-users
# Issue a re-enrollment link (revokes the prior device on completion):
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock enroll-existing --user <user_id>
```

### Revoke

```bash
# Revoke a user entirely (and their active device):
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock revoke <user_id>
# Revoke a single device, keeping the user:
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock revoke-device <device_id>
```

Revocation severs the device's live control socket immediately (it can no longer
send messages, typing, or call signaling).

### Look up a device by fingerprint

```bash
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock reconcile-device --pubkey <hex-ed25519-pubkey>
```

Returns `device_id`, `user_id`, and `revoked_at` (if revoked) — useful when a
user reports trouble and you only have the device key.

## Messaging / calls model

- 1:1 only — no group chats or group calls.
- The server stores only **ciphertext envelopes**; message content is never
  plaintext server-side. The offline spool expires after a configurable TTL
  (default 30 days).
- Calls are relayed media only (coturn), signalled over the control WebSocket.
  Inspect recent calls with `list-recent-calls`.

## Server configuration

Configuration is file-driven. After editing the server's on-disk config, apply
it without a restart:

```bash
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock reload-config
```

## Backup and restore

The database lives on the host data volume (`$NESTTALK_DATA_DIR`, default
`/opt/nesttalk/data`), mounted into the server container at `/data`
(`/data/nesttalk.db`). Write snapshots **under `/data`** so they land on the
host volume and survive pod recreation:

```bash
# Online, non-destructive snapshot (VACUUM INTO under the hood):
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock \
  backup-to --to /data/backups/nesttalk-$(date -u +%Y-%m-%dT%H%M).db
# -> appears on the host at /opt/nesttalk/data/backups/
```

```bash
# DESTRUCTIVE restore (swaps the live DB; forces both clients to re-handshake):
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock \
  restore-from --from /data/backups/<snapshot>.db
```

A backup restore rotates the server's JWT signing key and closes live sockets;
clients re-handshake automatically.

### Backup cadence

Run a daily snapshot from cron on the host and prune old files:

```cron
# Daily at 03:00 UTC
0 3 * * * podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock backup-to --to /data/backups/nesttalk-$(date -u +\%Y-\%m-\%d).db
```

```bash
# Keep the last 14 daily backups (run from cron too):
ls -1t /opt/nesttalk/data/backups/nesttalk-*.db | tail -n +15 | xargs -r rm --
```

## VACUUM

SQLite does not reclaim deleted-row space automatically; run `VACUUM`
periodically if the DB grows (e.g. after bulk message expiry). **Always take a
`backup-to` snapshot first** — VACUUM rewrites the whole file:

```bash
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock \
  backup-to --to /data/backups/nesttalk-prevacuum-$(date -u +%Y-%m-%dT%H%M).db
podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock vacuum
```

The server stays available during VACUUM (it blocks WAL checkpointing for the
duration). On typical family-sized databases VACUUM completes in seconds.

## SQLite encryption posture

The server's database is a standard SQLite 3 WAL database at `/data/nesttalk.db`
(no SQLCipher / in-process encryption extension). What protects data at rest:

- **Filesystem encryption.** The host data volume must sit on an encrypted
  filesystem (e.g. LUKS/dm-crypt). Operator responsibility at deploy time.
- **Ciphertext-only storage.** Message rows hold hybrid-PQC (X25519 + ML-KEM-768)
  ciphertext envelopes only — never plaintext.
- **Per-device E2EE.** Even with the DB file in hand, message content is
  decryptable only by the recipient device's private key, which lives in the
  client's Keychain and never reaches the server.

| Threat | Mitigation |
|--------|-----------|
| Physical disk theft | Host filesystem encryption (operator responsibility) |
| Message content exposure | Per-device hybrid-PQC E2EE — server sees ciphertext only |
| SQL injection | Parameterised queries throughout |
| Session-token forgery | HMAC-SHA256 JWT signed with a 32-byte server secret |

## Emergency shell (last resort)

`emergency-shell` is for when the daemon is unreachable (crashed, socket gone)
and you must inspect the DB directly. **The daemon MUST be stopped first** —
running raw sqlite3 against a live database risks corruption. It requires the
`sqlite3` binary and direct access to the DB file; the most reliable path is to
run it on the host against `/opt/nesttalk/data/nesttalk.db` with the pod
stopped:

```bash
podman pod stop nesttalk
sqlite3 /opt/nesttalk/data/nesttalk.db    # install sqlite3 on the host if absent
# …inspect / repair, then:
podman pod start nesttalk
```

## APNs VoIP push (optional)

Incoming-call-while-the-app-is-closed needs the app's APNs auth key so the
server can wake iOS CallKit on the lock screen. The key is supplied as a
**podman secret**, never a committed file or host mount:

```bash
# AuthKey_XXXX.p8 from developer.apple.com (Keys → APNs).
podman secret create nesttalk-apns-p8 deploy/.apns.p8
```

Set the APNs vars in `deploy/.env` (the `.p8` itself is NOT stored there):

```sh
NESTTALK_APNS_KEY_ID=<10-char Key ID>
NESTTALK_APNS_TEAM_ID=<Apple Team ID>
NESTTALK_APNS_TOPIC_VOIP=com.nesttalk.ios.voip
```

`render-pod.sh` reads the podman secret and materialises it into the (gitignored,
root-only) rendered manifest; the pod mounts it read-only at
`/etc/nesttalk/apns-key.p8`. Re-render and redeploy (`./deploy/up.sh`), then:

```bash
podman logs nesttalk-nesttalk-server | grep -i apns   # expect APNs enabled
```

With any APNs var missing (or no secret), the server logs `APNs client disabled`
and runs without push — calls still work while the app is foregrounded. A token
APNs reports permanently dead (`410 Unregistered`, `BadDeviceToken`, topic
mismatch) is cleared automatically; the client re-registers on next launch.

The server builds **both** the sandbox and production APNs clients and routes
each push by the device token's signing environment automatically — there is no
endpoint to configure. (A token must still match the build that registered it;
a mismatch surfaces as `BadEnvironmentKeyInToken` and the stale token is cleared.)

## Licensing / distribution posture

- First-party NestTalk code is MIT (`LICENSE`).
- The shipped Apple binary links GPL-3.0-or-later components via the in-bundle
  `Libbox.xcframework` (sing-box) on both iOS and macOS, so the final binary is
  a GPL-3 combined work for distribution.
- This is acceptable **only** because distribution is sideload / TestFlight /
  Developer-signed — not the App Store — which preserves the installing user's
  GPL inspection/redistribution rights. App Store distribution would require
  replacing the transport.

## Troubleshooting

**User can't enroll / link rejected (HTTP 410).** The enrollment link was
already consumed or has expired. Issue a fresh one (`enroll` for a new user,
`enroll-existing --user <id>` for an existing one).

**User isn't in someone's roster.** Confirm they completed enrollment
(`list-users` shows them `active`, not just an outstanding link in
`list-enrollment-links`). The roster is automatic for enrolled, non-revoked
users.

**User on a new phone / reinstall.** A reinstall is a new device identity —
re-enroll with `enroll-existing --user <id>`; the prior device is revoked on
completion.

**Calls connect but the peer's hang-up/force-quit doesn't drop the call fast.**
The surviving side tears down on sustained media loss (ICE) after a short
grace; abrupt termination has no clean `/end`, so this is expected.

**Verify the deployment is locked down.** Only `:443` should be externally
reachable:

```bash
ss -tulpn | grep -E '3478|5349'   # TURN ports — must be empty
ss -tulpn | grep 443              # only sing-box
podman exec nesttalk-nesttalk-server wget -qO- http://127.0.0.1:8080/api/v1/health
```
