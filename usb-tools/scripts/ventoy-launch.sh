#!/usr/bin/env bash
set -euo pipefail
umask 077

case "$(uname -m)" in
  x86_64) architecture=x86_64 ;;
  aarch64) architecture=aarch64 ;;
  *) echo 'Unsupported Ventoy architecture' >&2; exit 1 ;;
esac
mkdir -p "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
mkdir -p "$XDG_CACHE_HOME/ventoy" "$XDG_CONFIG_HOME/ventoy"
payload_directory=$(mktemp -d "$XDG_CACHE_HOME/ventoy.XXXXXX")
trap 'rm -rf -- "$payload_directory"' EXIT
cp -a /app/ventoy/. "$payload_directory/"
# Ventoy's own launcher handles the host Polkit prompt and display environment.
flatpak-spawn --host --watch-bus \
  "--env=XDG_CACHE_HOME=$XDG_CACHE_HOME" \
  "--env=XDG_CONFIG_HOME=$XDG_CONFIG_HOME" \
  "--directory=$payload_directory" \
  "$payload_directory/VentoyGUI.$architecture" --gtk3 --xdg "$@"
