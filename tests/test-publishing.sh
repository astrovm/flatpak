#!/usr/bin/env bash
set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$repository_root/scripts/lib/publish-common.sh"

temporary_directory=$(mktemp -d)
trap 'rm -rf -- "$temporary_directory"' EXIT

tests_run=0

pass()
{
  tests_run=$((tests_run + 1))
  printf 'ok %d - %s\n' "$tests_run" "$1"
}

expect_success()
{
  local name=$1
  shift

  if "$@"; then
    pass "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    exit 1
  fi
}

expect_failure()
{
  local name=$1
  shift

  if "$@" >/dev/null 2>&1; then
    printf 'not ok - %s unexpectedly succeeded\n' "$name" >&2
    exit 1
  else
    pass "$name"
  fi
}

expect_success "application registry is valid" validate_app_registry
expect_success \
  "allowlisted source repository is accepted" \
  validate_source_repository \
  "astrovm/AdventureMods"
expect_failure \
  "other source repositories are rejected" \
  validate_source_repository \
  "astrovm/Other"

if [ "$(app_value "astrovm/AdventureMods" id)" != "io.github.astrovm.AdventureMods" ]; then
  echo "not ok - application metadata lookup is incorrect" >&2
  exit 1
fi
pass "application metadata is loaded from the registry"

multi_app_registry=$temporary_directory/apps.json
jq '.apps += [{
  repository: "astrovm/TestApp",
  id: "io.github.astrovm.TestApp",
  name: "Test App",
  summary: "A test application.",
  bundle_prefix: "TestApp",
  branch: "stable",
  architectures: ["x86_64"],
  runtime_repository: "https://dl.flathub.org/repo/flathub.flatpakrepo"
}]' "$APP_REGISTRY" > "$multi_app_registry"

# The subshell expands its own positional parameter.
# shellcheck disable=SC2016
expect_success \
  "multiple registered applications are supported" \
  env \
  APP_REGISTRY="$multi_app_registry" \
  bash -c '
    source "$1"
    validate_app_registry
    validate_source_repository "astrovm/TestApp"
    [ "$(all_expected_refs | wc -l)" -eq 3 ]
  ' \
  _ \
  "$repository_root/scripts/lib/publish-common.sh"

jq '.apps += [.apps[0]]' "$APP_REGISTRY" > "$temporary_directory/duplicate-apps.json"
# The subshell expands its own positional parameter.
# shellcheck disable=SC2016
expect_failure \
  "duplicate application entries are rejected" \
  env \
  APP_REGISTRY="$temporary_directory/duplicate-apps.json" \
  bash -c 'source "$1"; validate_app_registry' \
  _ \
  "$repository_root/scripts/lib/publish-common.sh"

ostree_mock_directory=$temporary_directory/ostree-mock
mkdir "$ostree_mock_directory"
# The single quotes write a mock that expands its own environment.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[ "$1" = "refs" ]' \
  'printf "%s\n" "$MOCK_REFS"' \
  > "$ostree_mock_directory/ostree"
chmod +x "$ostree_mock_directory/ostree"

registered_refs=$'app/io.github.astrovm.AdventureMods/aarch64/master\napp/io.github.astrovm.AdventureMods/x86_64/master\napp/io.github.astrovm.TestApp/x86_64/stable'
# The subshell expands its own positional parameter.
# shellcheck disable=SC2016
expect_success \
  "repository validation supports all registered applications" \
  env \
  APP_REGISTRY="$multi_app_registry" \
  MOCK_REFS="$registered_refs" \
  PATH="$ostree_mock_directory:$PATH" \
  bash -c 'source "$1"; validate_repository_refs "$2"' \
  _ \
  "$repository_root/scripts/lib/publish-common.sh" \
  "$temporary_directory/repository"

# The subshell expands its own positional parameter.
# shellcheck disable=SC2016
expect_failure \
  "repository validation rejects unregistered applications" \
  env \
  APP_REGISTRY="$multi_app_registry" \
  MOCK_REFS="$registered_refs"$'\napp/io.github.astrovm.Unknown/x86_64/master' \
  PATH="$ostree_mock_directory:$PATH" \
  bash -c 'source "$1"; validate_repository_refs "$2"' \
  _ \
  "$repository_root/scripts/lib/publish-common.sh" \
  "$temporary_directory/repository"

expect_success "stable release tag is accepted" validate_release_tag "v1.2.3"
expect_success \
  "prerelease and build identifiers are syntactically accepted" \
  validate_release_tag \
  "v1.2.3-rc.1+build.2"
expect_failure "leading zero is rejected" validate_release_tag "v01.2.3"
expect_failure "trailing separator is rejected" validate_release_tag "v1.2.3-"
expect_failure \
  "multiline release tag is rejected" \
  validate_release_tag \
  $'v1.2.3\nmalicious=true'

expect_failure "filesystem root is rejected as output" validate_output_directory "/"
mkdir "$temporary_directory/output"
expect_success \
  "normal output directory is accepted" \
  validate_output_directory \
  "$temporary_directory/output" \
  "$repository_root"
expect_failure \
  "source repository is rejected as output" \
  validate_output_directory \
  "$repository_root" \
  "$repository_root"
ln -s "$temporary_directory/output" "$temporary_directory/output-link"
expect_failure \
  "symbolic-link output directory is rejected" \
  validate_output_directory \
  "$temporary_directory/output-link"

metadata_file=$temporary_directory/release.json
bundles_directory=$temporary_directory/bundles
mkdir "$bundles_directory"
printf 'arm bundle\n' > "$bundles_directory/AdventureMods-aarch64.flatpak"
printf 'x86 bundle\n' > "$bundles_directory/AdventureMods-x86_64.flatpak"
arm_digest=sha256:$(sha256sum "$bundles_directory/AdventureMods-aarch64.flatpak" | cut -d ' ' -f 1)
x86_digest=sha256:$(sha256sum "$bundles_directory/AdventureMods-x86_64.flatpak" | cut -d ' ' -f 1)

jq -n \
  --arg arm_digest "$arm_digest" \
  --arg x86_digest "$x86_digest" \
  '{
    tag_name: "v1.2.3",
    draft: false,
    prerelease: false,
    immutable: true,
    assets: [
      {name: "AdventureMods-aarch64.flatpak", digest: $arm_digest},
      {name: "AdventureMods-x86_64.flatpak", digest: $x86_digest}
    ]
  }' > "$metadata_file"

expect_success \
  "immutable production release metadata is accepted" \
  validate_release_metadata \
  "$metadata_file" \
  "v1.2.3"
expect_success \
  "expected bundles and digests are accepted" \
  validate_downloaded_bundles \
  "$metadata_file" \
  "$bundles_directory" \
  "astrovm/AdventureMods"

jq '.immutable = false' "$metadata_file" > "$temporary_directory/mutable.json"
expect_failure \
  "mutable releases are rejected" \
  validate_release_metadata \
  "$temporary_directory/mutable.json" \
  "v1.2.3"

printf 'changed\n' >> "$bundles_directory/AdventureMods-x86_64.flatpak"
expect_failure \
  "bundle digest mismatch is rejected" \
  validate_downloaded_bundles \
  "$metadata_file" \
  "$bundles_directory" \
  "astrovm/AdventureMods"
printf 'x86 bundle\n' > "$bundles_directory/AdventureMods-x86_64.flatpak"

printf 'unexpected\n' > "$bundles_directory/unexpected.flatpak"
expect_failure \
  "unexpected extra bundle is rejected" \
  validate_downloaded_bundles \
  "$metadata_file" \
  "$bundles_directory" \
  "astrovm/AdventureMods"

public_key_file=$temporary_directory/public-key.gpg
site_directory=$temporary_directory/site
printf 'public key\n' > "$public_key_file"

expect_success \
  "site generation supports every registered application" \
  env \
  APP_REGISTRY="$multi_app_registry" \
  "$repository_root/scripts/render-site.sh" \
  "$public_key_file" \
  "$site_directory"

for path in \
  "$site_directory/index.html" \
  "$site_directory/io.github.astrovm.AdventureMods.flatpakref" \
  "$site_directory/apps/io.github.astrovm.AdventureMods/install/index.html" \
  "$site_directory/io.github.astrovm.TestApp.flatpakref" \
  "$site_directory/apps/io.github.astrovm.TestApp/install/index.html"; do
  if [ ! -s "$path" ]; then
    echo "not ok - generated site is missing $path" >&2
    exit 1
  fi
done

if ! grep -Fq "Adventure Mods" "$site_directory/index.html" ||
  ! grep -Fq "Test App" "$site_directory/index.html" ||
  ! grep -Fq "/apps/io.github.astrovm.AdventureMods/install/" \
    "$site_directory/index.html" ||
  grep -Fq "https://github.com/" "$site_directory/index.html" ||
  grep -Fq "Download installer" "$site_directory/index.html" ||
  ! grep -Fq "https://github.com/astrovm/AdventureMods" \
    "$site_directory/apps/io.github.astrovm.AdventureMods/install/index.html" ||
  ! grep -Fq 'class="github-icon"' \
    "$site_directory/apps/io.github.astrovm.AdventureMods/install/index.html" ||
  ! grep -Eq 'styles[.]css[?]v=[0-9a-f]{12}' "$site_directory/index.html" ||
  ! grep -Eq 'styles[.]css[?]v=[0-9a-f]{12}' \
    "$site_directory/apps/io.github.astrovm.AdventureMods/install/index.html" ||
  grep -Fq "APP_CARDS" "$site_directory/index.html" ||
  grep -ERq '@[A-Z_]+@' "$site_directory"; then
  echo "not ok - generated site contains incorrect application content" >&2
  exit 1
fi
pass "generated site contains all application metadata"

mock_bin=$temporary_directory/mock-bin
mkdir "$mock_bin"
# The single quotes write a mock script that expands its own arguments.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [ "$1" = "release" ] && [ "$2" = "view" ]; then' \
  '  printf "v9.8.7\n"' \
  'else' \
  '  exit 1' \
  'fi' > "$mock_bin/gh"
chmod +x "$mock_bin/gh"

request_output=$temporary_directory/github-output
: > "$request_output"
expect_success \
  "manual request resolves the latest release safely" \
  env \
  PATH="$mock_bin:$PATH" \
  MANUAL_REPOSITORY="astrovm/AdventureMods" \
  MANUAL_TAG="" \
  "$repository_root/scripts/resolve-request.sh" \
  "workflow_dispatch" \
  "$request_output"

if ! grep -Fxq "repository=astrovm/AdventureMods" "$request_output" ||
  ! grep -Fxq "tag=v9.8.7" "$request_output"; then
  echo "not ok - resolved request output is incorrect" >&2
  exit 1
fi
pass "resolved request emits only validated outputs"

injection_marker=$temporary_directory/injected
rejected_output=$temporary_directory/rejected-output
expect_failure \
  "command-like dispatch tag is rejected without execution" \
  env \
  PATH="$mock_bin:$PATH" \
  DISPATCH_REPOSITORY="astrovm/AdventureMods" \
  DISPATCH_TAG="v1.2.3\$(touch $injection_marker)" \
  "$repository_root/scripts/resolve-request.sh" \
  "repository_dispatch" \
  "$rejected_output"

if [ -e "$injection_marker" ]; then
  echo "not ok - dispatch input executed as shell code" >&2
  exit 1
fi
pass "dispatch input is treated only as data"

printf '1..%d\n' "$tests_run"
