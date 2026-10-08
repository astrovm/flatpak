#!/usr/bin/env bash
# Resolve stable upstream releases into checksum-pinned, reproducible recipes.
set -euo pipefail
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/package-versions.sh
source "$script_directory/lib/package-versions.sh"
root=${1:-}
mode=${2:-}
output=${3:-}
previous=${4:-}
previous_recipes=${5:-}
rebuild=${6:-false}
if [ -z "$root" ] || [[ "$mode" != pinned && "$mode" != latest ]] || [ -z "$output" ]; then
  echo 'Usage: update-packages.sh ROOT pinned|latest OUTPUT [PREVIOUS_RELEASES] [PREVIOUS_RECIPES] [REBUILD]' >&2
  exit 2
fi
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp -a "$root/packages" "$work/packages"
cp -a "$root/scripts" "$work/scripts"
printf '[]\n' > "$work/changed.json"
printf '{}\n' > "$work/releases.json"
if [ -f "$previous" ]; then jq -e 'type == "object"' "$previous" >/dev/null; fi
mapfile -t entries < <(jq -c '.[]' "$work/packages/catalog.json")
for entry in "${entries[@]}"; do
  package=$(jq -r .package <<< "$entry")
  upstream=$(jq -r .upstream <<< "$entry")
  asset_prefix=$(jq -r .asset_prefix <<< "$entry")
  asset_suffix=$(jq -r .asset_suffix <<< "$entry")
  asset_version=$(jq -r '.asset_version | if . == null then true else . end' <<< "$entry")
  mapfile -t targets < <(jq -r '.targets // [.package] | .[]' <<< "$entry")
  target=${targets[0]}
  id=$(jq -r --arg package "$target" '.[] | select(.package == $package) | .id' "$work/packages/catalog.json")
  source_prefix=https://github.com/$upstream/releases/download/
  manifest=$work/packages/$target/$id.json
  if [ "$mode" = latest ]; then
    gh api "repos/$upstream/releases/latest" > "$work/release.json"
    # Require exactly one matching asset with a GitHub-provided SHA-256 digest.
    jq -e --arg upstream "$upstream" --arg prefix "$asset_prefix" --arg suffix "$asset_suffix" --arg asset_version "$asset_version" -f /dev/stdin "$work/release.json" > "$work/resolved.json" <<'JQ'
select(.draft == false and .prerelease == false)
| select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
| . as $release
| ($release.tag_name | ltrimstr("v")) as $version
| ($prefix + (if $asset_version == "false" then "" else $version end) + $suffix) as $name
| [.assets[] | select(.name == $name)]
| select(length == 1) | .[0]
| select(.digest | type == "string")
| select(.digest | test("^sha256:[0-9a-f]{64}$"))
| select(.browser_download_url == ("https://github.com/" + $upstream + "/releases/download/" + $release.tag_name + "/" + $name))
| {version: $version, url: .browser_download_url, sha256: (.digest | ltrimstr("sha256:")), date: ($release.published_at | strptime("%Y-%m-%dT%H:%M:%SZ") | strftime("%Y-%m-%d"))}
JQ
    version=$(jq -r .version "$work/resolved.json")
    old_version=$(jq -r --arg prefix "$source_prefix" '.modules[].sources[] | select(.url? | strings | startswith($prefix)) | .url | capture("/v(?<version>[0-9]+\\.[0-9]+\\.[0-9]+)/").version' "$manifest")
    if [ -f "$previous" ] && jq -e --arg package "$package" 'has($package)' "$previous" >/dev/null; then
      old_version=$(jq -er --arg package "$package" '.[$package].version' "$previous")
    fi
    assert_package_version "$package" "$old_version" "$version"
    for target in "${targets[@]}"; do
      id=$(jq -r --arg package "$target" '.[] | select(.package == $package) | .id' "$work/packages/catalog.json")
      manifest=$work/packages/$target/$id.json
      jq --arg prefix "$source_prefix" --slurpfile release "$work/resolved.json" '(.modules[].sources[] | select(.url? | strings | startswith($prefix))) |= (.url = $release[0].url | .sha256 = $release[0].sha256)' "$manifest" > "$work/manifest.json"
      mv "$work/manifest.json" "$manifest"
    done
    if [ "$package" != adb ]; then
      release_date=$(jq -r .date "$work/resolved.json")
      sed -i -E "s/<release version=\"[^\"]+\" date=\"[^\"]+\"\//<release version=\"$version\" date=\"$release_date\"\//" "$work/packages/$package/$id.metainfo.xml"
    fi
  fi
  jq -e --arg prefix "$source_prefix" '[.modules[].sources[] | select(.url? | strings | startswith($prefix))] | select(length == 1) | .[0] | {version: (.url | capture("/v(?<version>[0-9]+\\.[0-9]+\\.[0-9]+)/").version), sha256}' "$manifest" > "$work/record.json"
  jq --arg package "$package" --slurpfile record "$work/record.json" '.[$package] = $record[0]' "$work/releases.json" > "$work/next.json"
  mv "$work/next.json" "$work/releases.json"
done
# Resolve dependencies before hashing apps so a shared ADB change selects both.
mapfile -t entries < <(jq -c '.[] | select(has("id"))' "$work/packages/catalog.json")
for entry in "${entries[@]}"; do
  package=$(jq -r .package <<< "$entry")
  id=$(jq -r .id <<< "$entry")
  jq --arg package "$package" '.[$package]' "$work/releases.json" > "$work/record.json"
  digest=$(package_recipe_digest "$work" "$package" "$id")
  jq --arg digest "$digest" '.recipe_sha256 = $digest' "$work/record.json" > "$work/digest.json"
  mv "$work/digest.json" "$work/record.json"
  old_digest=
  if [ -f "$previous" ]; then
    old_digest=$(jq -r --arg package "$package" '.[$package].recipe_sha256 // empty' "$previous")
    # Bootstrap existing publications without rebuilding an unchanged tool.
    if [ -z "$old_digest" ] && [ -f "$previous_recipes/packages/$package/$id.json" ]; then
      old_digest=$(package_recipe_digest "$previous_recipes" "$package" "$id")
    fi
  fi
  if [ "$rebuild" = true ] || [ "$digest" != "$old_digest" ]; then
    jq --arg package "$package" '. + [$package]' "$work/changed.json" > "$work/next.json"
    mv "$work/next.json" "$work/changed.json"
  fi
  jq --arg package "$package" --slurpfile record "$work/record.json" '.[$package] = $record[0]' "$work/releases.json" > "$work/next.json"
  mv "$work/next.json" "$work/releases.json"
done
changed=false
if [ "$(jq length "$work/changed.json")" -gt 0 ]; then changed=true; fi
cp -a "$work/packages/." "$root/packages/"
cp "$work/releases.json" "$root/packages/releases.json"
printf 'changed=%s\n' "$changed" >> "$output"
jq -cr --slurpfile changed "$work/changed.json" --slurpfile catalog "$work/packages/catalog.json" -f /dev/stdin "$work/releases.json" >> "$output" <<'JQ'
. as $releases
| {include: [$catalog[0][] | select(has("id")) | . as $app
  | select(.package as $package | $changed[0] | index($package))
  | .architectures[] | {package: $app.package, id: $app.id,
      version: $releases[$app.package].version, arch: .,
      runner: (if . == "aarch64" then "ubuntu-24.04-arm" else "ubuntu-26.04" end)}]}
| "matrix=" + tojson
JQ
