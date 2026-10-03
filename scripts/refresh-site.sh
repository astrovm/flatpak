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

temporary_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
working_directory=$(mktemp -d "$temporary_root/flatpak-refresh.XXXXXX")
trap 'rm -rf -- "$working_directory"' EXIT

public_key_file=$working_directory/astrovm.gpg
cp "$site_directory/astrovm.gpg" "$public_key_file"

find "$site_directory" \
  -mindepth 1 \
  -maxdepth 1 \
  ! -name .git \
  ! -name repo \
  -exec rm -rf -- {} +

"$script_directory/render-site.sh" "$public_key_file" "$site_directory"

"$script_directory/verify-repository.sh" "$site_directory"
