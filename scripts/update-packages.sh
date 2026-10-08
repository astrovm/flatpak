#!/usr/bin/env bash
# Resolve stable upstream releases into checksum-pinned, reproducible recipes.
set -euo pipefail
root=${1:-}
mode=${2:-}
output=${3:-}
previous=${4:-}
if [ -z "$root" ] || [[ "$mode" != pinned && "$mode" != latest ]] || [ -z "$output" ]; then
  echo 'Usage: update-packages.sh ROOT pinned|latest OUTPUT [PREVIOUS_RELEASES]' >&2
  exit 2
fi
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp -a "$root/packages" "$work/packages"
printf '{}\n' > "$work/releases.json"
for package in etcher ventoy; do
  if [ "$package" = etcher ]; then
    upstream=balena-io/etcher
    id=io.github.astrovm.Etcher
    asset_prefix=balenaEtcher-linux-x64-
    asset_suffix=.zip
  else
    upstream=ventoy/Ventoy
    id=io.github.astrovm.Ventoy
    asset_prefix=ventoy-
    asset_suffix=-linux.tar.gz
  fi
  manifest=$work/packages/$package/$id.json
  if [ "$mode" = latest ]; then
    gh api "repos/$upstream/releases/latest" > "$work/release.json"
    # Require exactly one matching asset with a GitHub-provided SHA-256 digest.
    jq -e --arg upstream "$upstream" --arg prefix "$asset_prefix" --arg suffix "$asset_suffix" -f /dev/stdin "$work/release.json" > "$work/resolved.json" <<'JQ'
select(.draft == false and .prerelease == false)
| select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
| . as $release
| ($release.tag_name | ltrimstr("v")) as $version
| ($prefix + $version + $suffix) as $name
| [.assets[] | select(.name == $name)]
| select(length == 1) | .[0]
| select(.digest | type == "string")
| select(.digest | test("^sha256:[0-9a-f]{64}$"))
| select(.browser_download_url == ("https://github.com/" + $upstream + "/releases/download/" + $release.tag_name + "/" + $name))
| {version: $version, url: .browser_download_url, sha256: (.digest | ltrimstr("sha256:")), date: ($release.published_at | strptime("%Y-%m-%dT%H:%M:%SZ") | strftime("%Y-%m-%d"))}
JQ
    version=$(jq -r .version "$work/resolved.json")
    old_version=$(jq -r '.modules[].sources[] | select(.type == "archive") | .url | capture("/v(?<version>[0-9]+\\.[0-9]+\\.[0-9]+)/").version' "$manifest")
    if [ -f "$previous" ]; then
      old_version=$(jq -er --arg package "$package" '.[$package].version' "$previous")
    fi
    if [ "$(printf '%s\n' "$old_version" "$version" | sort -V | tail -1)" != "$version" ]; then
      echo "Refusing to downgrade $package from $old_version to $version" >&2
      exit 1
    fi
    jq --slurpfile release "$work/resolved.json" '(.modules[].sources[] | select(.type == "archive")) |= (.url = $release[0].url | .sha256 = $release[0].sha256)' "$manifest" > "$work/manifest.json"
    mv "$work/manifest.json" "$manifest"
    release_date=$(jq -r .date "$work/resolved.json")
    sed -i -E "s/<release version=\"[^\"]+\" date=\"[^\"]+\"\//<release version=\"$version\" date=\"$release_date\"\//" "$work/packages/$package/$id.metainfo.xml"
  fi
  jq -e '[.modules[].sources[] | select(.type == "archive")] | select(length == 1) | .[0] | {version: (.url | capture("/v(?<version>[0-9]+\\.[0-9]+\\.[0-9]+)/").version), sha256}' "$manifest" > "$work/record.json"
  jq --arg package "$package" --slurpfile record "$work/record.json" '.[$package] = $record[0]' "$work/releases.json" > "$work/next.json"
  mv "$work/next.json" "$work/releases.json"
done
changed=true
if [ -f "$previous" ] && diff -q <(jq -S . "$previous") <(jq -S . "$work/releases.json") >/dev/null; then
  changed=false
fi
cp -a "$work/packages/." "$root/packages/"
cp "$work/releases.json" "$root/packages/releases.json"
printf 'changed=%s\n' "$changed" >> "$output"
jq -cr -f /dev/stdin "$work/releases.json" >> "$output" <<'JQ'
{include: [
  {package: "etcher", id: "io.github.astrovm.Etcher", version: .etcher.version, arch: "x86_64", runner: "ubuntu-26.04"},
  {package: "ventoy", id: "io.github.astrovm.Ventoy", version: .ventoy.version, arch: "x86_64", runner: "ubuntu-26.04"},
  {package: "ventoy", id: "io.github.astrovm.Ventoy", version: .ventoy.version, arch: "aarch64", runner: "ubuntu-24.04-arm"}
]} | "matrix=" + tojson
JQ
