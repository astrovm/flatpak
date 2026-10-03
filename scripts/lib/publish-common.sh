#!/usr/bin/env bash

publish_common_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly APP_REGISTRY=${APP_REGISTRY:-$(realpath -- "$publish_common_directory/../../apps.json")}

error()
{
  printf '::error::%s\n' "$*" >&2
}

validate_source_repository()
{
  local repository=$1

  if ! jq -e \
    --arg repository "$repository" \
    '[.apps[] | select(.repository == $repository)] | length == 1' \
    "$APP_REGISTRY" >/dev/null; then
    error "Publishing from $repository is not allowed"
    return 1
  fi
}

app_registry_is_valid()
{
  jq -e -f /dev/stdin "$APP_REGISTRY" >/dev/null <<'JQ'
    def text:
      type == "string" and length > 0 and (test("[\t\r\n]") | not);
    (.apps | type == "array" and length > 0)
      and all(
        .apps[];
        (.repository | text and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
          and (.id | text and test("^[A-Za-z0-9_-]+([.][A-Za-z0-9_-]+)+$"))
          and (.name | text)
          and (.summary | text)
          and (.bundle_prefix | text and test("^[A-Za-z0-9_.-]+$"))
          and (.branch | text and test("^[A-Za-z0-9_.-]+$"))
          and (
            .architectures
            | type == "array"
              and length > 0
              and all(.[]; type == "string" and test("^[A-Za-z0-9_]+$"))
              and length == (unique | length)
          )
          and (.runtime_repository | text and test("^https://"))
      )
      and (
        [.apps[].repository] as $values
        | $values | length == (unique | length)
      )
      and (
        [.apps[].id] as $values
        | $values | length == (unique | length)
      )
JQ
}

validate_app_registry()
{
  if ! app_registry_is_valid; then
    error "Invalid application registry: $APP_REGISTRY"
    return 1
  fi
}

app_value()
{
  local repository=$1
  local field=$2

  jq -er \
    --arg repository "$repository" \
    --arg field "$field" \
    '.apps[] | select(.repository == $repository) | .[$field]' \
    "$APP_REGISTRY"
}

app_html_value()
{
  local repository=$1
  local field=$2

  jq -jr \
    --arg repository "$repository" \
    --arg field "$field" \
    '.apps[] | select(.repository == $repository) | .[$field] | @html' \
    "$APP_REGISTRY"
}

app_architectures()
{
  local repository=$1

  jq -r \
    --arg repository "$repository" \
    '.apps[] | select(.repository == $repository) | .architectures[]' \
    "$APP_REGISTRY"
}

app_repositories()
{
  jq -r '.apps[].repository' "$APP_REGISTRY"
}

all_architectures()
{
  jq -r '[.apps[].architectures[]] | unique[]' "$APP_REGISTRY"
}

all_expected_refs()
{
  jq -r -f /dev/stdin "$APP_REGISTRY" <<'JQ'
    .apps[]
    | . as $app
    | .architectures[]
    | "app/\($app.id)/\(.)/\($app.branch)"
JQ
}

expected_refs_for_arch()
{
  local arch=$1

  jq -r --arg arch "$arch" -f /dev/stdin "$APP_REGISTRY" <<'JQ' | sort
    .apps[]
    | select(.architectures | index($arch))
    | "app/\(.id)/\($arch)/\(.branch)"
JQ
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

release_bundle_name()
{
  local metadata_file=$1
  local repository=$2
  local arch=$3
  local prefix tag versioned legacy

  prefix=$(app_value "$repository" bundle_prefix)
  tag=$(jq -er '.tag_name' "$metadata_file")
  validate_release_tag "$tag" || return 1
  versioned=$prefix-$tag-$arch.flatpak
  legacy=$prefix-$arch.flatpak
  jq -er --arg versioned "$versioned" --arg legacy "$legacy" -f /dev/stdin "$metadata_file" <<'JQ'
    [.assets[].name | select(. == $versioned or . == $legacy)]
    | if length == 1 then .[0] else empty end
JQ
}

expected_ref()
{
  local repository=$1
  local arch=$2

  printf 'app/%s/%s/%s\n' \
    "$(app_value "$repository" id)" \
    "$arch" \
    "$(app_value "$repository" branch)"
}

validate_release_metadata()
{
  local metadata_file=$1
  local expected_tag=$2

  if ! jq -e \
    --arg tag "$expected_tag" \
    '.tag_name == $tag and .draft == false and .prerelease == false and .immutable == true' \
    "$metadata_file" >/dev/null; then
    error "Release $expected_tag must be published, immutable, and not a prerelease"
    return 1
  fi
}

unique_asset_digest()
{
  local metadata_file=$1
  local name=$2

  jq -er --arg name "$name" -f /dev/stdin "$metadata_file" <<'JQ'
    [.assets[] | select(.name == $name) | .digest]
    | if length == 1 then .[0] else empty end
JQ
}

validate_downloaded_bundles()
{
  local metadata_file=$1
  local bundles_directory=$2
  local repository=$3
  local arch bundle bundle_name expected_digest actual_digest
  local -a downloaded_bundles
  local -a architectures

  mapfile -t architectures < <(app_architectures "$repository")

  mapfile -d '' downloaded_bundles < <(find "$bundles_directory" -maxdepth 1 -type f -name '*.flatpak' -print0)

  if [ "${#downloaded_bundles[@]}" -ne "${#architectures[@]}" ]; then
    error "Expected ${#architectures[@]} Flatpak bundles, found ${#downloaded_bundles[@]}"
    return 1
  fi

  for arch in "${architectures[@]}"; do
    if ! bundle_name=$(release_bundle_name "$metadata_file" "$repository" "$arch"); then
      error "Release needs one Flatpak bundle for $repository on $arch"
      return 1
    fi
    bundle=$bundles_directory/$bundle_name

    if [ ! -f "$bundle" ]; then
      error "Release is missing $bundle_name"
      return 1
    fi

    if ! expected_digest=$(unique_asset_digest "$metadata_file" "$bundle_name"); then
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
  local -a architectures expected_refs refs
  local -A expected_app_refs=()
  local -A expected_appstream_refs=()
  local -A found_app_refs=()

  mapfile -t expected_refs < <(all_expected_refs)
  for ref in "${expected_refs[@]}"; do
    expected_app_refs["$ref"]=1
  done

  mapfile -t architectures < <(all_architectures)
  for arch in "${architectures[@]}"; do
    expected_appstream_refs["appstream/$arch"]=1
    expected_appstream_refs["appstream2/$arch"]=1
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
      appstream/* | appstream2/*)
        if [ -z "${expected_appstream_refs[$ref]:-}" ]; then
          error "Repository contains unexpected AppStream ref: $ref"
          return 1
        fi
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

# Git does not track empty directories. A previously published OSTree repo on
# gh-pages therefore often lacks empty refs/{remotes,mirrors} (and similar)
# paths after checkout, and OSTree fails with:
# Listing refs: opendir(refs/remotes): No such file or directory
restore_repository_directories()
{
  local repository_directory=$1

  mkdir -p \
    "$repository_directory/extensions" \
    "$repository_directory/objects" \
    "$repository_directory/refs/heads" \
    "$repository_directory/refs/mirrors" \
    "$repository_directory/refs/remotes" \
    "$repository_directory/state" \
    "$repository_directory/tmp"
}
