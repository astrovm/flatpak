#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/app/etcher/resources" "$work/app/libexec" "$work/app/ventoy" "$work/cache with spaces" "$work/config"
export XDG_CACHE_HOME="$work/cache with spaces"
export XDG_CONFIG_HOME="$work/config"
export XDG_DATA_HOME="$work/data"
export CALLS=$work/calls
export PATH="$work/bin:$PATH"
export MOCK_APP_DIRECTORY=$work/app

cat > "$work/bin/cp" <<'MOCK'
#!/usr/bin/env bash
arguments=()
for argument in "$@"; do
  arguments+=("${argument/#\/app\//$MOCK_APP_DIRECTORY/}")
done
exec /bin/cp "${arguments[@]}"
MOCK
cat > "$work/bin/dirname" <<'MOCK'
#!/usr/bin/env bash
case "${!#}" in
  */scripts/etcher-host-writer.sh) echo "$MOCK_APP_DIRECTORY/etcher/resources" ;;
  *) exec /usr/bin/dirname "$@" ;;
esac
MOCK

cat > "$work/bin/flatpak-spawn" <<'MOCK'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in
    */VentoyGUI.*) test -x "$argument" || exit 127 ;;
  esac
done
printf '%s\n' "$@" > "$CALLS"
exit "${MOCK_STATUS:-0}"
MOCK
cat > "$work/bin/uname" <<'MOCK'
#!/usr/bin/env bash
echo "${MOCK_ARCH:-x86_64}"
MOCK
cat > "$work/bin/zypak-wrapper" <<'MOCK'
#!/usr/bin/env bash
test -z "${ELECTRON_RUN_AS_NODE:-}"
test -z "${APPIMAGE:-}"
test -z "${APPDIR:-}"
test -z "${ARGV0:-}"
test "$HOME" = "$XDG_DATA_HOME"
test -w "$HOME"
test -x "$ETCHER_HOST_WRITER"
test -x "$(dirname -- "$ETCHER_HOST_WRITER")/etcher-util"
printf '%s\n' "$@" > "$CALLS"
exit "${MOCK_STATUS:-0}"
MOCK
printf '#!/usr/bin/env bash\nprintf "writer:%%s\\n" "$@"\n' > "$work/app/etcher/resources/etcher-util"
cp "$root/scripts/etcher-host-writer.sh" "$work/app/libexec/etcher-host-writer"
printf 'payload\n' > "$work/app/ventoy/data"
for architecture in x86_64 aarch64; do
  printf '#!/bin/sh\nexit 0\n' > "$work/app/ventoy/VentoyGUI.$architecture"
  chmod +x "$work/app/ventoy/VentoyGUI.$architecture"
done
chmod +x "$work/bin/"* "$work/app/etcher/resources/etcher-util"

expect_failure()
{
  if "$@" > "$work/output" 2>&1; then
    echo 'Expected command to fail' >&2
    exit 1
  fi
}
assert_clean()
{
  test -z "$(find "$XDG_CACHE_HOME" -mindepth 1 ! -path "$XDG_CACHE_HOME/ventoy" -print -quit)"
}

ELECTRON_RUN_AS_NODE=1 APPIMAGE=/another-app APPDIR=/another-dir ARGV0=/another-app bash "$root/scripts/etcher-launch.sh" 'image with spaces.img'
grep -Fxq 'image with spaces.img' "$CALLS"
assert_clean
expect_failure env MOCK_STATUS=1 bash "$root/scripts/etcher-launch.sh"
assert_clean
bash "$root/scripts/ventoy-launch.sh" 'argument with spaces'
grep -Fxq 'argument with spaces' "$CALLS"
grep -Fxq -- '--gtk3' "$CALLS"
grep -Fxq -- "--env=XDG_CONFIG_HOME=$XDG_CONFIG_HOME" "$CALLS"
assert_clean
MOCK_ARCH=aarch64 bash "$root/scripts/ventoy-launch.sh"
grep -q '/VentoyGUI.aarch64$' "$CALLS"
assert_clean
expect_failure env MOCK_ARCH=wrong bash "$root/scripts/ventoy-launch.sh"
grep -q 'Unsupported Ventoy architecture' "$work/output"
expect_failure env MOCK_STATUS=126 bash "$root/scripts/ventoy-launch.sh"
assert_clean

prefix='echo AUTHENTICATION SUCCEEDED && /app/etcher/resources/etcher-util '
request=$prefix'--ETCHER_SERVER_ADDRESS=127.0.0.1 --ETCHER_SERVER_PORT=12345 --ETCHER_SERVER_ID=test --UV_THREADPOOL_SIZE=2'
bridge=$root/scripts/etcher-pkexec.sh
export ETCHER_HOST_WRITER="$work/app/libexec/etcher-host-writer"
bash "$bridge" --disable-internal-agent /bin/bash -c "$request"
grep -Fxq "$ETCHER_HOST_WRITER" "$CALLS"
grep -Fxq -- '--ETCHER_SERVER_PORT=12345' "$CALLS"
expect_failure env MOCK_STATUS=126 bash "$bridge" --disable-internal-agent /bin/bash -c "$request"
grep -Fxq 'AUTHENTICATION FAILED' "$work/output"
expect_failure env -u ETCHER_HOST_WRITER bash "$bridge" --disable-internal-agent /bin/bash -c "$request"
expect_failure env ETCHER_HOST_WRITER=/missing bash "$bridge" --disable-internal-agent /bin/bash -c "$request"
expect_failure bash "$bridge"
expect_failure bash "$bridge" wrong /bin/bash -c "$request"
expect_failure bash "$bridge" --disable-internal-agent /bin/sh -c "$request"
expect_failure bash "$bridge" --disable-internal-agent /bin/bash wrong "$request"
expect_failure bash "$bridge" --disable-internal-agent /bin/bash -c 'echo wrong'
expect_failure bash "$bridge" --disable-internal-agent /bin/bash -c "$prefix"
expect_failure bash "$bridge" --disable-internal-agent /bin/bash -c "$request"$'\necho unexpected'
# shellcheck disable=SC2016
for argument in '--OTHER=value' '--ETCHER_SERVER_ID=emoji😀' '--ETCHER_SERVER_ID=$(touch invalid)' '--ETCHER_SERVER_ID=test;echo unexpected' '--ETCHER_SERVER_ADDRESS=0.0.0.0'; do
  expect_failure bash "$bridge" --disable-internal-agent /bin/bash -c "$prefix$argument"
done
bash "$root/scripts/etcher-host-writer.sh" 'argument with spaces' > "$work/output"
grep -Fxq 'AUTHENTICATION SUCCEEDED' "$work/output"
grep -Fxq 'writer:argument with spaces' "$work/output"
echo 'ok - launchers preserve arguments, reject malformed requests, report denied authentication and clean up'
