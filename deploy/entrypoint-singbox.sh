#!/bin/sh
# Render the sing-box server config from envsubst and exec the binary.
#
# Required env (validated below):
#   REALITY_API_UUID    UUID for the API user
#   REALITY_TURN_UUID   UUID for the TURN-relay user
#   REALITY_PRIVATE_KEY REALITY private key (sing-box generate reality-keypair)
#   REALITY_SHORT_ID    REALITY short id (hex)
#
# Optional env (with defaults):
#   REALITY_DEST   default cloudflare.com:443
#   REALITY_SNI    default cloudflare.com
#   API_REDIRECT   default 127.0.0.1:8080
set -eu

: "${REALITY_API_UUID:?REALITY_API_UUID is required}"
: "${REALITY_TURN_UUID:?REALITY_TURN_UUID is required}"
: "${REALITY_PRIVATE_KEY:?REALITY_PRIVATE_KEY is required}"
: "${REALITY_SHORT_ID:?REALITY_SHORT_ID is required}"

export REALITY_API_UUID
export REALITY_TURN_UUID
export REALITY_PRIVATE_KEY
export REALITY_SHORT_ID
export REALITY_DEST="${REALITY_DEST:-cloudflare.com:443}"
export REALITY_SNI="${REALITY_SNI:-cloudflare.com}"
export API_REDIRECT="${API_REDIRECT:-127.0.0.1:8080}"

# Split REALITY_DEST into host:port for the sing-box reality.handshake block.
# IPv4 / DNS hostnames only — bracketed IPv6 ([::1]:443) is NOT supported here.
REALITY_DEST_HOST=$(printf '%s' "${REALITY_DEST}" | awk -F: '{print $1}')
REALITY_DEST_PORT=$(printf '%s' "${REALITY_DEST}" | awk -F: '{print $2}')
[ -n "${REALITY_DEST_HOST}" ] || { echo "REALITY_DEST host empty" >&2; exit 1; }
[ -n "${REALITY_DEST_PORT}" ] || { echo "REALITY_DEST port empty" >&2; exit 1; }
export REALITY_DEST_HOST REALITY_DEST_PORT

# Split API_REDIRECT into host and port for the route-rule overrides
# (POC finding: modern sing-box rejects override_address/override_port on
# direct outbounds, so we apply the destination override in the route rule).
# IPv4 / DNS hostnames only — bracketed IPv6 ([::1]:8080) is NOT supported here.
API_REDIRECT_HOST=$(printf '%s' "${API_REDIRECT}" | awk -F: '{print $1}')
API_REDIRECT_PORT=$(printf '%s' "${API_REDIRECT}" | awk -F: '{print $2}')
[ -n "${API_REDIRECT_HOST}" ] || { echo "API_REDIRECT host empty" >&2; exit 1; }
[ -n "${API_REDIRECT_PORT}" ] || { echo "API_REDIRECT port empty" >&2; exit 1; }
export API_REDIRECT_HOST API_REDIRECT_PORT

envsubst \
  '${REALITY_API_UUID} ${REALITY_TURN_UUID} ${REALITY_PRIVATE_KEY} ${REALITY_SHORT_ID} ${REALITY_DEST} ${REALITY_SNI} ${REALITY_DEST_HOST} ${REALITY_DEST_PORT} ${API_REDIRECT} ${API_REDIRECT_HOST} ${API_REDIRECT_PORT}' \
  < /etc/sing-box/config.json.tmpl \
  > /etc/sing-box/config.json

exec sing-box run -c /etc/sing-box/config.json
