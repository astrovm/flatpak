#!/usr/bin/env bash
set -euo pipefail
umask 077
unset ELECTRON_RUN_AS_NODE APPIMAGE APPDIR ARGV0

# Chromium needs writable private storage for its NSS database. Resolve the
# desktop folders against the real home before moving HOME to private storage.
export OWD=${OWD:-$HOME}
mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
mkdir -p "$XDG_CONFIG_HOME/balenaEtcher" "$XDG_CONFIG_HOME/gtk-3.0"
writer_directory=$(mktemp -d "$XDG_CACHE_HOME/etcher-writer.XXXXXX")
trap 'rm -rf -- "$writer_directory"' EXIT
# xdg-user-dir has an unquoted config-path check; use a space-free private path.
config_directory=$(mktemp -d /tmp/etcher-config.XXXXXX)
trap 'rm -rf -- "$writer_directory" "$config_directory"' EXIT
# Flatpak's user-dirs.dirs is read-only. Mirror the other app settings so their
# changes still persist, and provide GTK with an absolute-path directory file.
shopt -s nullglob dotglob
for entry in "$XDG_CONFIG_HOME"/*; do
  ln -s -- "$entry" "$config_directory/"
done
export XDG_CONFIG_HOME=$config_directory
for category in DESKTOP DOWNLOAD TEMPLATES PUBLICSHARE DOCUMENTS MUSIC PICTURES VIDEOS; do
  folder=$(xdg-user-dir "$category")
  folder=${folder//\\/\\\\}
  folder=${folder//\"/\\\"}
  folder=${folder//\$/\\\$}
  folder=${folder//\`/\\\`}
  printf 'XDG_%s_DIR="%s"\n' "$category" "$folder" >> "$config_directory/user-dirs.absolute"
done
mv -f -- "$config_directory/user-dirs.absolute" "$config_directory/user-dirs.dirs"
export HOME=$XDG_DATA_HOME

# The UI stays in Flatpak. Only this copy of the upstream writer runs on host.
cp /app/etcher/resources/etcher-util "$writer_directory/etcher-util"
cp /app/libexec/etcher-host-writer "$writer_directory/writer"
chmod 700 "$writer_directory/etcher-util" "$writer_directory/writer"
export ETCHER_HOST_WRITER=$writer_directory/writer
# The host writer needs real paths, not document-portal FUSE paths. Use
# Electron's native chooser for the home/media paths this package can read.
zypak-wrapper /app/etcher/balena-etcher --ozone-platform-hint=auto --xdg-portal-required-version=999 "$@"
