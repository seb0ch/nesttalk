#!/bin/sh

set -eu

# The rendered manifest can embed secrets (APNs .p8, REALITY private key, TURN
# secret), so create everything 0600.
umask 077

required_vars="
NESTTALK_DATA_DIR
TURN_SECRET
REALITY_SERVER_ADDR
REALITY_PUBLIC_KEY
REALITY_SHORT_ID
REALITY_API_UUID
REALITY_TURN_UUID
REALITY_PRIVATE_KEY
"

for var_name in ${required_vars}; do
  eval "value=\${${var_name}:-}"
  if [ -z "${value}" ]; then
    echo "missing required environment variable: ${var_name}" >&2
    exit 1
  fi
done

export LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:8080}"
export TURN_REALM="${TURN_REALM:-nesttalk}"
export REALITY_SNI="${REALITY_SNI:-cloudflare.com}"
export REALITY_DEST="${REALITY_DEST:-cloudflare.com:443}"
export API_REDIRECT="${API_REDIRECT:-127.0.0.1:8080}"
export API_BASE_URL="${API_BASE_URL:-}"
# Per-request HTTP logging toggle (metadata only). Empty = off.
export NESTTALK_DEBUG="${NESTTALK_DEBUG:-}"

# APNs / VoIP push (optional). Values come from deploy/.env (sourced by
# up.sh before this script); empty KEY_ID/TEAM_ID render as empty env and
# main.go treats that as "feature disabled". To enable: set the APNs vars in
# deploy/.env AND supply the .p8 key as a podman secret:
#   podman secret create nesttalk-apns-p8 deploy/.apns.p8
# See ADMIN_GUIDE.md.
export NESTTALK_APNS_KEY_ID="${NESTTALK_APNS_KEY_ID:-}"
export NESTTALK_APNS_TEAM_ID="${NESTTALK_APNS_TEAM_ID:-}"
export NESTTALK_APNS_TOPIC_VOIP="${NESTTALK_APNS_TOPIC_VOIP:-}"
export NESTTALK_APNS_ENDPOINT="${NESTTALK_APNS_ENDPOINT:-}"

envsubst \
  '${API_BASE_URL} ${NESTTALK_DATA_DIR} ${TURN_SECRET} ${TURN_REALM} ${LISTEN_ADDR} ${REALITY_SERVER_ADDR} ${REALITY_PUBLIC_KEY} ${REALITY_SHORT_ID} ${REALITY_API_UUID} ${REALITY_TURN_UUID} ${REALITY_PRIVATE_KEY} ${REALITY_SNI} ${REALITY_DEST} ${API_REDIRECT} ${NESTTALK_DEBUG} ${NESTTALK_APNS_KEY_ID} ${NESTTALK_APNS_TEAM_ID} ${NESTTALK_APNS_TOPIC_VOIP} ${NESTTALK_APNS_ENDPOINT}' \
  < "$(dirname "$0")/pod.yaml" \
  > "$(dirname "$0")/pod.rendered.yaml"

# play kube cannot mount a pre-created podman secret directly — only Secret
# resources defined in the manifest. If the APNs podman secret exists, read it
# and prepend a `kind: Secret` doc so play kube materializes + mounts it. The
# rendered file is gitignored and root-only.
RENDERED="$(dirname "$0")/pod.rendered.yaml"
if podman secret inspect nesttalk-apns-p8 >/dev/null 2>&1; then
  p8_b64=$(podman secret inspect --showsecret --format '{{.SecretData}}' nesttalk-apns-p8 | base64 -w0)
  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: nesttalk-apns\ndata:\n  apns-key.p8: %s\n---\n' "$p8_b64"
    cat "$RENDERED"
  } > "$RENDERED.tmp" && mv "$RENDERED.tmp" "$RENDERED"
  echo "embedded APNs key from podman secret nesttalk-apns-p8 into rendered manifest"
fi

# Enforce restrictive perms even if pod.rendered.yaml pre-existed with a looser
# mode (umask only applies to newly-created files).
chmod 600 "$RENDERED"

echo "wrote $RENDERED"
