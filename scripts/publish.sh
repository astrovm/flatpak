#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(realpath -- "$script_directory/..")
# shellcheck source=scripts/lib/publish-common.sh
source "$script_directory/lib/publish-common.sh"

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <source-repository> <release-tag> <output-directory>" >&2
  exit 2
fi

source_repository=$1
release_tag=$2
output_directory=$(realpath --canonicalize-missing -- "$3")

validate_app_registry
validate_source_repository "$source_repository"
validate_release_tag "$release_tag"
validate_output_directory "$output_directory" "$repository_root"

mapfile -t app_arches < <(app_architectures "$source_repository")

if [ -z "${GH_TOKEN:-}" ]; then
  error "GH_TOKEN is required"
  exit 1
fi

if [ -z "${FLATPAK_GPG_PRIVATE_KEY:-}" ] || [ -z "${FLATPAK_GPG_KEY_ID:-}" ]; then
  error "FLATPAK_GPG_PRIVATE_KEY and FLATPAK_GPG_KEY_ID must be configured"
  exit 1
fi

temporary_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
working_directory=$(mktemp -d "$temporary_root/flatpak-publish.XXXXXX")
trap 'rm -rf -- "$working_directory"' EXIT

bundles_directory=$working_directory/bundles
gnupg_home=$working_directory/gnupg
release_metadata=$working_directory/release.json

mkdir -p "$bundles_directory"
mkdir -p "$gnupg_home"
chmod 700 "$gnupg_home"
printf '%s\n' "$FLATPAK_GPG_PRIVATE_KEY" | gpg --batch --homedir "$gnupg_home" --import
gpg --batch --homedir "$gnupg_home" --list-secret-keys "$FLATPAK_GPG_KEY_ID" >/dev/null

gh api "repos/$source_repository/releases/tags/$release_tag" > "$release_metadata"
validate_release_metadata "$release_metadata" "$release_tag"

gh release download "$release_tag" \
  --repo "$source_repository" \
  --pattern '*.flatpak' \
  --dir "$bundles_directory"

validate_downloaded_bundles \
  "$release_metadata" \
  "$bundles_directory" \
  "$source_repository"

mkdir -p "$output_directory"
repository_directory=$output_directory/repo
if [ ! -f "$repository_directory/config" ]; then
  ostree init --repo="$repository_directory" --mode=archive-z2
fi

# Git does not track empty directories. A previously published OSTree repo on
# gh-pages therefore often lacks empty refs/{remotes,mirrors} (and similar)
# paths after checkout. flatpak build-update-repo --generate-static-deltas
# fails with: Listing refs: opendir(refs/remotes): No such file or directory
mkdir -p \
  "$repository_directory/extensions" \
  "$repository_directory/objects" \
  "$repository_directory/refs/heads" \
  "$repository_directory/refs/mirrors" \
  "$repository_directory/refs/remotes" \
  "$repository_directory/state" \
  "$repository_directory/tmp"

ostree fsck --quiet --repo="$repository_directory"

for arch in "${app_arches[@]}"; do
  bundle=$bundles_directory/$(expected_bundle_name "$source_repository" "$arch")
  expected=$(expected_ref "$source_repository" "$arch")
  inspection_repository=$working_directory/inspect-$arch

  ostree init --repo="$inspection_repository" --mode=archive-z2
  flatpak build-import-bundle \
    --no-update-summary \
    "$inspection_repository" \
    "$bundle"

  mapfile -t imported_refs < <(ostree refs --repo="$inspection_repository")
  if [ "${#imported_refs[@]}" -ne 1 ] || [ "${imported_refs[0]}" != "$expected" ]; then
    error "$(basename "$bundle") contains an unexpected ref: ${imported_refs[*]:-none}"
    exit 1
  fi

  echo "Importing $(basename "$bundle") as $expected"
  flatpak build-import-bundle \
    --no-update-summary \
    --gpg-sign="$FLATPAK_GPG_KEY_ID" \
    --gpg-homedir="$gnupg_home" \
    "$repository_directory" \
    "$bundle"
done

flatpak build-update-repo \
  --title="astrovm Flatpak Repository" \
  --comment="Official Flatpak applications published by astrovm" \
  --description="Install and update applications published by astrovm." \
  --homepage="https://4st.li/" \
  --default-branch=master \
  --gpg-sign="$FLATPAK_GPG_KEY_ID" \
  --gpg-homedir="$gnupg_home" \
  --generate-static-deltas \
  --prune \
  --prune-depth=3 \
  "$repository_directory"

validate_repository_refs "$repository_directory"

public_key_file=$working_directory/astrovm.gpg
gpg --batch --homedir "$gnupg_home" --export "$FLATPAK_GPG_KEY_ID" > "$public_key_file"
if [ ! -s "$public_key_file" ]; then
  error "Failed to export the Flatpak repository public key"
  exit 1
fi

# Keep the publishing branch as one generated snapshot while preserving its
# Git worktree metadata and persistent OSTree repository.
find "$output_directory" \
  -mindepth 1 \
  -maxdepth 1 \
  ! -name .git \
  ! -name repo \
  -exec rm -rf -- {} +

"$script_directory/render-site.sh" "$public_key_file" "$output_directory"

"$script_directory/verify-repository.sh" "$output_directory"
