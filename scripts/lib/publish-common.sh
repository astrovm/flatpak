#!/usr/bin/env bash

readonly SOURCE_REPOSITORY="astrovm/AdventureMods"
readonly APP_ID="io.github.astrovm.AdventureMods"
readonly APP_BRANCH="master"
readonly EXPECTED_ARCHES=("aarch64" "x86_64")

error()
{
  printf '::error::%s\n' "$*" >&2
}

validate_source_repository()
{
  local repository=$1

  if [ "$repository" != "$SOURCE_REPOSITORY" ]; then
    error "Publishing from $repository is not allowed"
    return 1
  fi
}

validate_release_tag()
{
  local tag=$1
  local number='(0|[1-9][0-9]*)'
  local identifier='[0-9A-Za-z]+([.-][0-9A-Za-z]+)*'

  if [[ ! "$tag" =~ ^v${number}\.${number}\.${number}(-${identifier})?(\+${identifier})?$ ]]; then
    error "Invalid release tag: $tag"
    return 1
  fi
}

validate_output_directory()
{
  local directory=$1
  local protected_directory=${2:-}
  local resolved_directory
  local resolved_protected_directory

  if [ -z "$directory" ]; then
    error "Output directory is required"
    return 1
  fi

  resolved_directory=$(realpath --canonicalize-missing -- "$directory")
  if [ "$resolved_directory" = "/" ]; then
    error "Refusing to use the filesystem root as the output directory"
    return 1
  fi

  if [ -n "$protected_directory" ]; then
    resolved_protected_directory=$(realpath --canonicalize-missing -- "$protected_directory")
    if [ "$resolved_directory" = "$resolved_protected_directory" ] ||
      [[ "$resolved_protected_directory/" == "$resolved_directory/"* ]]; then
      error "Output directory cannot be the source repository or one of its parents"
      return 1
    fi
  fi

  if [ -L "$directory" ]; then
    error "Refusing to use a symbolic link as the output directory: $directory"
    return 1
  fi
}

expected_bundle_name()
{
  local arch=$1
  printf 'AdventureMods-%s.flatpak\n' "$arch"
}

expected_ref()
{
  local arch=$1
  printf 'app/%s/%s/%s\n' "$APP_ID" "$arch" "$APP_BRANCH"
}

validate_release_metadata()
{
  local metadata_file=$1
  local expected_tag=$2

  if ! jq -e \
    --arg tag "$expected_tag" \
    '.tag_name == $tag
      and .draft == false
      and .prerelease == false
      and .immutable == true' \
    "$metadata_file" >/dev/null; then
    error "Release $expected_tag must be published, immutable, and not a prerelease"
    return 1
  fi
}

validate_downloaded_bundles()
{
  local metadata_file=$1
  local bundles_directory=$2
  local arch bundle bundle_name expected_digest actual_digest
  local -a downloaded_bundles

  mapfile -d '' downloaded_bundles < <(
    find "$bundles_directory" -maxdepth 1 -type f -name '*.flatpak' -print0 |
      sort -z
  )

  if [ "${#downloaded_bundles[@]}" -ne "${#EXPECTED_ARCHES[@]}" ]; then
    error "Expected ${#EXPECTED_ARCHES[@]} Flatpak bundles, found ${#downloaded_bundles[@]}"
    return 1
  fi

  for arch in "${EXPECTED_ARCHES[@]}"; do
    bundle_name=$(expected_bundle_name "$arch")
    bundle=$bundles_directory/$bundle_name

    if [ ! -f "$bundle" ]; then
      error "Release is missing $bundle_name"
      return 1
    fi

    if ! expected_digest=$(jq -er \
      --arg name "$bundle_name" \
      '[.assets[] | select(.name == $name) | .digest]
        | if length == 1 then .[0] else empty end' \
      "$metadata_file"); then
      error "Release metadata has no unique digest for $bundle_name"
      return 1
    fi

    if [[ ! "$expected_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      error "Release metadata has an invalid digest for $bundle_name"
      return 1
    fi

    actual_digest=sha256:$(sha256sum "$bundle" | cut -d ' ' -f 1)
    if [ "$actual_digest" != "$expected_digest" ]; then
      error "Digest mismatch for $bundle_name"
      return 1
    fi
  done
}

validate_repository_refs()
{
  local repository_directory=$1
  local arch ref
  local -A expected_app_refs=()
  local -A found_app_refs=()
  local -a refs

  for arch in "${EXPECTED_ARCHES[@]}"; do
    expected_app_refs["$(expected_ref "$arch")"]=1
  done

  mapfile -t refs < <(ostree refs --repo="$repository_directory" | sort)
  for ref in "${refs[@]}"; do
    case "$ref" in
      app/*)
        if [ -z "${expected_app_refs[$ref]:-}" ]; then
          error "Repository contains unexpected application ref: $ref"
          return 1
        fi
        found_app_refs["$ref"]=1
        ;;
      runtime/*)
        error "Repository contains unexpected runtime ref: $ref"
        return 1
        ;;
      appstream/aarch64 | appstream/x86_64 | appstream2/aarch64 | appstream2/x86_64)
        ;;
      *)
        error "Repository contains unexpected ref: $ref"
        return 1
        ;;
    esac
  done

  for ref in "${!expected_app_refs[@]}"; do
    if [ -z "${found_app_refs[$ref]:-}" ]; then
      error "Repository is missing expected ref: $ref"
      return 1
    fi
  done
}
