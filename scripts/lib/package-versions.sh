#!/usr/bin/env bash
# Shared by release resolution and publication inside the serialized queue.
assert_package_version()
{
  local package=$1 old_version=$2 version=$3
  if [[ ! "$old_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid $package release version" >&2
    return 1
  fi
  if [ "$(printf '%s\n' "$old_version" "$version" | sort -V | tail -1)" != "$version" ]; then
    echo "Refusing to downgrade $package from $old_version to $version" >&2
    return 1
  fi
}

verify_package_versions()
{
  local proposed=$1 previous=$2 package old_version version
  local -a packages
  if [ ! -f "$previous" ]; then return 0; fi
  jq -e 'type == "object" and length > 0' "$previous" >/dev/null || return 1
  mapfile -t packages < <(jq -r 'keys[]' "$previous")
  for package in "${packages[@]}"; do
    old_version=$(jq -er --arg package "$package" '.[$package].version' "$previous") || return 1
    version=$(jq -er --arg package "$package" '.[$package].version' "$proposed") || return 1
    assert_package_version "$package" "$old_version" "$version" || return 1
  done
}

# Hash the manifest and every local source installed by it. Unrelated tools and
# publication-only workflow edits do not change the built package.
package_recipe_digest()
{
  local root=$1 package=$2 id=$3 manifest source
  local -a sources
  manifest=$root/packages/$package/$id.json
  {
    jq -Sc . "$manifest" || return 1
    mapfile -t sources < <(jq -r '.. | objects | select(.type? == "file" and has("path")) | .path' "$manifest")
    for source in "${sources[@]}"; do
      printf '%s\0' "$source"
      sha256sum < "$root/packages/$package/$source" || return 1
    done
  } | sha256sum | cut -d ' ' -f 1
}

# Validate exactly the selected artifacts before modifying the signed repo.
verify_package_artifacts()
{
  local directory=$1 matrix=$2 artifact expected actual count
  expected=$(jq -er '.include | map(.package + "-" + .arch) | sort | .[]' <<< "$matrix") || return 1
  actual=$(find "$directory" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  if [ "$actual" != "$expected" ]; then
    echo 'Build artifacts do not match selected packages' >&2
    return 1
  fi
  for artifact in "$directory"/*; do
    count=$(find "$artifact" -type f -name '*.flatpak' | wc -l)
    if [ "$count" -ne 1 ]; then
      echo 'Expected one bundle per selected architecture' >&2
      return 1
    fi
    (cd "$artifact" && sha256sum --check SHA256SUMS) || return 1
  done
}

# Obtain the sole expected ref from the prepared, checksum-verified build plan.
package_artifact_ref()
{
  local matrix=$1 artifact=$2
  jq -er --arg artifact "$artifact" '[.include[] | select(.package + "-" + .arch == $artifact)] | select(length == 1) | .[0] | "app/" + .id + "/" + .arch + "/master"' <<< "$matrix"
}
