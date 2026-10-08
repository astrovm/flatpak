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
  *) exit 1 ;;
esac
MOCK
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"
source_root=$work/source\ with\ spaces
updater=$root/scripts/update-packages.sh
reset_source()
{
  rm -rf "$source_root/packages"
  cp -a "$root/packages" "$source_root/packages"
  rm -f "$work/output"
}
fixtures()
{
  for package in etcher ventoy; do
    if [ "$package" = etcher ]; then
      repository=balena-io/etcher
      asset=balenaEtcher-linux-x64-99.0.1.zip
    else
      repository=ventoy/Ventoy
      asset=ventoy-99.0.1-linux.tar.gz
    fi
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
sed -n 's/^matrix=//p' "$work/output" | jq -e '.include | length == 3' >/dev/null
cp "$source_root/packages/releases.json" "$work/previous.json"
rm "$work/output"
bash "$updater" "$source_root" pinned "$work/output" "$work/previous.json"
grep -Fxq changed=false "$work/output"

reset_source
fixtures
bash "$updater" "$source_root" latest "$work/output" "$work/previous.json"
grep -Fxq changed=true "$work/output"
sed -n 's/^matrix=//p' "$work/output" | jq -e 'all(.include[]; .version == "99.0.1")' >/dev/null
for package in etcher ventoy; do
  grep -q 'version="99.0.1" date="2026-10-08"' "$source_root/packages/$package/"*.metainfo.xml
  jq -e '[.modules[].sources[] | select(.type == "archive")][0] | .sha256 == ("a"*64) and (.url | contains("/v99.0.1/"))' "$source_root/packages/$package/"*.json >/dev/null
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
expect_failure bash "$updater" "$source_root" latest "$work/output" "$work/newer.json"
grep -q 'Refusing to downgrade' "$work/error"
assert_unchanged
printf 'not json\n' > "$work/etcher.json"
expect_failure bash "$updater" "$source_root" latest "$work/output"
assert_unchanged
reset_source
fixtures
sed -i 's/99\.0\.1/0.0.1/g' "$work/etcher.json"
expect_failure bash "$updater" "$source_root" latest "$work/output"
grep -q 'Refusing to downgrade' "$work/error"
assert_unchanged

# Execute the actual manifest patch against the reviewed upstream function.
python3 - "$root" "$work" <<'PY'
import json
from pathlib import Path
import shlex
import subprocess
import sys

root, work = map(Path, sys.argv[1:])
manifest = json.loads((root / 'packages/etcher/io.github.astrovm.Etcher.json').read_text())
command = shlex.split(manifest['modules'][-1]['build-commands'][-1])
archive = work / 'app.asar'
code = command[-1].replace('/app/etcher/resources/app.asar', str(archive))
upstream = (root / 'tests/fixtures/etcher-linux-elevation.js').read_bytes()
archive.write_bytes(upstream)
subprocess.run(['python3', '-c', code], check=True)
assert b'/app/bin/pkexec' in archive.read_bytes()
assert b'/usr/bin/pkexec' not in archive.read_bytes()
changed = upstream.replace(b'--disable-internal-agent', b'--changed-internal-agent')
archive.write_bytes(changed)
result = subprocess.run(['python3', '-c', code], capture_output=True, text=True)
assert result.returncode != 0 and 'Etcher elevation contract changed' in result.stderr
assert archive.read_bytes() == changed
PY
echo 'ok - release updates are pinned, atomic, idempotent and reject malformed releases, downgrades and API failures'
