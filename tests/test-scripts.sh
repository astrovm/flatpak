#!/usr/bin/env bash
# End-to-end tests for the publishing, verification, and health-check scripts.
# External tools (gh, gpg, ostree, flatpak, curl) are replaced by small mocks
# that keep their state in files, so the scripts run without network access.
set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scripts=$repository_root/scripts

temporary_directory=$(mktemp -d)
trap 'rm -rf -- "$temporary_directory"' EXIT

tests_run=0

pass()
{
  tests_run=$((tests_run + 1))
  printf 'ok %d - %s\n' "$tests_run" "$1"
}

fail()
{
  printf 'not ok - %s\n' "$1" >&2
  if [ -s "$temporary_directory/last-output" ]; then
    sed 's/^/# /' "$temporary_directory/last-output" >&2
  fi
  exit 1
}

# Run a command and require success.
expect_success()
{
  local name=$1
  shift

  if "$@" > "$temporary_directory/last-output" 2>&1; then
    pass "$name"
  else
    fail "$name"
  fi
}

# Run a command, require failure, and require a message in its output.
expect_failure()
{
  local name=$1
  local message=$2
  shift 2

  if "$@" > "$temporary_directory/last-output" 2>&1; then
    fail "$name unexpectedly succeeded"
  fi
  if ! grep -Fq -- "$message" "$temporary_directory/last-output"; then
    fail "$name did not report: $message"
  fi
  pass "$name"
}

mock_bin=$temporary_directory/mock-bin
mkdir "$mock_bin"

# The quoted heredocs below write mocks that expand their own arguments.
cat > "$mock_bin/gpg" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  case "$argument" in
    --import)
      cat > /dev/null
      exit 0
      ;;
    --list-secret-keys)
      if [ -n "${MOCK_GPG_MISSING_KEY:-}" ]; then
        echo "gpg: error reading key: No secret key" >&2
        exit 2
      fi
      exit 0
      ;;
    --export)
      [ -n "${MOCK_GPG_EMPTY_EXPORT:-}" ] || printf 'public key for %s\n' "${!#}"
      exit 0
      ;;
  esac
done
exit 1
EOF

cat > "$mock_bin/gh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "api repos/"*)
    cat "$MOCK_RELEASE_METADATA"
    ;;
  "release download")
    directory=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --dir ]; then
        directory=$2
      fi
      shift
    done
    cp "$MOCK_BUNDLES"/*.flatpak "$directory/"
    ;;
  *)
    exit 1
    ;;
esac
EOF

# Repositories are directories with a config file and a refs list; a bundle's
# content is the ref it contains.
cat > "$mock_bin/ostree" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
repository=""
for argument in "$@"; do
  case "$argument" in
    --repo=*) repository=${argument#--repo=} ;;
  esac
done
case "$1" in
  init)
    mkdir -p "$repository"
    printf '[core]\nmode=archive-z2\n' > "$repository/config"
    touch "$repository/refs-list"
    ;;
  refs)
    sort -u "$repository/refs-list"
    ;;
  fsck)
    [ -z "${MOCK_OSTREE_CORRUPT:-}" ] || exit 1
    ;;
  summary)
    [ -s "$repository/summary" ]
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat > "$mock_bin/flatpak" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
command=$1
shift
positional=()
arch=""
for argument in "$@"; do
  case "$argument" in
    --arch=*) arch=${argument#--arch=} ;;
    --*) ;;
    *) positional+=("$argument") ;;
  esac
done
case "$command" in
  build-import-bundle)
    cat "${positional[1]}" >> "${positional[0]}/refs-list"
    ;;
  build-update-repo)
    repository=${positional[0]}
    for ref_arch in $(grep -o '/[^/]*/[^/]*$' "$repository/refs-list" | cut -d / -f 2 | sort -u); do
      printf 'appstream/%s\nappstream2/%s\n' "$ref_arch" "$ref_arch" >> "$repository/refs-list"
    done
    printf 'summary\n' > "$repository/summary"
    printf 'signature\n' > "$repository/summary.sig"
    ;;
  remote-add)
    mkdir -p "$XDG_DATA_HOME/remotes"
    case "${positional[1]}" in
      https://*) printf '%s\n' "${positional[1]}" > "$XDG_DATA_HOME/remotes/${positional[0]}" ;;
      *) sed -n 's/^Url=//p' "${positional[1]}" > "$XDG_DATA_HOME/remotes/${positional[0]}" ;;
    esac
    ;;
  remote-ls)
    url=$(cat "$XDG_DATA_HOME/remotes/${positional[0]}")
    case "$url" in
      file://*) refs=$(cat "${url#file://}refs-list") ;;
      *) refs=${MOCK_LIVE_REFS:-} ;;
    esac
    printf '%s\n' "$refs" | grep "^app/[^/]*/$arch/" | sort -u || true
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat > "$mock_bin/curl" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=${!#}
if [ -n "${MOCK_CURL_FAIL:-}" ] && [[ "$url" == *"$MOCK_CURL_FAIL"* ]]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
printf 'ok\n'
EOF

chmod +x "$mock_bin"/*

export PATH=$mock_bin:$PATH
export RUNNER_TEMP=$temporary_directory

refs_for_app()
{
  local app_id=$1
  local branch=$2
  shift 2
  local arch

  for arch in "$@"; do
    printf 'app/%s/%s/%s\n' "$app_id" "$arch" "$branch"
  done
}

all_registered_refs=$(
  refs_for_app io.github.astrovm.AdventureMods master x86_64 aarch64
  refs_for_app io.github.astrovm.PkgDeck master x86_64 aarch64
)

# Release fixtures for AdventureMods v1.2.3.
bundles=$temporary_directory/bundles
mkdir "$bundles"
refs_for_app io.github.astrovm.AdventureMods master x86_64 \
  > "$bundles/AdventureMods-v1.2.3-x86_64.flatpak"
refs_for_app io.github.astrovm.AdventureMods master aarch64 \
  > "$bundles/AdventureMods-v1.2.3-aarch64.flatpak"

write_release_metadata()
{
  local output=$1
  local bundle_directory=$2

  jq -n \
    --arg x86 "sha256:$(sha256sum "$bundle_directory/AdventureMods-v1.2.3-x86_64.flatpak" | cut -d ' ' -f 1)" \
    --arg arm "sha256:$(sha256sum "$bundle_directory/AdventureMods-v1.2.3-aarch64.flatpak" | cut -d ' ' -f 1)" \
    '{tag_name: "v1.2.3", draft: false, prerelease: false, immutable: true,
      assets: [
        {name: "AdventureMods-v1.2.3-x86_64.flatpak", digest: $x86},
        {name: "AdventureMods-v1.2.3-aarch64.flatpak", digest: $arm}
      ]}' > "$output"
}

release_metadata=$temporary_directory/release.json
write_release_metadata "$release_metadata" "$bundles"

export MOCK_RELEASE_METADATA=$release_metadata
export MOCK_BUNDLES=$bundles
export GH_TOKEN=synthetic-token
export FLATPAK_GPG_PRIVATE_KEY=synthetic-private-key
export FLATPAK_GPG_KEY_ID=ABCDEF0123456789

# A published site keeps the other applications' refs from earlier releases.
seed_site()
{
  local site=$1

  mkdir -p "$site/repo"
  printf '[core]\nmode=archive-z2\n' > "$site/repo/config"
  refs_for_app io.github.astrovm.PkgDeck master x86_64 aarch64 > "$site/repo/refs-list"
  mkdir -p "$site/.git"
  printf 'stale\n' > "$site/stale.html"
}

site=$temporary_directory/site
seed_site "$site"
expect_success \
  "a release is published into an existing repository and verified" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"

if ! grep -Fq "Verified signed Flatpak repository" "$temporary_directory/last-output" ||
  ! grep -Fq "Importing AdventureMods-v1.2.3-x86_64.flatpak as app/io.github.astrovm.AdventureMods/x86_64/master" \
    "$temporary_directory/last-output"; then
  fail "publishing did not report the imported bundles"
fi
if [ "$(sort -u "$site/repo/refs-list" | grep -c '^app/')" -ne 4 ] ||
  [ -e "$site/stale.html" ] || [ ! -d "$site/.git" ] ||
  [ "$(cat "$site/CNAME")" != "flatpak.4st.li" ] ||
  [ ! -f "$site/.nojekyll" ] ||
  ! grep -Fxq "public key for $FLATPAK_GPG_KEY_ID" "$site/astrovm.gpg"; then
  fail "published site content is incorrect"
fi
for directory in extensions objects refs/heads refs/mirrors refs/remotes state tmp; do
  [ -d "$site/repo/$directory" ] || fail "repository directory $directory was not created"
done
pass "published site keeps the repository and regenerates the rest"

expect_success \
  "a published site verifies on its own" \
  "$scripts/verify-repository.sh" "$site"

fresh_site=$temporary_directory/fresh-site
expect_failure \
  "a new repository must contain every registered application" \
  "Repository is missing expected ref: app/io.github.astrovm.PkgDeck" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$fresh_site"
[ -s "$fresh_site/repo/config" ] || fail "a new repository was not initialized"
pass "a new repository is initialized before validation"

expect_failure \
  "publishing requires three arguments" \
  "usage:" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3
expect_failure \
  "publishing requires a GitHub token" \
  "GH_TOKEN is required" \
  env -u GH_TOKEN "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"
expect_failure \
  "publishing requires signing configuration" \
  "FLATPAK_GPG_PRIVATE_KEY and FLATPAK_GPG_KEY_ID must be configured" \
  env FLATPAK_GPG_KEY_ID= "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"
expect_failure \
  "publishing requires the signing key to be importable" \
  "No secret key" \
  env MOCK_GPG_MISSING_KEY=1 "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"
expect_failure \
  "publishing requires an exportable public key" \
  "Failed to export the Flatpak repository public key" \
  env MOCK_GPG_EMPTY_EXPORT=1 "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"

prerelease_metadata=$temporary_directory/prerelease.json
jq '.prerelease = true' "$release_metadata" > "$prerelease_metadata"
expect_failure \
  "publishing rejects prereleases" \
  "must be published, immutable, and not a prerelease" \
  env MOCK_RELEASE_METADATA="$prerelease_metadata" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"

wrong_bundles=$temporary_directory/wrong-bundles
mkdir "$wrong_bundles"
refs_for_app io.github.astrovm.PkgDeck master x86_64 \
  > "$wrong_bundles/AdventureMods-v1.2.3-x86_64.flatpak"
cp "$bundles/AdventureMods-v1.2.3-aarch64.flatpak" "$wrong_bundles/"
wrong_metadata=$temporary_directory/wrong-release.json
write_release_metadata "$wrong_metadata" "$wrong_bundles"
expect_failure \
  "publishing rejects a bundle with another application's ref" \
  "contains an unexpected ref: app/io.github.astrovm.PkgDeck/x86_64/master" \
  env MOCK_RELEASE_METADATA="$wrong_metadata" MOCK_BUNDLES="$wrong_bundles" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"

expect_failure \
  "publishing refuses to write into the source checkout" \
  "Output directory cannot be the source repository" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$repository_root"

missing_bundles=$temporary_directory/missing-bundles
mkdir "$missing_bundles"
cp "$bundles/AdventureMods-v1.2.3-x86_64.flatpak" "$missing_bundles/"
printf 'other\n' > "$missing_bundles/Other.flatpak"
expect_failure \
  "bundle validation reports a missing release asset" \
  "Release is missing AdventureMods-v1.2.3-aarch64.flatpak" \
  env MOCK_BUNDLES="$missing_bundles" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"

no_asset_metadata=$temporary_directory/no-asset.json
jq '.assets |= map(select(.name | endswith("aarch64.flatpak") | not))' \
  "$release_metadata" > "$no_asset_metadata"
expect_failure \
  "bundle validation needs a release asset per architecture" \
  "Release needs one Flatpak bundle for astrovm/AdventureMods on aarch64" \
  env MOCK_RELEASE_METADATA="$no_asset_metadata" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"

bad_digest_metadata=$temporary_directory/bad-digest.json
jq '.assets[0].digest = "md5:0123"' "$release_metadata" > "$bad_digest_metadata"
expect_failure \
  "bundle validation rejects malformed digests" \
  "Release metadata has an invalid digest for AdventureMods-v1.2.3-x86_64.flatpak" \
  env MOCK_RELEASE_METADATA="$bad_digest_metadata" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"

no_digest_metadata=$temporary_directory/no-digest.json
jq 'del(.assets[0].digest)' "$release_metadata" > "$no_digest_metadata"
expect_failure \
  "bundle validation requires a digest" \
  "Release metadata has no unique digest for AdventureMods-v1.2.3-x86_64.flatpak" \
  env MOCK_RELEASE_METADATA="$no_digest_metadata" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"

# Repository validation of unexpected refs.
validate_refs()
{
  local refs=$1
  local repository=$temporary_directory/refs-repository

  mkdir -p "$repository"
  printf '%s\n' "$refs" > "$repository/refs-list"
  bash -c 'source "$1"; validate_repository_refs "$2"' \
    _ "$scripts/lib/publish-common.sh" "$repository"
}

expect_success \
  "repository validation accepts AppStream refs" \
  validate_refs "$all_registered_refs"$'\nappstream/x86_64\nappstream2/aarch64'
expect_failure \
  "repository validation rejects runtime refs" \
  "unexpected runtime ref: runtime/org.example.Platform/x86_64/1" \
  validate_refs "$all_registered_refs"$'\nruntime/org.example.Platform/x86_64/1'
expect_failure \
  "repository validation rejects AppStream refs for other architectures" \
  "unexpected AppStream ref: appstream/riscv64" \
  validate_refs "$all_registered_refs"$'\nappstream/riscv64'
expect_failure \
  "repository validation rejects unknown ref kinds" \
  "unexpected ref: ostree-metadata" \
  validate_refs "$all_registered_refs"$'\nostree-metadata'

# The subshell expands its own positional parameter.
# shellcheck disable=SC2016
expect_failure \
  "an empty output directory argument is rejected" \
  "Output directory is required" \
  bash -c 'source "$1"; validate_output_directory ""' _ "$scripts/lib/publish-common.sh"

# Repository verification failures.
broken_site=$temporary_directory/broken-site
cp -R "$site" "$broken_site"
rm "$broken_site/repo/summary.sig"
expect_failure \
  "verification requires a signed summary" \
  "Generated repository file is missing or empty: $broken_site/repo/summary.sig" \
  "$scripts/verify-repository.sh" "$broken_site"

rm -rf "$broken_site"
cp -R "$site" "$broken_site"
rm "$broken_site/apps/io.github.astrovm.PkgDeck/install/index.html"
expect_failure \
  "verification requires every application page" \
  "Generated application files are missing or empty for io.github.astrovm.PkgDeck" \
  "$scripts/verify-repository.sh" "$broken_site"

rm -rf "$broken_site"
cp -R "$site" "$broken_site"
printf 'rotated key\n' > "$broken_site/astrovm.gpg"
expect_failure \
  "verification requires descriptors to embed the published key" \
  "Embedded GPG key does not match astrovm.gpg" \
  "$scripts/verify-repository.sh" "$broken_site"

rm -rf "$broken_site"
cp -R "$site" "$broken_site"
grep -v '/aarch64/' "$site/repo/refs-list" > "$broken_site/repo/refs-list"
expect_failure \
  "verification detects missing refs" \
  "Repository is missing expected ref" \
  "$scripts/verify-repository.sh" "$broken_site"

# The client check catches refs that the repository summary would not serve.
client_mock=$temporary_directory/client-mock
mkdir "$client_mock"
cat > "$client_mock/flatpak" << EOF
#!/usr/bin/env bash
if [ "\$1" = remote-ls ]; then
  exit 0
fi
exec "$mock_bin/flatpak" "\$@"
EOF
chmod +x "$client_mock/flatpak"
expect_failure \
  "verification compares the refs a client receives" \
  "Flatpak client received unexpected refs for aarch64" \
  env PATH="$client_mock:$PATH" "$scripts/verify-repository.sh" "$site"

expect_failure \
  "verification requires one argument" \
  "usage:" \
  "$scripts/verify-repository.sh"

# Live repository health check.
export MOCK_LIVE_REFS=$all_registered_refs
expect_success "the live repository health check passes" "$scripts/check-live.sh"
grep -Fq "Published repository is healthy" "$temporary_directory/last-output" ||
  fail "health check did not report success"
pass "health check reports a healthy repository"

expect_failure \
  "the health check fails when an install page is missing" \
  "The requested URL returned error: 404" \
  env MOCK_CURL_FAIL=/apps/io.github.astrovm.PkgDeck/install/ "$scripts/check-live.sh"
expect_failure \
  "the health check fails when the live repository lacks refs" \
  "Published repository has unexpected refs for aarch64" \
  env MOCK_LIVE_REFS="$(grep -v aarch64 <<< "$all_registered_refs")" "$scripts/check-live.sh"

# Site rendering and request resolution argument checks.
expect_failure \
  "site rendering requires two arguments" \
  "usage:" \
  "$scripts/render-site.sh" "$site/astrovm.gpg"
: > "$temporary_directory/empty-key.gpg"
expect_failure \
  "site rendering rejects an empty public key" \
  "Public key is empty" \
  "$scripts/render-site.sh" "$temporary_directory/empty-key.gpg" "$temporary_directory/render"
expect_failure \
  "request resolution requires two arguments" \
  "usage:" \
  "$scripts/resolve-request.sh" workflow_dispatch
expect_failure \
  "request resolution rejects other events" \
  "Unsupported publication event: push" \
  "$scripts/resolve-request.sh" push "$temporary_directory/request-output"

dispatch_output=$temporary_directory/dispatch-output
expect_success \
  "repository dispatch with an explicit tag is accepted" \
  env DISPATCH_REPOSITORY=astrovm/PkgDeck DISPATCH_TAG=v2.0.0 \
  "$scripts/resolve-request.sh" repository_dispatch "$dispatch_output"
grep -Fxq "tag=v2.0.0" "$dispatch_output" || fail "dispatch tag was not emitted"
pass "repository dispatch emits the requested tag"

printf '1..%d\n' "$tests_run"
