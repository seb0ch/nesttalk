#!/bin/sh

set -eu

: "${TURN_SECRET:?TURN_SECRET is required}"

export TURN_SECRET
export TURN_REALM="${TURN_REALM:-nesttalk}"

envsubst '${TURN_SECRET} ${TURN_REALM}' \
  < /etc/coturn/turnserver.conf.tmpl \
  > /etc/coturn/turnserver.conf

exec turnserver -c /etc/coturn/turnserver.conf
