#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/app/bin" "$work/app/libexec" "$work/app/qtscrcpy/bin" "$work/home"
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu/GL/default/lib
export MOCK_PREFIX=$work/app
export CAPTURE=$work/capture
export HOME=$work/home
export PATH="$work/bin:$PATH"
export XDG_CONFIG_HOME="$work/config with spaces"
export XDG_DATA_HOME="$work/data ñ😀"
cat > "$work/bin/dirname" <<'MOCK'
#!/bin/sh
printf '%s/bin\n' "$MOCK_PREFIX"
MOCK
cat > "$work/app/qtscrcpy/bin/QtScrcpy" <<'MOCK'
#!/bin/sh
set -eu
test -z "${APPIMAGE:-}${APPDIR:-}${ARGV0:-}${LD_PRELOAD:-}"
test "$QT_QPA_PLATFORM" = xcb
test "$QT_PLUGIN_PATH" = "$MOCK_PREFIX/qtscrcpy/plugins"
test "$QT_QPA_PLATFORM_PLUGIN_PATH" = "$QT_PLUGIN_PATH/platforms"
test "$LD_LIBRARY_PATH" = "$MOCK_PREFIX/qtscrcpy/lib:$MOCK_PREFIX/qtscrcpy/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu/GL/default/lib"
test "$QTSCRCPY_ADB_PATH" = "$MOCK_PREFIX/bin/adb"
test "$QTSCRCPY_SERVER_PATH" = "$MOCK_PREFIX/qtscrcpy/lib/qtscrcpy/scrcpy-server"
test "$QTSCRCPY_DEFAULT_KEYMAP_PATH" = "$MOCK_PREFIX/qtscrcpy/share/keymap"
test "$QTSCRCPY_DEFAULT_CONFIG_PATH" = "$MOCK_PREFIX/qtscrcpy/share/config"
test "$QTSCRCPY_CONFIG_PATH" = "${XDG_CONFIG_HOME:-$HOME/.config}/qtscrcpy"
test -d "$QTSCRCPY_CONFIG_PATH"
test "$ANDROID_USER_HOME" = "${XDG_DATA_HOME:-$HOME/.local/share}/android"
test -d "$ANDROID_USER_HOME"
printf '%s\n' "$@" > "$CAPTURE"
exit "${MOCK_STATUS:-0}"
MOCK
cat > "$work/app/libexec/uadng" <<'MOCK'
#!/bin/sh
set -eu
test "${PATH%%:*}" = "$MOCK_PREFIX/bin"
test "$PWD" = "${XDG_DATA_HOME:-$HOME/.local/share}/uad-ng"
test "$ANDROID_USER_HOME" = "${XDG_DATA_HOME:-$HOME/.local/share}/android"
test -d "$ANDROID_USER_HOME"
printf '%s\n' "$@" > "$CAPTURE"
printf 'saved export\n' > selection_export.txt
exit "${MOCK_STATUS:-0}"
MOCK
chmod +x "$work/bin/dirname" "$work/app/qtscrcpy/bin/QtScrcpy" "$work/app/libexec/uadng"
expect_failure()
{
  if "$@" > "$work/error" 2>&1; then echo 'Expected launcher failure' >&2; exit 1; fi
}
for launcher in qtscrcpy uadng; do
  env APPIMAGE=wrong APPDIR=wrong ARGV0=wrong QT_PLUGIN_PATH=wrong QT_QPA_PLATFORM_PLUGIN_PATH=wrong QT_QPA_PLATFORM=wayland bash "$root/scripts/$launcher-launch.sh" 'argument with spaces ñ😀' '' '; echo not code'
  printf '%s\n' 'argument with spaces ñ😀' '' '; echo not code' > "$work/expected"
  cmp "$CAPTURE" "$work/expected"
  env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u LD_LIBRARY_PATH bash "$root/scripts/$launcher-launch.sh"
  expect_failure env MOCK_STATUS=7 bash "$root/scripts/$launcher-launch.sh"
  mkdir -p "$work/file-parent"
  printf 'not a directory\n' > "$work/file-parent/data"
  expect_failure env XDG_DATA_HOME="$work/file-parent/data" bash "$root/scripts/$launcher-launch.sh"
done
test "$(cat "$XDG_DATA_HOME/uad-ng/selection_export.txt")" = 'saved export'
test ! -e "$root/selection_export.txt"
printf 'saved settings\n' > "$XDG_CONFIG_HOME/qtscrcpy/config.ini"
bash "$root/scripts/qtscrcpy-launch.sh"
test "$(cat "$XDG_CONFIG_HOME/qtscrcpy/config.ini")" = 'saved settings'
# Both manifests explicitly bundle ADB, retain notices, and allow USB/network.
python3 - "$root" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
for package, name in [('qtscrcpy', 'QtScrcpy'), ('uadng', 'UADng')]:
    manifest = json.loads((root / 'packages' / package / f'io.github.astrovm.{name}.json').read_text())
    assert manifest['runtime-version'] == '50'
    assert set(['--share=network', '--device=all']) <= set(manifest['finish-args'])
    if package == 'qtscrcpy':
        assert '--socket=x11' in manifest['finish-args'] and '--socket=wayland' not in manifest['finish-args']
    else:
        assert set(['--socket=wayland', '--socket=fallback-x11']) <= set(manifest['finish-args'])
    assert not any('org.freedesktop.Flatpak' in permission for permission in manifest['finish-args'])
    sources = manifest['modules'][0]['sources']
    adb = [source for source in sources if 'Genymobile/scrcpy/releases/download/' in source.get('url', '')]
    assert len(adb) == 1 and len(adb[0]['sha256']) == 64
    assert any(source.get('path') == 'NOTICE.adb' for source in sources)
    app = [source for source in sources if source.get('url') and source not in adb]
    assert len(app) == 1
    if package == 'uadng':
        assert 'noselfupdate' in app[0]['url'] and app[0]['strip-components'] == 0
    else:
        assert app[0]['type'] == 'file' and app[0]['dest-filename'] == 'QtScrcpy.AppImage'
PY
echo 'ok - Android launchers isolate keys/settings, preserve arguments and save exports in writable storage'
