#!/usr/bin/env bash
set -euo pipefail
umask 077
unset ELECTRON_RUN_AS_NODE APPIMAGE APPDIR ARGV0

# Chromium needs writable private storage for its NSS database. Keep the
# original home as the file picker's starting location before changing HOME.
export OWD=${OWD:-$HOME}
mkdir -p "$XDG_DATA_HOME"
export HOME=$XDG_DATA_HOME

# The UI stays in Flatpak. Only this copy of the upstream writer runs on host.
mkdir -p "$XDG_CACHE_HOME"
writer_directory=$(mktemp -d "$XDG_CACHE_HOME/etcher-writer.XXXXXX")
trap 'rm -rf -- "$writer_directory"' EXIT
cp /app/etcher/resources/etcher-util "$writer_directory/etcher-util"
cp /app/libexec/etcher-host-writer "$writer_directory/writer"
chmod 700 "$writer_directory/etcher-util" "$writer_directory/writer"
export ETCHER_HOST_WRITER=$writer_directory/writer
zypak-wrapper /app/etcher/balena-etcher --ozone-platform-hint=auto "$@"
