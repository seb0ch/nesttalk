# NestTalk E2E Smoke Test

`test/e2e/run.sh` is the full Podman-pod smoke runner for NestTalk v0.2.1.

## What it tests

The harness now uses the real production launch path:

1. `deploy/up.sh` builds and starts the full pod: `nesttalk-nesttalk-server`, `nesttalk-nesttalk-singbox`, `nesttalk-nesttalk-coturn`, plus the isolated `nesttalk-cli` sidecar.
2. A host-side sing-box client loopback is started from the same pinned image.
3. `curl http://127.0.0.1:62080/api/v1/health` succeeds through that loopback, which proves the REALITY ingress path is live end-to-end.
4. The admin CLI surface is exercised over the shared Unix socket at `/var/run/nesttalk/control.sock`:
   - `enroll <name>`
   - `list-enrollment-links`
   - `list-users`
   - `backup-to --to ...`
   - `restore-from --from ...`
   - `vacuum`

This harness intentionally stops there. It does **not** attempt authenticated
device flows, WebSocket messaging, reactions, typing, or calls. Those remain in:

- Dart unit/widget/integration coverage for the production wiring
- Task 11 live smoke with real macOS clients

## Running it

Run it on the `nesttalk` host or any Linux machine with Podman and host-network
containers available:

```bash
./test/e2e/run.sh
```

Override the REALITY server address if needed:

```bash
./test/e2e/run.sh --server-addr 203.0.113.10:443
```

Reuse the prior build and temp env/data:

```bash
NESTTALK_E2E_DATA=/tmp/nesttalk-e2e ./test/e2e/run.sh --skip-build
```

Keep the pod and loopback client running for inspection:

```bash
NESTTALK_E2E_KEEP=1 ./test/e2e/run.sh
```

## CI

The CI job runs this harness only on `push` to `main`, after the split server,
client, and interop jobs have passed. The e2e job also enables unprivileged
low ports before starting the pod so the production `:443` binding works on the
GitHub runner.

## Out of Scope

- Device enrollment completion
- Authenticated messaging / WS status / reactions / calls
- Physical iPhone / iPad smoke
- Any manual operator drill better captured in Task 11's release-smoke doc
