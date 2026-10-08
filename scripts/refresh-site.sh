#!/usr/bin/env bash
# Regenerate the website of an already published site and keep its repository.
# No signing key is needed: the public key the site already publishes is reused.
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(realpath -- "$script_directory/..")
# shellcheck source=scripts/lib/publish-common.sh
source "$script_directory/lib/publish-common.sh"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <site-directory>" >&2
  exit 2
fi

validate_app_registry
# Validate the argument as given: resolving it first would follow symbolic links.
validate_output_directory "$1" "$repository_root"
site_directory=$(realpath --canonicalize-missing -- "$1")

if [ ! -s "$site_directory/repo/config" ] || [ ! -s "$site_directory/astrovm.gpg" ]; then
  error "No published repository to refresh in $site_directory"
  exit 1
fi

restore_repository_directories "$site_directory/repo"

temporary_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
working_directory=$(mktemp -d "$temporary_root/flatpak-refresh.XXXXXX")
trap 'rm -rf -- "$working_directory"' EXIT

# Main can register an app before its first package publication finishes, so
# only apps already in the repository can be verified now. An app the site
# already advertises stays in the checks even when its refs are missing.
published_refs=$(ostree refs --repo="$site_directory/repo" | jq -Rsc 'split("\n") | map(select(length > 0))')
published_descriptors=$(find "$site_directory" -maxdepth 1 -type f -name '*.flatpakref' -printf '%f\n' | jq -Rsc 'split("\n")')
published_registry=$working_directory/apps.json
jq --argjson refs "$published_refs" --argjson descriptors "$published_descriptors" -f /dev/stdin "$APP_REGISTRY" > "$published_registry" <<'JQ'
  .apps |= map(select(
    . as $app
    | any($refs[]; startswith("app/\($app.id)/"))
      or ($descriptors | index("\($app.id).flatpakref") != null)
  ))
JQ

# Reject incomplete or unknown published refs before replacing website files.
# The subshell expands its own positional parameter.
# shellcheck disable=SC2016
env APP_REGISTRY="$published_registry" bash -c 'source "$1"; validate_app_registry && validate_repository_refs "$2"' \
  _ "$script_directory/lib/publish-common.sh" "$site_directory/repo"

public_key_file=$working_directory/astrovm.gpg
cp "$site_directory/astrovm.gpg" "$public_key_file"

find "$site_directory" \
  -mindepth 1 \
  -maxdepth 1 \
  ! -name .git \
  ! -name repo \
  ! -name usb-tools \
  -exec rm -rf -- {} +

env APP_REGISTRY="$published_registry" "$script_directory/render-site.sh" "$public_key_file" "$site_directory"

env APP_REGISTRY="$published_registry" "$script_directory/verify-repository.sh" "$site_directory"
