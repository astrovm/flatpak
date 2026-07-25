#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/publish-common.sh
source "$script_directory/lib/publish-common.sh"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <site-directory>" >&2
  exit 2
fi

site_directory=$(realpath -- "$1")
repository_directory=$site_directory/repo
repository_file=$site_directory/astrovm.flatpakrepo

for path in \
  "$repository_directory/config" \
  "$repository_directory/summary" \
  "$repository_directory/summary.sig" \
  "$site_directory/astrovm.gpg" \
  "$repository_file" \
  "$site_directory/io.github.astrovm.AdventureMods.flatpakref"; do
  if [ ! -s "$path" ]; then
    error "Generated repository file is missing or empty: $path"
    exit 1
  fi
done

encoded_public_key=$(base64 --wrap=0 "$site_directory/astrovm.gpg")
for descriptor in \
  "$repository_file" \
  "$site_directory/io.github.astrovm.AdventureMods.flatpakref"; do
  if ! grep -Fxq "GPGKey=$encoded_public_key" "$descriptor"; then
    error "Embedded GPG key does not match astrovm.gpg: $descriptor"
    exit 1
  fi
done

ostree fsck --quiet --verify-bindings --repo="$repository_directory"
ostree summary --view --repo="$repository_directory" >/dev/null
validate_repository_refs "$repository_directory"

temporary_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
client_directory=$(mktemp -d "$temporary_root/flatpak-client.XXXXXX")
trap 'rm -rf -- "$client_directory"' EXIT

local_repository_file=$client_directory/astrovm.flatpakrepo
repository_url=file://$(realpath -- "$repository_directory")/
sed "s|^Url=.*|Url=$repository_url|" "$repository_file" > "$local_repository_file"

export XDG_CACHE_HOME=$client_directory/cache
export XDG_DATA_HOME=$client_directory/data
mkdir -p "$XDG_CACHE_HOME" "$XDG_DATA_HOME"

flatpak remote-add --user --if-not-exists astrovm-verification "$local_repository_file"

for arch in "${EXPECTED_ARCHES[@]}"; do
  expected=$(expected_ref "$arch")
  actual=$(flatpak remote-ls \
    --user \
    --arch="$arch" \
    --columns=ref \
    astrovm-verification)

  if [ "$actual" != "$expected" ]; then
    error "Flatpak client expected $expected, received: ${actual:-nothing}"
    exit 1
  fi
done

echo "Verified signed Flatpak repository for ${EXPECTED_ARCHES[*]}"
