#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE=${NESTTALK_ENV_FILE:-"$SCRIPT_DIR/.env"}
PODMAN=${PODMAN:-podman}

WITH_SETTINGS=0
WITH_DATA=0
WITH_IMAGES=0

usage() {
  cat <<'EOF'
Usage:
  ./deploy/clean.sh [--with-settings] [--with-data] [--with-images] [--all]

Behavior:
  - always removes NestTalk pods/containers:
    - nesttalk
    - nesttalk-spike
    - nesttalk-cli
    - nesttalk-server / nesttalk-singbox / nesttalk-coturn (if left standalone)
  - optionally removes generated deployment settings, host data, and local images

Options:
  --with-settings   remove deploy/.env and deploy/pod.rendered.yaml
  --with-data       remove the host data directory from NESTTALK_DATA_DIR
  --with-images     remove localhost/nesttalk-* images
  --all             remove settings, data, and images
  -h, --help        show this help
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-settings)
      WITH_SETTINGS=1
      shift
      ;;
    --with-data)
      WITH_DATA=1
      shift
      ;;
    --with-images)
      WITH_IMAGES=1
      shift
      ;;
    --all)
      WITH_SETTINGS=1
      WITH_DATA=1
      WITH_IMAGES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

command -v "$PODMAN" >/dev/null 2>&1 || die "podman is required"

DATA_DIR="/opt/nesttalk/data"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
  if [ -n "${NESTTALK_DATA_DIR:-}" ]; then
    DATA_DIR=$NESTTALK_DATA_DIR
  fi
fi

remove_container() {
  name=$1
  "$PODMAN" rm -f "$name" >/dev/null 2>&1 || true
}

remove_pod() {
  name=$1
  "$PODMAN" pod rm -f "$name" >/dev/null 2>&1 || true
}

remove_pod nesttalk
remove_pod nesttalk-spike

remove_container nesttalk-cli
remove_container nesttalk-server
remove_container nesttalk-singbox
remove_container nesttalk-coturn
# Legacy v0.1 names — keep cleaning up for users upgrading from older deployments.
remove_container nesttalk-api
remove_container nesttalk-xray

if [ "$WITH_SETTINGS" -eq 1 ]; then
  rm -f "$SCRIPT_DIR/pod.rendered.yaml"
  rm -f "$ENV_FILE"
fi

if [ "$WITH_DATA" -eq 1 ]; then
  case "$DATA_DIR" in
    ""|"/"|".")
      die "refusing to remove unsafe data dir: $DATA_DIR"
      ;;
  esac
  rm -rf "$DATA_DIR"
fi

if [ "$WITH_IMAGES" -eq 1 ]; then
  "$PODMAN" rmi -f \
    localhost/nesttalk-server:latest \
    localhost/nesttalk-cli:latest \
    localhost/nesttalk-singbox:latest \
    localhost/nesttalk-coturn:latest \
    localhost/nesttalk-api:latest \
    localhost/nesttalk-xray:latest \
    >/dev/null 2>&1 || true
fi

echo
echo "NestTalk cleanup complete."
echo "Removed pods/containers: nesttalk, nesttalk-spike, nesttalk-cli, nesttalk-server, nesttalk-singbox, nesttalk-coturn (plus legacy nesttalk-api/nesttalk-xray)"
if [ "$WITH_SETTINGS" -eq 1 ]; then
  echo "Removed generated settings: $ENV_FILE and deploy/pod.rendered.yaml"
fi
if [ "$WITH_DATA" -eq 1 ]; then
  echo "Removed data directory: $DATA_DIR"
fi
if [ "$WITH_IMAGES" -eq 1 ]; then
  echo "Removed local NestTalk images"
fi
