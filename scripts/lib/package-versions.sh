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
  if [ ! -f "$previous" ]; then return 0; fi
  for package in etcher ventoy; do
    old_version=$(jq -er --arg package "$package" '.[$package].version' "$previous") || return 1
    version=$(jq -er --arg package "$package" '.[$package].version' "$proposed") || return 1
    assert_package_version "$package" "$old_version" "$version" || return 1
  done
}
