#!/usr/bin/env bash
set -euo pipefail
export ETCHER_SERVER_ADDRESS=127.0.0.1
# Etcher waits for this marker before connecting to its privileged writer.
printf '%s\n' 'AUTHENTICATION SUCCEEDED'
exec "$(dirname -- "$0")/etcher-util" "$@"
