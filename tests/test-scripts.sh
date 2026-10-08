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
printf '%s\n' "$*" >> "${MOCK_GH_LOG:-/dev/null}"
case "$1 $2" in
  "release view")
    printf '%s\n' "$MOCK_LATEST_TAG"
    ;;
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
    if [ -n "${MOCK_OSTREE_CORRUPT:-}" ]; then
      echo "error: fsck: corrupted object" >&2
      exit 1
    fi
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
# MOCK_CURL_FAIL is a glob pattern matched against the whole URL.
# shellcheck disable=SC2053
if [ -n "${MOCK_CURL_FAIL:-}" ] && [[ "$url" == $MOCK_CURL_FAIL ]]; then
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
  refs_for_app io.github.astrovm.Etcher master x86_64
  refs_for_app io.github.astrovm.Ventoy master x86_64 aarch64
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
  {
    refs_for_app io.github.astrovm.PkgDeck master x86_64 aarch64
    refs_for_app io.github.astrovm.Etcher master x86_64
    refs_for_app io.github.astrovm.Ventoy master x86_64 aarch64
  } > "$site/repo/refs-list"
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
if [ "$(sort -u "$site/repo/refs-list" | grep -c '^app/')" -ne 7 ] ||
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

# Refreshing the website keeps the published repository and key.
refreshed_site=$temporary_directory/refreshed-site
cp -R "$site" "$refreshed_site"
printf 'stale\n' > "$refreshed_site/stale.html"
rm "$refreshed_site/index.html"
cp "$refreshed_site/repo/refs-list" "$temporary_directory/refs-before"
cp "$refreshed_site/astrovm.gpg" "$temporary_directory/key-before"
# A fresh gh-pages checkout has no empty directories, which OSTree needs.
rm -rf "$refreshed_site/repo/refs/remotes" "$refreshed_site/repo/refs/mirrors"
expect_success \
  "the website is refreshed on a published site and verified" \
  env -u GH_TOKEN -u FLATPAK_GPG_PRIVATE_KEY -u FLATPAK_GPG_KEY_ID \
  "$scripts/refresh-site.sh" "$refreshed_site"
if [ -e "$refreshed_site/stale.html" ] ||
  [ ! -s "$refreshed_site/index.html" ] ||
  [ ! -d "$refreshed_site/.git" ] ||
  [ "$(cat "$refreshed_site/CNAME")" != "flatpak.4st.li" ] ||
  ! cmp -s "$temporary_directory/refs-before" "$refreshed_site/repo/refs-list" ||
  ! cmp -s "$temporary_directory/key-before" "$refreshed_site/astrovm.gpg"; then
  fail "refreshing changed the repository or left the old website behind"
fi
for directory in extensions objects refs/heads refs/mirrors refs/remotes state tmp; do
  [ -d "$refreshed_site/repo/$directory" ] || fail "refreshing did not restore repository directory $directory"
done
pass "refreshing regenerates the website and keeps the repository and key"

expect_failure \
  "refreshing requires one argument" \
  "usage:" \
  "$scripts/refresh-site.sh"
mkdir "$temporary_directory/unpublished-site"
expect_failure \
  "refreshing requires a published repository" \
  "No published repository to refresh" \
  "$scripts/refresh-site.sh" "$temporary_directory/unpublished-site"

fresh_site=$temporary_directory/fresh-site
expect_failure \
  "a new repository must contain every registered application" \
  "Repository is missing expected ref: app/io.github.astrovm." \
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
  env MOCK_CURL_FAIL='*/apps/io.github.astrovm.PkgDeck/install/' "$scripts/check-live.sh"
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


# Temporary directories are removed whether a script succeeds or fails.
leftovers=$(find "$temporary_directory" -maxdepth 1 -name 'flatpak-*' -print)
[ -z "$leftovers" ] || fail "scripts left temporary directories behind: $leftovers"
pass "publishing, verification, and health checks clean up temporary directories"

# Publishing rejects bad requests before contacting GitHub.
gh_log=$temporary_directory/gh-log
: > "$gh_log"
expect_failure \
  "publishing rejects unregistered source repositories" \
  "Publishing from astrovm/Other is not allowed" \
  env MOCK_GH_LOG="$gh_log" "$scripts/publish.sh" astrovm/Other v1.2.3 "$site"
expect_failure \
  "publishing rejects malformed release tags" \
  "Invalid release tag: latest" \
  env MOCK_GH_LOG="$gh_log" "$scripts/publish.sh" astrovm/AdventureMods latest "$site"
[ ! -s "$gh_log" ] || fail "rejected publishing requests contacted GitHub: $(cat "$gh_log")"
pass "rejected publishing requests never contact GitHub"

broken_registry=$temporary_directory/broken-apps.json
jq '.apps[0].runtime_repository = "http://example.com/"' \
  "$repository_root/apps.json" > "$broken_registry"
expect_failure \
  "publishing refuses to run with an invalid registry" \
  "Invalid application registry: $broken_registry" \
  env APP_REGISTRY="$broken_registry" "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"

ln -s "$site" "$temporary_directory/site-link"
expect_failure \
  "publishing refuses a symbolic-link output directory" \
  "Refusing to use a symbolic link as the output directory" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$temporary_directory/site-link"
expect_failure \
  "site rendering refuses a symbolic-link output directory" \
  "Refusing to use a symbolic link as the output directory" \
  "$scripts/render-site.sh" "$site/astrovm.gpg" "$temporary_directory/site-link"
expect_failure \
  "publishing requires a non-empty output directory" \
  "Output directory is required" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 ""

other_tag_metadata=$temporary_directory/other-tag.json
jq '.tag_name = "v1.2.4"' "$release_metadata" > "$other_tag_metadata"
expect_failure \
  "publishing rejects metadata for a different release" \
  "Release v1.2.3 must be published, immutable, and not a prerelease" \
  env MOCK_RELEASE_METADATA="$other_tag_metadata" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"

expect_failure \
  "publishing stops when the existing repository is corrupt" \
  "corrupted object" \
  env MOCK_OSTREE_CORRUPT=1 "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"
if grep -Fq "Importing" "$temporary_directory/last-output"; then
  fail "bundles were imported into a corrupt repository"
fi
pass "nothing is imported into a corrupt repository"

double_ref_bundles=$temporary_directory/double-ref-bundles
mkdir "$double_ref_bundles"
cp "$bundles"/*.flatpak "$double_ref_bundles/"
refs_for_app io.github.astrovm.AdventureMods master x86_64 aarch64 \
  > "$double_ref_bundles/AdventureMods-v1.2.3-x86_64.flatpak"
double_ref_metadata=$temporary_directory/double-ref.json
write_release_metadata "$double_ref_metadata" "$double_ref_bundles"
expect_failure \
  "publishing rejects a bundle containing more than one ref" \
  "AdventureMods-v1.2.3-x86_64.flatpak contains an unexpected ref: app/io.github.astrovm.AdventureMods/aarch64/master app/io.github.astrovm.AdventureMods/x86_64/master" \
  env MOCK_RELEASE_METADATA="$double_ref_metadata" MOCK_BUNDLES="$double_ref_bundles" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"

# A failure after importing must not replace the previously published site.
site_snapshot()
{
  (cd "$site" && find . -path ./repo -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
}
site_before=$(site_snapshot)
expect_failure \
  "publishing fails when the public key cannot be exported" \
  "Failed to export the Flatpak repository public key" \
  env MOCK_GPG_EMPTY_EXPORT=1 "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"
[ "$(site_snapshot)" = "$site_before" ] || fail "a failed publish modified the website"
pass "a failed publish leaves the previous website in place"

expect_success \
  "publishing the same release again succeeds" \
  "$scripts/publish.sh" astrovm/AdventureMods v1.2.3 "$site"
if [ "$(sort -u "$site/repo/refs-list" | grep -c '^app/')" -ne 7 ]; then
  fail "republishing changed the set of application refs"
fi
pass "republishing a release keeps exactly one ref per application and architecture"

# Verification failures.
expect_failure \
  "verification fails for a missing site" \
  "Generated repository file is missing or empty: $temporary_directory/no-such-site/repo/config" \
  "$scripts/verify-repository.sh" "$temporary_directory/no-such-site"
expect_failure \
  "verification fails when OSTree reports corruption" \
  "corrupted object" \
  env MOCK_OSTREE_CORRUPT=1 "$scripts/verify-repository.sh" "$site"
if grep -Fq "Verified signed Flatpak repository" "$temporary_directory/last-output"; then
  fail "a corrupt repository was reported as verified"
fi
pass "a corrupt repository is not reported as verified"

rm -rf "$broken_site"
cp -R "$site" "$broken_site"
sed -i 's/^GPGKey=.*/GPGKey=b2xkIGtleQ==/' "$broken_site/io.github.astrovm.AdventureMods.flatpakref"
expect_failure \
  "verification names the descriptor with a stale key" \
  "Embedded GPG key does not match astrovm.gpg: $broken_site/io.github.astrovm.AdventureMods.flatpakref" \
  "$scripts/verify-repository.sh" "$broken_site"

rm -rf "$broken_site"
cp -R "$site" "$broken_site"
printf 'app/io.github.astrovm.Unknown/x86_64/master\n' >> "$broken_site/repo/refs-list"
expect_failure \
  "verification rejects refs for unregistered applications" \
  "Repository contains unexpected application ref: app/io.github.astrovm.Unknown/x86_64/master" \
  "$scripts/verify-repository.sh" "$broken_site"

# Live health check failures.
expect_failure \
  "the health check fails when the home page is down" \
  "The requested URL returned error: 404" \
  env MOCK_CURL_FAIL=https://flatpak.4st.li/ "$scripts/check-live.sh"
expect_failure \
  "the health check fails when the repository file is missing" \
  "The requested URL returned error: 404" \
  env MOCK_CURL_FAIL='*/astrovm.flatpakrepo' "$scripts/check-live.sh"
expect_failure \
  "the health check fails when an application descriptor is missing" \
  "The requested URL returned error: 404" \
  env MOCK_CURL_FAIL='*/io.github.astrovm.AdventureMods.flatpakref' "$scripts/check-live.sh"
expect_failure \
  "the health check rejects unregistered live refs" \
  "Published repository has unexpected refs for aarch64" \
  env MOCK_LIVE_REFS="$all_registered_refs"$'\napp/io.github.astrovm.Unknown/aarch64/master' \
  "$scripts/check-live.sh"
if ! grep -Fxq "Actual:" "$temporary_directory/last-output" ||
  ! grep -Fxq "app/io.github.astrovm.Unknown/aarch64/master" "$temporary_directory/last-output"; then
  fail "the health check did not show the unexpected live ref"
fi
pass "the health check shows which live refs differ"
expect_failure \
  "the health check reports an empty live repository" \
  "Published repository has unexpected refs for aarch64" \
  env MOCK_LIVE_REFS= "$scripts/check-live.sh"
if ! grep -Fxq "nothing" "$temporary_directory/last-output"; then
  fail "the health check did not report that no refs were served"
fi
pass "the health check says when the live repository serves nothing"

# Site rendering keeps registry values intact in every output format.
special_registry=$temporary_directory/special-apps.json
jq '.apps[0] += {
  name: "Mods & <Tools> | \\ \"Q\"",
  summary: "Fast & safe | 100% \\ tested",
  branch: "stable",
  architectures: ["aarch64", "x86_64"],
  runtime_repository: "https://example.com/repo?a=1&b=2|3"
}' "$repository_root/apps.json" > "$special_registry"
special_site=$temporary_directory/special-site
printf 'key & | \\ bytes\n' > "$temporary_directory/special-key.gpg"
expect_success \
  "site rendering accepts registry values with special characters" \
  env APP_REGISTRY="$special_registry" \
  "$scripts/render-site.sh" "$temporary_directory/special-key.gpg" "$special_site"

special_descriptor=$special_site/io.github.astrovm.AdventureMods.flatpakref
special_page=$special_site/apps/io.github.astrovm.AdventureMods/install/index.html
encoded_special_key=$(base64 --wrap=0 "$temporary_directory/special-key.gpg")
# The single-quoted values are literal expected output.
# shellcheck disable=SC2016
if ! grep -Fxq 'Title=Mods & <Tools> | \ "Q"' "$special_descriptor" ||
  ! grep -Fxq 'Comment=Fast & safe | 100% \ tested' "$special_descriptor" ||
  ! grep -Fxq 'Branch=stable' "$special_descriptor" ||
  ! grep -Fxq 'Name=io.github.astrovm.AdventureMods' "$special_descriptor" ||
  ! grep -Fxq 'RuntimeRepo=https://example.com/repo?a=1&b=2|3' "$special_descriptor" ||
  ! grep -Fxq "GPGKey=$encoded_special_key" "$special_descriptor" ||
  ! grep -Fxq "GPGKey=$encoded_special_key" "$special_site/astrovm.flatpakrepo"; then
  sed 's/^/# /' "$special_descriptor" >&2
  fail "the application descriptor does not contain the exact registry values"
fi
pass "application descriptors contain registry values verbatim"

if ! grep -Fq '<h1>Mods &amp; &lt;Tools&gt; | \ &quot;Q&quot;</h1>' "$special_page" ||
  ! grep -Fq '<h2>Mods &amp; &lt;Tools&gt; | \ &quot;Q&quot;</h2>' "$special_site/index.html" ||
  ! grep -Fq '<p>Fast &amp; safe | 100% \ tested</p>' "$special_site/index.html" ||
  grep -Fq '<Tools>' "$special_page" "$special_site/index.html"; then
  fail "the generated pages do not escape registry values"
fi
pass "generated pages escape registry values"

cmp -s "$temporary_directory/special-key.gpg" "$special_site/astrovm.gpg" ||
  fail "the published key differs from the input key"
cmp -s "$repository_root/templates/styles.css" "$special_site/styles.css" ||
  fail "the stylesheet was not copied unchanged"
stylesheet_version=$(sha256sum "$repository_root/templates/styles.css" | cut -c1-12)
grep -Fq "styles.css?v=$stylesheet_version" "$special_site/index.html" ||
  fail "the stylesheet version does not match its content"
pass "the key and stylesheet are published unchanged with a content-based version"

expect_failure \
  "site rendering fails for a missing public key" \
  "No such file or directory" \
  "$scripts/render-site.sh" "$temporary_directory/no-such-key.gpg" "$temporary_directory/render"
expect_failure \
  "site rendering refuses to write into the source checkout" \
  "Output directory cannot be the source repository" \
  "$scripts/render-site.sh" "$site/astrovm.gpg" "$repository_root"

# Request resolution.
latest_output=$temporary_directory/latest-output
printf 'existing=value\n' > "$latest_output"
expect_success \
  "a manual request without a tag uses the latest release" \
  env MANUAL_REPOSITORY=astrovm/PkgDeck MANUAL_TAG= MOCK_LATEST_TAG=v3.0.0 \
  "$scripts/resolve-request.sh" workflow_dispatch "$latest_output"
grep -Fxq "::notice::No tag provided; using latest release v3.0.0" "$temporary_directory/last-output" ||
  fail "the latest release was not announced"
[ "$(cat "$latest_output")" = $'existing=value\nrepository=astrovm/PkgDeck\ntag=v3.0.0' ] ||
  fail "request outputs were not appended to the existing output file"
pass "resolved outputs are appended after existing workflow outputs"

: > "$gh_log"
explicit_output=$temporary_directory/explicit-output
expect_success \
  "a manual request with a tag is accepted" \
  env MANUAL_REPOSITORY=astrovm/AdventureMods MANUAL_TAG=v1.0.0 MOCK_GH_LOG="$gh_log" \
  "$scripts/resolve-request.sh" workflow_dispatch "$explicit_output"
[ ! -s "$gh_log" ] || fail "an explicit tag still queried the latest release"
[ "$(cat "$explicit_output")" = $'repository=astrovm/AdventureMods\ntag=v1.0.0' ] ||
  fail "the explicit manual tag was not emitted"
pass "an explicit tag is used without querying GitHub"

invalid_latest_output=$temporary_directory/invalid-latest-output
: > "$invalid_latest_output"
expect_failure \
  "a latest release with an invalid tag is rejected" \
  "Invalid release tag: nightly" \
  env MANUAL_REPOSITORY=astrovm/PkgDeck MANUAL_TAG= MOCK_LATEST_TAG=nightly \
  "$scripts/resolve-request.sh" workflow_dispatch "$invalid_latest_output"
expect_failure \
  "a dispatch without a repository is rejected" \
  "Publishing from  is not allowed" \
  env -u DISPATCH_REPOSITORY DISPATCH_TAG=v1.0.0 \
  "$scripts/resolve-request.sh" repository_dispatch "$invalid_latest_output"
expect_failure \
  "a dispatch for an unregistered repository is rejected" \
  "Publishing from astrovm/Other is not allowed" \
  env DISPATCH_REPOSITORY=astrovm/Other DISPATCH_TAG=v1.0.0 \
  "$scripts/resolve-request.sh" repository_dispatch "$invalid_latest_output"
[ ! -s "$invalid_latest_output" ] || fail "rejected requests wrote workflow outputs"
pass "rejected requests write no workflow outputs"

printf '1..%d\n' "$tests_run"
