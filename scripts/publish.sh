#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <source-repository> <release-tag> <output-directory> <bundles-directory>" >&2
  exit 2
fi

source_repository=$1
release_tag=$2
output_directory=$3
bundles_directory=$4

case "$source_repository" in
  astrovm/AdventureMods)
    ;;
  *)
    echo "::error::Publishing from $source_repository is not allowed" >&2
    exit 1
    ;;
esac

if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "::error::Invalid release tag: $release_tag" >&2
  exit 1
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::GH_TOKEN is required" >&2
  exit 1
fi

if [ -z "${FLATPAK_GPG_PRIVATE_KEY:-}" ] || [ -z "${FLATPAK_GPG_KEY_ID:-}" ]; then
  echo "::error::FLATPAK_GPG_PRIVATE_KEY and FLATPAK_GPG_KEY_ID must be configured" >&2
  exit 1
fi

gnupg_home=${GNUPGHOME:-"$RUNNER_TEMP/flatpak-gnupg"}
mkdir -p "$gnupg_home"
chmod 700 "$gnupg_home"
printf '%s\n' "$FLATPAK_GPG_PRIVATE_KEY" | gpg --batch --homedir "$gnupg_home" --import
gpg --batch --homedir "$gnupg_home" --list-secret-keys "$FLATPAK_GPG_KEY_ID" >/dev/null

rm -rf "$bundles_directory"
mkdir -p "$bundles_directory"
gh release view "$release_tag" --repo "$source_repository" >/dev/null
gh release download "$release_tag" \
  --repo "$source_repository" \
  --pattern '*.flatpak' \
  --dir "$bundles_directory"

mapfile -d '' bundles < <(find "$bundles_directory" -maxdepth 1 -type f -name '*.flatpak' -print0 | sort -z)
if [ "${#bundles[@]}" -eq 0 ]; then
  echo "::error::Release $source_repository $release_tag contains no Flatpak bundles" >&2
  exit 1
fi

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

for bundle in "${bundles[@]}"; do
  echo "Importing $(basename "$bundle")"
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

public_key=$(gpg --batch --homedir "$gnupg_home" --export "$FLATPAK_GPG_KEY_ID" | base64 --wrap=0)
if [ -z "$public_key" ]; then
  echo "::error::Failed to export the Flatpak repository public key" >&2
  exit 1
fi

sed "s|@GPG_KEY@|$public_key|" \
  templates/astrovm.flatpakrepo.in \
  > "$output_directory/astrovm.flatpakrepo"
sed "s|@GPG_KEY@|$public_key|" \
  templates/io.github.astrovm.AdventureMods.flatpakref.in \
  > "$output_directory/io.github.astrovm.AdventureMods.flatpakref"
cp templates/index.html "$output_directory/index.html"
install_directory="$output_directory/apps/io.github.astrovm.AdventureMods/install"
mkdir -p "$install_directory"
cp templates/adventuremods-install.html "$install_directory/index.html"
printf '%s\n' 'flatpak.4st.li' > "$output_directory/CNAME"
touch "$output_directory/.nojekyll"
