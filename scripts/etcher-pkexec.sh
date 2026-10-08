#!/usr/bin/env bash
set -euo pipefail

# Parse the one command produced by Etcher 2.1.7, without evaluating shell text.
prefix='echo AUTHENTICATION SUCCEEDED && /app/etcher/resources/etcher-util '
if [ "$#" -ne 4 ] || [ "$1" != '--disable-internal-agent' ] ||
  [ "$2" != '/bin/bash' ] || [ "$3" != '-c' ] || [[ "$4" != "$prefix"* ]] || [[ "$4" == *$'\n'* ]]; then
  echo 'Unsupported Etcher elevation request' >&2
  exit 2
fi
read -r -a writer_arguments <<< "${4#"$prefix"}"
if [ "${#writer_arguments[@]}" -eq 0 ]; then
  echo 'Missing Etcher writer arguments' >&2
  exit 2
fi
for argument in "${writer_arguments[@]}"; do
  if [[ ! "$argument" =~ ^--(ETCHER_SERVER_ADDRESS|ETCHER_SERVER_PORT|ETCHER_SERVER_ID|ETCHER_NO_SPAWN_UTIL|ETCHER_TERMINATE_TIMEOUT|UV_THREADPOOL_SIZE)=[a-zA-Z0-9._:-]+$ ]]; then
    echo 'Unsupported Etcher writer argument' >&2
    exit 2
  fi
  if [[ "$argument" == --ETCHER_SERVER_ADDRESS=* ]] && [ "$argument" != '--ETCHER_SERVER_ADDRESS=127.0.0.1' ]; then
    echo 'Etcher writer must listen on localhost' >&2
    exit 2
  fi
done
if [ -z "${ETCHER_HOST_WRITER:-}" ] || [ ! -x "$ETCHER_HOST_WRITER" ]; then
  echo 'Etcher host writer is unavailable; restart the application' >&2
  exit 1
fi
if flatpak-spawn --host --watch-bus pkexec --disable-internal-agent "$ETCHER_HOST_WRITER" "${writer_arguments[@]}"; then
  exit 0
else
  status=$?
  # Upstream waits for stdout to classify a refusal. Avoid its 30 second timeout.
  printf '%s\n' 'AUTHENTICATION FAILED'
  exit "$status"
fi
