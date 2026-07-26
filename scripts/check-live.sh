#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/publish-common.sh
source "$script_directory/lib/publish-common.sh"

validate_app_registry

site_url=https://flatpak.4st.li

curl --fail --silent --show-error "$site_url/" >/dev/null
curl --fail --silent --show-error "$site_url/astrovm.flatpakrepo" >/dev/null

while IFS= read -r repository; do
  app_id=$(app_value "$repository" id)
  curl --fail --silent --show-error \
    "$site_url/$app_id.flatpakref" >/dev/null
  curl --fail --silent --show-error \
    "$site_url/apps/$app_id/install/" >/dev/null
done < <(app_repositories)

temporary_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
client_directory=$(mktemp -d "$temporary_root/flatpak-client.XXXXXX")
trap 'rm -rf -- "$client_directory"' EXIT

export XDG_CACHE_HOME=$client_directory/cache
export XDG_DATA_HOME=$client_directory/data
mkdir -p "$XDG_CACHE_HOME" "$XDG_DATA_HOME"

flatpak remote-add \
  --user \
  --if-not-exists \
  astrovm \
  "$site_url/astrovm.flatpakrepo"

while IFS= read -r arch; do
  expected=$(expected_refs_for_arch "$arch")
  actual=$(flatpak remote-ls \
    --user \
    --arch="$arch" \
    --columns=ref \
    astrovm |
    sort)

  if [ "$actual" != "$expected" ]; then
    error "Published repository has unexpected refs for $arch"
    printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "${actual:-nothing}" >&2
    exit 1
  fi
done < <(all_architectures)

echo "Published repository is healthy"
