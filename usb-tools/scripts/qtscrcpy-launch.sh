#!/usr/bin/env bash
set -euo pipefail
prefix=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
unset APPIMAGE APPDIR ARGV0 LD_PRELOAD QT_PLUGIN_PATH QT_QPA_PLATFORM_PLUGIN_PATH
export LD_LIBRARY_PATH="$prefix/qtscrcpy/lib:$prefix/qtscrcpy/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-/usr/lib/x86_64-linux-gnu/GL/default/lib}"
export QT_QPA_PLATFORM=xcb
export QT_PLUGIN_PATH="$prefix/qtscrcpy/plugins"
export QT_QPA_PLATFORM_PLUGIN_PATH="$QT_PLUGIN_PATH/platforms"
export QTSCRCPY_ADB_PATH="$prefix/bin/adb"
export QTSCRCPY_SERVER_PATH="$prefix/qtscrcpy/lib/qtscrcpy/scrcpy-server"
export QTSCRCPY_DEFAULT_KEYMAP_PATH="$prefix/qtscrcpy/share/keymap"
export QTSCRCPY_DEFAULT_CONFIG_PATH="$prefix/qtscrcpy/share/config"
export QTSCRCPY_CONFIG_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/qtscrcpy"
export ANDROID_USER_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/android"
mkdir -p -- "$QTSCRCPY_CONFIG_PATH" "$ANDROID_USER_HOME"
exec "$prefix/qtscrcpy/bin/QtScrcpy" "$@"
