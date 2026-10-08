#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/source with spaces"
export RELEASE_FIXTURES=$work
cat > "$work/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "${MOCK_API_FAILURE:-false}" = true ]; then
  echo 'API request failed' >&2
  exit 1
fi
case "$*" in
  'api repos/balena-io/etcher/releases/latest') cat "$RELEASE_FIXTURES/etcher.json" ;;
  'api repos/ventoy/Ventoy/releases/latest') cat "$RELEASE_FIXTURES/ventoy.json" ;;
  'api repos/barry-ran/QtScrcpy/releases/latest') cat "$RELEASE_FIXTURES/qtscrcpy.json" ;;
  'api repos/Universal-Debloater-Alliance/universal-android-debloater-next-generation/releases/latest') cat "$RELEASE_FIXTURES/uadng.json" ;;
  'api repos/Genymobile/scrcpy/releases/latest') cat "$RELEASE_FIXTURES/adb.json" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"
source_root="$work/source with spaces"
updater=$root/scripts/update-packages.sh
# shellcheck source=scripts/lib/package-versions.sh
source "$root/scripts/lib/package-versions.sh"
reset_source()
{
  rm -rf "$source_root/packages" "$source_root/scripts"
  cp -a "$root/scripts" "$source_root/scripts"
  cp -a "$root/packages" "$source_root/packages"
  rm -f "$work/output"
}
fixtures()
{
  local package repository asset
  for package in etcher ventoy qtscrcpy uadng adb; do
    case "$package" in
      etcher) repository=balena-io/etcher; asset=balenaEtcher-linux-x64-99.0.1.zip ;;
      ventoy) repository=ventoy/Ventoy; asset=ventoy-99.0.1-linux.tar.gz ;;
      qtscrcpy) repository=barry-ran/QtScrcpy; asset=QtScrcpy-ubuntu-x64-v99.0.1.AppImage ;;
      uadng) repository=Universal-Debloater-Alliance/universal-android-debloater-next-generation; asset=uad-ng-noselfupdate-linux.tar.gz ;;
      adb) repository=Genymobile/scrcpy; asset=scrcpy-linux-x86_64-v99.0.1.tar.gz ;;
    esac
    jq -n --arg asset "$asset" --arg repository "$repository" \
      '{tag_name:"v99.0.1",draft:false,prerelease:false,published_at:"2026-10-08T12:00:00Z",assets:[{name:$asset,browser_download_url:("https://github.com/"+$repository+"/releases/download/v99.0.1/"+$asset),digest:("sha256:"+("a"*64))}]}' > "$work/$package.json"
  done
}
expect_failure()
{
  if "$@" > "$work/error" 2>&1; then
    echo 'Expected updater to fail' >&2
    exit 1
  fi
}
assert_unchanged()
{
  diff -r "$root/packages" "$source_root/packages"
  test ! -e "$work/output"
}
expect_failure bash "$updater"
expect_failure bash "$updater" "$source_root" invalid "$work/output"
expect_failure bash "$updater" "$source_root" pinned
reset_source
bash "$updater" "$source_root" pinned "$work/output"
grep -Fxq changed=true "$work/output"
sed -n 's/^matrix=//p' "$work/output" | jq -e '.include | length == 5' >/dev/null
cp "$source_root/packages/releases.json" "$work/previous.json"
cp "$work/previous.json" "$work/pinned-previous.json"
verify_package_versions "$work/previous.json" "$work/missing.json"
verify_package_versions "$work/previous.json" "$work/previous.json"
rm "$work/output"
bash "$updater" "$source_root" pinned "$work/output" "$work/previous.json"
grep -Fxq changed=false "$work/output"

sed -n 's/^matrix=//p' "$work/output" | jq -e '.include == []' >/dev/null
rm "$work/output"
bash "$updater" "$source_root" pinned "$work/output" "$work/previous.json" "" true
sed -n 's/^matrix=//p' "$work/output" | jq -e '.include | length == 5' >/dev/null
printf 'wrong json\n' > "$work/invalid.json"
mkdir -p "$work/bad/packages/etcher"
cp "$work/invalid.json" "$work/bad/packages/etcher/io.github.astrovm.Etcher.json"
expect_failure package_recipe_digest "$work/bad" etcher io.github.astrovm.Etcher
reset_source
jq -c . "$source_root/packages/ventoy/io.github.astrovm.Ventoy.json" > "$work/compact.json"
mv "$work/compact.json" "$source_root/packages/ventoy/io.github.astrovm.Ventoy.json"
bash "$updater" "$source_root" pinned "$work/output" "$work/previous.json"
grep -Fxq changed=false "$work/output"
# A launcher or metadata change must build only its owning package.
for input in scripts/etcher-launch.sh packages/etcher/io.github.astrovm.Etcher.metainfo.xml; do
  reset_source
  printf '\n# changed input\n' >> "$source_root/$input"
  bash "$updater" "$source_root" pinned "$work/output" "$work/previous.json"
  sed -n 's/^matrix=//p' "$work/output" | jq -e '.include | length == 1 and .[0].package == "etcher"' >/dev/null
done
reset_source
printf '\n# changed input\n' >> "$source_root/scripts/ventoy-launch.sh"
bash "$updater" "$source_root" pinned "$work/output" "$work/previous.json"
sed -n 's/^matrix=//p' "$work/output" | jq -e '.include | length == 2 and all(.[]; .package == "ventoy")' >/dev/null
# Migrate the published snapshot without a redundant Ventoy update.
jq 'map_values(del(.recipe_sha256))' "$work/previous.json" > "$work/legacy.json"
reset_source
bash "$updater" "$source_root" pinned "$work/output" "$work/legacy.json" "$root"
grep -Fxq changed=false "$work/output"
reset_source
bash "$updater" "$source_root" pinned "$work/output" "$work/legacy.json"
sed -n 's/^matrix=//p' "$work/output" | jq -e '.include | length == 5' >/dev/null
# Missing build inputs fail before either package is updated.
reset_source
rm "$source_root/scripts/ventoy-launch.sh"
expect_failure bash "$updater" "$source_root" pinned "$work/output"
assert_unchanged

reset_source
fixtures
bash "$updater" "$source_root" latest "$work/output" "$work/previous.json"
grep -Fxq changed=true "$work/output"
sed -n 's/^matrix=//p' "$work/output" | jq -e 'all(.include[]; .version == "99.0.1")' >/dev/null
for package in etcher ventoy qtscrcpy uadng; do
  grep -q 'version="99.0.1" date="2026-10-08"' "$source_root/packages/$package/"*.metainfo.xml
  jq -e --arg upstream "$(jq -r --arg package "$package" '.[] | select(.package == $package) | .upstream' "$root/packages/catalog.json")" '[.modules[].sources[] | select(.url? | strings | contains($upstream + "/releases/download/"))][0] | .sha256 == ("a"*64) and (.url | contains("/v99.0.1/"))' "$source_root/packages/$package/"*.json >/dev/null
done
cp "$source_root/packages/releases.json" "$work/previous.json"
rm "$work/output"
bash "$updater" "$source_root" latest "$work/output" "$work/previous.json"
grep -Fxq changed=false "$work/output"
jq '.assets[0].digest = ("sha256:"+("b"*64))' "$work/ventoy.json" > "$work/changed.json"
mv "$work/changed.json" "$work/ventoy.json"
rm "$work/output"
bash "$updater" "$source_root" latest "$work/output" "$work/previous.json"
grep -Fxq changed=true "$work/output"
sed -n 's/^matrix=//p' "$work/output" | jq -e '.include | length == 2 and all(.[]; .package == "ventoy")' >/dev/null

# A failed second release resolution must not leave a partially updated first app.
for mutation in \
  '.draft = true' \
  '.prerelease = true' \
  '.tag_name = "v99.0.1-rc1"' \
  '.tag_name = "v99.0.1;echo wrong"' \
  '.tag_name = "😀"' \
  '.assets = []' \
  '.assets += .assets' \
  '.assets[0].digest = null' \
  '.assets[0].digest = "sha256:wrong"' \
  '.assets[0].browser_download_url = "https://example.com/file"' \
  '.published_at = "bad date"'; do
  reset_source
  fixtures
  jq "$mutation" "$work/ventoy.json" > "$work/bad.json"
  mv "$work/bad.json" "$work/ventoy.json"
  expect_failure bash "$updater" "$source_root" latest "$work/output"
  assert_unchanged
done
reset_source
fixtures
expect_failure env MOCK_API_FAILURE=true bash "$updater" "$source_root" latest "$work/output"
assert_unchanged
jq '.etcher.version = "99.0.2"' "$work/previous.json" > "$work/newer.json"
expect_failure verify_package_versions "$work/previous.json" "$work/newer.json"
expect_failure bash "$updater" "$source_root" latest "$work/output" "$work/newer.json"
grep -q 'Refusing to downgrade' "$work/error"
assert_unchanged
expect_failure assert_package_version etcher wrong 1.0.0
expect_failure assert_package_version etcher 1.0.0 wrong
printf '{}\n' > "$work/missing-version.json"
expect_failure verify_package_versions "$work/previous.json" "$work/missing-version.json"
expect_failure verify_package_versions "$work/missing-version.json" "$work/previous.json"
printf 'not json\n' > "$work/etcher.json"
expect_failure bash "$updater" "$source_root" latest "$work/output"
assert_unchanged
reset_source
fixtures
sed -i 's/99\.0\.1/0.0.1/g' "$work/etcher.json"
expect_failure bash "$updater" "$source_root" latest "$work/output"
grep -q 'Refusing to downgrade' "$work/error"
assert_unchanged


# Existing publications gain the two new apps without rebuilding either USB tool.
reset_source
jq '{etcher, ventoy}' "$work/pinned-previous.json" > "$work/old-apps.json"
bash "$updater" "$source_root" pinned "$work/output" "$work/old-apps.json"
sed -n 's/^matrix=//p' "$work/output" | jq -e '.include | map(.package) == ["qtscrcpy", "uadng"]' >/dev/null
verify_package_versions "$source_root/packages/releases.json" "$work/old-apps.json"
for package in qtscrcpy uadng; do
  reset_source
  printf '\n# changed input\n' >> "$source_root/scripts/$package-launch.sh"
  bash "$updater" "$source_root" pinned "$work/output" "$work/pinned-previous.json"
  sed -n 's/^matrix=//p' "$work/output" | jq -e --arg package "$package" '.include | length == 1 and .[0].package == $package' >/dev/null
done
# A dependency-only update selects both Android apps, preserving their versions.
reset_source
fixtures
bash "$updater" "$source_root" latest "$work/output"
cp "$source_root/packages/releases.json" "$work/dependency-previous.json"
jq '.assets[0].digest = ("sha256:"+("c"*64))' "$work/adb.json" > "$work/new-adb.json"
mv "$work/new-adb.json" "$work/adb.json"
rm "$work/output"
bash "$updater" "$source_root" latest "$work/output" "$work/dependency-previous.json"
sed -n 's/^matrix=//p' "$work/output" | jq -e '.include | map(.package) == ["qtscrcpy", "uadng"] and all(.[]; .version == "99.0.1")' >/dev/null
# App-only upstream changes do not replace ADB or rebuild other apps.
for package in qtscrcpy uadng; do
  reset_source
  fixtures
  bash "$updater" "$source_root" latest "$work/output"
  cp "$source_root/packages/releases.json" "$work/app-previous.json"
  jq '.tag_name = "v99.0.2" | .assets[0].browser_download_url |= sub("/v99.0.1/"; "/v99.0.2/")' "$work/$package.json" > "$work/app-release.json"
  if [ "$package" = qtscrcpy ]; then
    jq '.assets[0].name |= sub("v99.0.1"; "v99.0.2") | .assets[0].browser_download_url |= sub("v99.0.1.AppImage"; "v99.0.2.AppImage")' "$work/app-release.json" > "$work/$package.json"
  else
    mv "$work/app-release.json" "$work/$package.json"
  fi
  rm "$work/output"
  bash "$updater" "$source_root" latest "$work/output" "$work/app-previous.json"
  sed -n 's/^matrix=//p' "$work/output" | jq -e --arg package "$package" '.include | length == 1 and .[0].package == $package and .[0].version == "99.0.2"' >/dev/null
  jq -e '.adb.version == "99.0.1"' "$source_root/packages/releases.json" >/dev/null
  jq -e '[.modules[].sources[] | select(.url? | strings | contains("Genymobile/scrcpy"))][0].url | contains("/v99.0.1/")' "$source_root/packages/$package/"*.json >/dev/null
done
jq '.adb.version = "0.0.1"' "$work/dependency-previous.json" > "$work/adb-downgrade.json"
expect_failure verify_package_versions "$work/adb-downgrade.json" "$work/dependency-previous.json"
# Malformed saved publications and removed entries stop publication.
expect_failure verify_package_versions "$work/old-apps.json" "$work/dependency-previous.json"
expect_failure verify_package_versions "$work/previous.json" "$work/invalid.json"
reset_source
expect_failure bash "$updater" "$source_root" latest "$work/output" "$work/invalid.json"
assert_unchanged
# File downloads count as primary releases, and dependencies cannot be overwritten.
reset_source
jq '.modules[0].sources += [.modules[0].sources[] | select(.url? | strings | contains("barry-ran/QtScrcpy"))]' "$source_root/packages/qtscrcpy/io.github.astrovm.QtScrcpy.json" > "$work/duplicate.json"
mv "$work/duplicate.json" "$source_root/packages/qtscrcpy/io.github.astrovm.QtScrcpy.json"
expect_failure bash "$updater" "$source_root" latest "$work/output"
# A late dependency error leaves all earlier app recipes untouched.
reset_source
fixtures
jq '.assets = []' "$work/adb.json" > "$work/new-adb.json"
mv "$work/new-adb.json" "$work/adb.json"
expect_failure bash "$updater" "$source_root" latest "$work/output"
assert_unchanged
matrix='{"include":[{"package":"qtscrcpy","id":"io.github.astrovm.QtScrcpy","arch":"x86_64"}]}'
test "$(package_artifact_ref "$matrix" qtscrcpy-x86_64)" = app/io.github.astrovm.QtScrcpy/x86_64/master
expect_failure package_artifact_ref "$matrix" uadng-x86_64
expect_failure package_artifact_ref 'wrong' qtscrcpy-x86_64
expect_failure package_artifact_ref '{"include":[]}' qtscrcpy-x86_64
expect_failure package_artifact_ref "$(jq '.include += .include' <<< "$matrix")" qtscrcpy-x86_64

# Partial publication accepts one Etcher artifact and rejects incomplete,
# extra, corrupt or duplicate bundles before signing any repository changes.
mkdir -p "$work/bundles/etcher-x86_64"
printf 'bundle\n' > "$work/bundles/etcher-x86_64/test.flatpak"
(cd "$work/bundles/etcher-x86_64" && sha256sum test.flatpak > SHA256SUMS)
matrix='{"include":[{"package":"etcher","arch":"x86_64"}]}'
verify_package_artifacts "$work/bundles" "$matrix"
expect_failure verify_package_artifacts "$work/bundles" 'wrong'
expect_failure verify_package_artifacts "$work/bundles" '{"include":[]}'
expect_failure verify_package_artifacts "$work/bundles" '{"include":[{"package":"ventoy","arch":"aarch64"}]}'
printf 'extra\n' > "$work/bundles/etcher-x86_64/duplicate.flatpak"
expect_failure verify_package_artifacts "$work/bundles" "$matrix"
rm "$work/bundles/etcher-x86_64/duplicate.flatpak"
printf 'corrupt\n' >> "$work/bundles/etcher-x86_64/test.flatpak"
expect_failure verify_package_artifacts "$work/bundles" "$matrix"
rm "$work/bundles/etcher-x86_64/test.flatpak"
expect_failure verify_package_artifacts "$work/bundles" "$matrix"

# Execute the actual manifest patch against the reviewed upstream function.
python3 - "$root" "$work" <<'PY'
import json
import hashlib
from pathlib import Path
import shlex
import subprocess
import struct
import sys

root, work = map(Path, sys.argv[1:])
manifest = json.loads((root / 'packages/etcher/io.github.astrovm.Etcher.json').read_text())
command = shlex.split(manifest['modules'][-1]['build-commands'][-1])
archive = work / 'app.asar'
code = command[-1].replace('/app/etcher/resources/app.asar', str(archive))
contents = (root / 'tests/fixtures/etcher-linux-elevation.txt').read_bytes()
digest = hashlib.sha256(contents).hexdigest()
header = json.dumps({'files': {'index.js': {'offset': '0', 'size': len(contents), 'integrity': {
    'algorithm': 'SHA256', 'hash': digest, 'blockSize': 4194304, 'blocks': [digest],
}}}}, separators=(',', ':')).encode()
pickle_size = (4 + len(header) + 3) // 4 * 4
upstream = struct.pack('<4I', 4, 4 + pickle_size, pickle_size, len(header)) + header + bytes(pickle_size - 4 - len(header)) + contents
archive.write_bytes(upstream)
subprocess.run(['python3', '-c', code], check=True)
assert b'/app/bin/pkexec' in archive.read_bytes()
assert b'/usr/bin/pkexec' not in archive.read_bytes()
patched = archive.read_bytes()
assert len(patched) == len(upstream), 'ASAR offsets must not move'
patched_header = json.loads(patched[16:16 + len(header)])
data_start = 8 + struct.unpack_from('<I', patched, 4)[0]
assert patched_header['files']['index.js']['integrity']['hash'] == hashlib.sha256(patched[data_start:]).hexdigest()
assert b'setAsDefaultProtocolClient' not in patched
start = patched.index(b'(0,y.spawnChildAndConnect)')
end = patched.index(b';let C=!1', start)
fragment = patched[start:end].decode()
node_test = r'''
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const fragment = fs.readFileSync(0, 'utf8');
const handlers = {};
let metadata;
const t = {};
const context = {
  y: { spawnChildAndConnect: async () => ({
    registerHandler: (name, callback) => { handlers[name] = callback; },
    emit: (name) => {
      if (name === 'sourceMetadata') {
        // A fast local response must not race listener registration.
        assert.equal(typeof handlers[name], 'function');
        handlers[name](JSON.stringify(metadata));
      }
    },
  }) },
  t, h: { isFlashing: () => false }, p: { setDrives: () => {} },
  o: { values: Object.values }, Error, JSON, Promise,
};
(async () => {
  await vm.runInNewContext(fragment, context);
  for (const path of ['image with spaces.img.gz', 'imagen-ñ-😀.img']) {
    metadata = { path, extension: path.endsWith('gz') ? 'gz' : 'img', size: 1024 };
    assert.deepEqual(await t.requestMetadata({ selected: path, SourceType: 'File' }), metadata);
  }
  for (metadata of [null, [], 42, "wrong", {}, { path: 'missing.img' }, { extension: 'gz' }]) {
    await assert.rejects(t.requestMetadata({ selected: 'broken.img.gz', SourceType: 'File' }), /Cannot read image file/);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
subprocess.run(['node', '-e', node_test], input=fragment, text=True, check=True)
changed = upstream.replace(b'--disable-internal-agent', b'--changed-internal-agent')
archive.write_bytes(changed)
result = subprocess.run(['python3', '-c', code], capture_output=True, text=True)
assert result.returncode != 0 and 'Etcher elevation contract changed' in result.stderr
assert archive.read_bytes() == changed
changed = upstream.replace(b't.requestMetadata=async', b't.requestMetadata=changed')
archive.write_bytes(changed)
result = subprocess.run(['python3', '-c', code], capture_output=True, text=True)
assert result.returncode != 0 and 'Etcher image metadata contract changed' in result.stderr
assert archive.read_bytes() == changed
changed = upstream.replace(b'setAsDefaultProtocolClient', b'changedProtocolClient')
archive.write_bytes(changed)
result = subprocess.run(['python3', '-c', code], capture_output=True, text=True)
assert result.returncode != 0 and 'Etcher protocol registration changed' in result.stderr
assert archive.read_bytes() == changed
PY
echo 'ok - release updates are pinned, atomic, idempotent and reject malformed releases, downgrades and API failures'
