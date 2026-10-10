#!/usr/bin/env bash
set -euo pipefail
prefix=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export PATH="$prefix/bin:$PATH"
export ANDROID_USER_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/android"
# Upstream selection exports and CSV backups use the current directory.
work_directory=${XDG_DATA_HOME:-$HOME/.local/share}/uad-ng
mkdir -p -- "$work_directory" "$ANDROID_USER_HOME"
cd -- "$work_directory"
exec "$prefix/libexec/uadng" "$@"
