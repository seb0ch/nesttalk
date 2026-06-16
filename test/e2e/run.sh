#!/usr/bin/env bash
# NestTalk v0.2.1 Podman pod smoke test.
#
# Brings up the full production pod via deploy/up.sh, then starts a host-side
# sing-box client loopback that connects back to the pod's REALITY ingress.
# The smoke confirms /api/v1/health over that loopback path and exercises only
# the admin CLI surface that shell+curl can reach:
#
#   1. curl /api/v1/health through the client loopback
#   2. enroll <name>
#   3. list-enrollment-links
#   4. list-users
#   5. backup-to
#   6. restore-from
#   7. vacuum
#
# Authenticated device flows (connect, messages, reactions, calls, WS) stay out
# of this harness. Those are covered by Dart integration tests and Task 11's
# live macOS smoke.

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || (CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd))"
DEPLOY_DIR="${ROOT}/deploy"
UP_SCRIPT="${DEPLOY_DIR}/up.sh"

SERVER_ADDR="127.0.0.1:443"
SKIP_BUILD=0
API_LOOPBACK_PORT=62080
TURN_LOOPBACK_PORT=62180
CLIENT_CONTAINER="nesttalk-e2e-client"
SERVER_CONTAINER="nesttalk-nesttalk-server"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-addr)
      [[ $# -ge 2 ]] || { echo "E2E: --server-addr requires a value" >&2; exit 1; }
      SERVER_ADDR="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "E2E: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${NESTTALK_E2E_DATA:-}" ]]; then
  E2E_DATA="$(mktemp -d "${TMPDIR:-/tmp}/nesttalk-e2e-XXXXXX")"
  OWNS_DATA=1
else
  E2E_DATA="${NESTTALK_E2E_DATA}"
  mkdir -p "${E2E_DATA}"
  OWNS_DATA=0
fi

KEEP="${NESTTALK_E2E_KEEP:-0}"
ENV_FILE="${E2E_DATA}/e2e.env"
CLIENT_CONFIG="${E2E_DATA}/singbox-client.json"
DATA_DIR="${E2E_DATA}/data"
BACKUP_PATH="/data/e2e-backup.sqlite"

log() { echo "[e2e] $*"; }
fail() { echo "[e2e] FAIL: $*" >&2; exit 1; }

cleanup() {
  local exit_code=$?
  if [[ "${KEEP}" != "1" ]]; then
    podman rm -f "${CLIENT_CONTAINER}" >/dev/null 2>&1 || true
    podman rm -f nesttalk-cli >/dev/null 2>&1 || true
    podman pod rm -f nesttalk >/dev/null 2>&1 || true
    if [[ "${OWNS_DATA}" == "1" ]]; then
      rm -rf "${E2E_DATA}"
    fi
  else
    log "NESTTALK_E2E_KEEP=1: preserving data in ${E2E_DATA}"
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

load_env() {
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

write_client_config() {
  cat > "${CLIENT_CONFIG}" <<EOF
{
  "log": {
    "level": "warn",
    "output": "stderr"
  },
  "inbounds": [
    {
      "type": "direct",
      "tag": "api-in",
      "listen": "127.0.0.1",
      "listen_port": ${API_LOOPBACK_PORT},
      "network": "tcp"
    },
    {
      "type": "direct",
      "tag": "turn-in",
      "listen": "127.0.0.1",
      "listen_port": ${TURN_LOOPBACK_PORT},
      "network": "tcp"
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "api-out",
      "server": "${REALITY_SERVER_ADDR%%:*}",
      "server_port": ${REALITY_SERVER_ADDR##*:},
      "uuid": "${REALITY_API_UUID}",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBLIC_KEY}",
          "short_id": "${REALITY_SHORT_ID}"
        }
      }
    },
    {
      "type": "vless",
      "tag": "turn-out",
      "server": "${REALITY_SERVER_ADDR%%:*}",
      "server_port": ${REALITY_SERVER_ADDR##*:},
      "uuid": "${REALITY_TURN_UUID}",
      "flow": "xtls-rprx-vision",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBLIC_KEY}",
          "short_id": "${REALITY_SHORT_ID}"
        }
      }
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["api-in"],
        "action": "route",
        "outbound": "api-out"
      },
      {
        "inbound": ["turn-in"],
        "action": "route",
        "outbound": "turn-out"
      }
    ]
  }
}
EOF
}

wait_for_loopback() {
  local deadline shell_deadline
  shell_deadline=$(( $(date +%s) + 90 ))
  while true; do
    if curl -fsS "http://127.0.0.1:${API_LOOPBACK_PORT}/api/v1/health" >/dev/null 2>&1; then
      break
    fi
    if [[ "$(date +%s)" -ge "${shell_deadline}" ]]; then
      fail "REALITY loopback did not become healthy within 90 seconds"
    fi
    sleep 2
  done
}

cli() {
  podman exec nesttalk-cli nesttalk-cli --socket /var/run/nesttalk/control.sock "$@"
}

assert_invite_transport_bundle() {
  local invite_url="$1"
  python3 - "$invite_url" <<'PY'
import base64
import json
import sys
import urllib.parse
import zlib

invite = sys.argv[1].strip()
if not invite:
    raise SystemExit("empty invite URL")

parsed = urllib.parse.urlparse(invite)
segments = [segment for segment in parsed.path.split("/") if segment]
blob = ""
if len(segments) >= 2 and segments[0] == "i":
    blob = segments[1]
else:
    blob = urllib.parse.parse_qs(parsed.query).get("data", [""])[0]
if not blob:
    raise SystemExit(f"invite missing data blob: {invite}")

padding = "=" * (-len(blob) % 4)
raw = base64.urlsafe_b64decode(blob + padding)
try:
    raw = zlib.decompress(raw)
except zlib.error:
    pass

payload = json.loads(raw.decode("utf-8"))
transport = payload.get("transport") or {}
required = [
    "server_addr",
    "public_key",
    "short_id",
    "api_uuid",
    "turn_uuid",
]
missing = [name for name in required if not transport.get(name)]
if transport.get("kind") != "reality":
    raise SystemExit(f"invite transport kind was not reality: {transport!r}")
if missing:
    raise SystemExit(
        "invite transport bundle was incomplete; missing: " + ", ".join(missing)
    )
PY
}

log "Bringing up the full NestTalk pod via deploy/up.sh..."
mkdir -p "${DATA_DIR}"
export NESTTALK_ENV_FILE="${ENV_FILE}"
export NESTTALK_SKIP_BUILD="${SKIP_BUILD}"
up_args=(--server-addr "${SERVER_ADDR}" --data-dir "${DATA_DIR}")
if [[ "${SKIP_BUILD}" -eq 1 ]]; then
  up_args+=(--skip-build)
fi
"${UP_SCRIPT}" "${up_args[@]}"
load_env

log "Starting host-side sing-box client loopback..."
write_client_config
podman rm -f "${CLIENT_CONTAINER}" >/dev/null 2>&1 || true
podman run -d --name "${CLIENT_CONTAINER}" --network host \
  --entrypoint sing-box \
  -v "${CLIENT_CONFIG}:/tmp/singbox-client.json:ro" \
  localhost/nesttalk-singbox:latest \
  run -c /tmp/singbox-client.json >/dev/null

log "Waiting for /api/v1/health through the REALITY loopback..."
wait_for_loopback
HEALTH_JSON="$(curl -fsS "http://127.0.0.1:${API_LOOPBACK_PORT}/api/v1/health")"
log "  health: ${HEALTH_JSON}"

log "Step 1: enroll user 'e2e-alice'..."
ENROLL_OUT="$(cli enroll e2e-alice 2>&1)"
log "  ${ENROLL_OUT}"
echo "${ENROLL_OUT}" | grep -q "Code:" || fail "enroll did not emit a Code"
INVITE_URL="$(printf '%s\n' "${ENROLL_OUT}" | sed -n 's/^Invite URL: //p')"
[[ -n "${INVITE_URL}" ]] || fail "enroll did not emit an Invite URL"
assert_invite_transport_bundle "${INVITE_URL}" \
  || fail "enroll emitted an invite without a usable REALITY transport bundle"

log "Step 2: list enrollment links..."
LINKS_OUT="$(cli list-enrollment-links 2>&1)"
log "  ${LINKS_OUT}"
echo "${LINKS_OUT}" | grep -q "e2e-alice" || fail "enrollment link missing from list"

log "Step 3: list users..."
USERS_OUT="$(cli list-users 2>&1)"
log "  ${USERS_OUT}"

log "Step 4: backup live DB..."
podman exec "${SERVER_CONTAINER}" rm -f "${BACKUP_PATH}" >/dev/null 2>&1 || true
BACKUP_OUT="$(cli backup-to --to "${BACKUP_PATH}" 2>&1)"
log "  ${BACKUP_OUT}"
echo "${BACKUP_OUT}" | grep -q "Backup written to" || fail "backup-to failed"

log "Step 5: restore from the backup snapshot..."
RESTORE_OUT="$(cli restore-from --from "${BACKUP_PATH}" 2>&1)"
log "  ${RESTORE_OUT}"
echo "${RESTORE_OUT}" | grep -q "Restore complete" || fail "restore-from failed"

log "Step 6: vacuum..."
VAC_OUT="$(cli vacuum 2>&1)"
log "  ${VAC_OUT}"
echo "${VAC_OUT}" | grep -qi "VACUUM complete" || fail "vacuum did not complete successfully"

log "Final /health through the REALITY loopback..."
curl -fsS "http://127.0.0.1:${API_LOOPBACK_PORT}/api/v1/health" >/dev/null \
  || fail "final /health check via REALITY loopback failed"

log "E2E smoke completed successfully."
