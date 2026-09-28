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
    [ "$(all_expected_refs | wc -l)" -eq 5 ]
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
  '[ -z "$MOCK_REFS" ] || printf "%s\n" "$MOCK_REFS"' \
  > "$ostree_mock_directory/ostree"
chmod +x "$ostree_mock_directory/ostree"

registered_refs=$'app/io.github.astrovm.AdventureMods/aarch64/master\napp/io.github.astrovm.AdventureMods/x86_64/master\napp/io.github.astrovm.PkgDeck/aarch64/master\napp/io.github.astrovm.PkgDeck/x86_64/master\napp/io.github.astrovm.TestApp/x86_64/stable'
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
rm "$bundles_directory/unexpected.flatpak"
mv "$bundles_directory/AdventureMods-aarch64.flatpak" "$bundles_directory/AdventureMods-v1.2.3-aarch64.flatpak"
mv "$bundles_directory/AdventureMods-x86_64.flatpak" "$bundles_directory/AdventureMods-v1.2.3-x86_64.flatpak"
jq '.assets[].name |= sub("AdventureMods-"; "AdventureMods-v1.2.3-")' \
  "$metadata_file" > "$temporary_directory/adventuremods-versioned.json"
expect_success \
  "versioned AdventureMods bundles are accepted by the same publisher" \
  validate_downloaded_bundles \
  "$temporary_directory/adventuremods-versioned.json" \
  "$bundles_directory" \
  "astrovm/AdventureMods"
jq '.assets += [{name: "AdventureMods-x86_64.flatpak", digest: "sha256:unused"}]' \
  "$temporary_directory/adventuremods-versioned.json" > "$temporary_directory/ambiguous.json"
expect_failure \
  "ambiguous release bundles are rejected" \
  validate_downloaded_bundles \
  "$temporary_directory/ambiguous.json" \
  "$bundles_directory" \
  "astrovm/AdventureMods"

versioned_bundles=$temporary_directory/versioned-bundles
versioned_metadata=$temporary_directory/versioned-release.json
mkdir "$versioned_bundles"
printf 'arm bundle\n' > "$versioned_bundles/PkgDeck-v9.8.7-aarch64.flatpak"
printf 'x86 bundle\n' > "$versioned_bundles/PkgDeck-v9.8.7-x86_64.flatpak"
arm_digest=sha256:$(sha256sum "$versioned_bundles/PkgDeck-v9.8.7-aarch64.flatpak" | cut -d ' ' -f 1)
x86_digest=sha256:$(sha256sum "$versioned_bundles/PkgDeck-v9.8.7-x86_64.flatpak" | cut -d ' ' -f 1)
jq -n \
  --arg arm_digest "$arm_digest" \
  --arg x86_digest "$x86_digest" \
  '{tag_name: "v9.8.7", draft: false, prerelease: false, immutable: true,
   assets: [
     {name: "PkgDeck-v9.8.7-aarch64.flatpak", digest: $arm_digest},
     {name: "PkgDeck-v9.8.7-x86_64.flatpak", digest: $x86_digest}
   ]}' > "$versioned_metadata"
if [ "$(release_bundle_name "$versioned_metadata" astrovm/PkgDeck x86_64)" != "PkgDeck-v9.8.7-x86_64.flatpak" ]; then
  echo "not ok - versioned bundle name is incorrect" >&2
  exit 1
fi
pass "versioned bundle names use the release tag"
expect_success \
  "versioned bundles and digests are accepted" \
  validate_downloaded_bundles \
  "$versioned_metadata" \
  "$versioned_bundles" \
  "astrovm/PkgDeck"
mv "$versioned_bundles/PkgDeck-v9.8.7-x86_64.flatpak" "$versioned_bundles/PkgDeck-x86_64.flatpak"
expect_failure \
  "unversioned alias is rejected for versioned releases" \
  validate_downloaded_bundles \
  "$versioned_metadata" \
  "$versioned_bundles" \
  "astrovm/PkgDeck"

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
  "$site_directory/io.github.astrovm.PkgDeck.flatpakref" \
  "$site_directory/apps/io.github.astrovm.PkgDeck/install/index.html" \
  "$site_directory/io.github.astrovm.TestApp.flatpakref" \
  "$site_directory/apps/io.github.astrovm.TestApp/install/index.html"; do
  if [ ! -s "$path" ]; then
    echo "not ok - generated site is missing $path" >&2
    exit 1
  fi
done

if ! grep -Fq "Adventure Mods" "$site_directory/index.html" ||
  ! grep -Fq "PkgDeck" "$site_directory/index.html" ||
  ! grep -Fq "Test App" "$site_directory/index.html" ||
  ! grep -Fq "/apps/io.github.astrovm.AdventureMods/install/" \
    "$site_directory/index.html" ||
  ! grep -Fq "Why this repository" "$site_directory/index.html" ||
  ! grep -Fq 'class="benefit-list"' "$site_directory/index.html" ||
  grep -Fq 'class="grid"' "$site_directory/index.html" ||
  grep -Fq "https://github.com/" "$site_directory/index.html" ||
  grep -Fq "Download installer" "$site_directory/index.html" ||
  ! grep -Fq "https://github.com/astrovm/AdventureMods" \
    "$site_directory/apps/io.github.astrovm.AdventureMods/install/index.html" ||
  ! grep -Fq 'class="github-icon"' \
    "$site_directory/apps/io.github.astrovm.AdventureMods/install/index.html" ||
  ! grep -Fq '<main class="page">' "$site_directory/index.html" ||
  ! grep -Fq '<main class="page">' \
    "$site_directory/apps/io.github.astrovm.AdventureMods/install/index.html" ||
  grep -Fq "page-index" "$site_directory/index.html" ||
  grep -Fq "page-index" "$site_directory/styles.css" ||
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


library=$repository_root/scripts/lib/publish-common.sh

# Run a library function against another registry and require that it fails
# with the given message.
expect_library_error()
{
  local name=$1
  local registry=$2
  local message=$3
  shift 3

  # The subshell expands its own positional parameters.
  # shellcheck disable=SC2016
  if env APP_REGISTRY="$registry" bash -c 'source "$1"; shift; "$@"' \
    _ "$library" "$@" > "$temporary_directory/library-output" 2>&1; then
    printf 'not ok - %s unexpectedly succeeded\n' "$name" >&2
    exit 1
  fi
  if ! grep -Fq -- "$message" "$temporary_directory/library-output"; then
    printf 'not ok - %s did not report: %s\n' "$name" "$message" >&2
    sed 's/^/# /' "$temporary_directory/library-output" >&2
    exit 1
  fi
  pass "$name"
}

# Each registry mutation below breaks exactly one rule.
while IFS='|' read -r description mutation; do
  jq "$mutation" "$APP_REGISTRY" > "$temporary_directory/invalid-apps.json"
  expect_library_error \
    "registry rejects $description" \
    "$temporary_directory/invalid-apps.json" \
    "Invalid application registry: $temporary_directory/invalid-apps.json" \
    validate_app_registry
done << 'REGISTRY_CASES'
an empty application list|.apps = []
an application list that is not an array|.apps = {}
a repository without an owner|.apps[0].repository = "AdventureMods"
a repository with shell characters|.apps[0].repository = "astrovm/$(id)"
an application ID with one component|.apps[0].id = "AdventureMods"
an application ID with an empty component|.apps[0].id = "io..AdventureMods"
a missing name|del(.apps[0].name)
a name containing a newline|.apps[0].name = "Adventure\nMods"
a summary containing a tab|.apps[0].summary = "A\tsummary"
an empty summary|.apps[0].summary = ""
a non-string name|.apps[0].name = 42
a bundle prefix containing a slash|.apps[0].bundle_prefix = "../AdventureMods"
a branch containing a space|.apps[0].branch = "main branch"
an empty architecture list|.apps[0].architectures = []
a duplicated architecture|.apps[0].architectures = ["x86_64", "x86_64"]
a non-string architecture|.apps[0].architectures = [64]
an architecture containing a slash|.apps[0].architectures = ["x86_64/../aarch64"]
an insecure runtime repository|.apps[0].runtime_repository = "http://dl.flathub.org/repo/flathub.flatpakrepo"
an application ID used twice|.apps[1].id = .apps[0].id
REGISTRY_CASES

printf '{"apps": [' > "$temporary_directory/malformed-apps.json"
expect_library_error \
  "registry rejects malformed JSON" \
  "$temporary_directory/malformed-apps.json" \
  "Invalid application registry" \
  validate_app_registry

jq '.apps[0].id = "a.b"' "$APP_REGISTRY" > "$temporary_directory/short-id-apps.json"
# The subshell expands its own positional parameter.
# shellcheck disable=SC2016
expect_success \
  "registry accepts the shortest valid application ID" \
  env APP_REGISTRY="$temporary_directory/short-id-apps.json" \
  bash -c 'source "$1"; validate_app_registry' _ "$library"

expect_failure "empty source repository is rejected" validate_source_repository ""
expect_failure \
  "source repository matching is case-sensitive" \
  validate_source_repository \
  "astrovm/adventuremods"
expect_failure \
  "source repository matching is exact" \
  validate_source_repository \
  "astrovm/AdventureMods.git"

for tag in v0.0.0 v10.20.30 v1.2.3+build v1.2.3-alpha-1 v1.2.3-rc.1.2+exp.sha.5114f85; do
  expect_success "release tag $tag is accepted" validate_release_tag "$tag"
done
for tag in "" 1.2.3 V1.2.3 v1.2 v1.2.3.4 v1.02.3 v1.2.03 "v1.2.3 " v1.2.3-rc..1 v1.2.3+ v1.2.3-rc_1 v1.2.3/../x; do
  expect_failure "release tag '$tag' is rejected" validate_release_tag "$tag"
done
if validate_release_tag "v1.2" 2> "$temporary_directory/tag-error" ||
  ! grep -Fxq "::error::Invalid release tag: v1.2" "$temporary_directory/tag-error"; then
  echo "not ok - invalid tag error is not a workflow annotation" >&2
  exit 1
fi
pass "invalid release tags are reported as workflow errors"

expect_failure \
  "parent of the source repository is rejected as output" \
  validate_output_directory \
  "$repository_root/.." \
  "$repository_root"
expect_failure \
  "source repository reached through dot segments is rejected as output" \
  validate_output_directory \
  "$repository_root/scripts/.." \
  "$repository_root"
expect_success \
  "a sibling that extends the repository name is accepted as output" \
  validate_output_directory \
  "$repository_root-site" \
  "$repository_root"
expect_success \
  "a sibling whose name is a prefix of the repository name is accepted as output" \
  validate_output_directory \
  "${repository_root%?}" \
  "$repository_root"
expect_success \
  "a directory inside the source repository is accepted as output" \
  validate_output_directory \
  "$repository_root/coverage/site" \
  "$repository_root"
expect_success \
  "a missing output directory is accepted before it is created" \
  validate_output_directory \
  "$temporary_directory/not-created-yet"

jq '.draft = true' "$metadata_file" > "$temporary_directory/draft.json"
expect_failure \
  "draft releases are rejected" \
  validate_release_metadata \
  "$temporary_directory/draft.json" \
  "v1.2.3"
expect_failure \
  "release metadata for another tag is rejected" \
  validate_release_metadata \
  "$metadata_file" \
  "v1.2.4"
jq 'del(.immutable)' "$metadata_file" > "$temporary_directory/unknown-immutability.json"
expect_failure \
  "releases without an immutability flag are rejected" \
  validate_release_metadata \
  "$temporary_directory/unknown-immutability.json" \
  "v1.2.3"

if [ "$(release_bundle_name "$metadata_file" astrovm/AdventureMods aarch64)" != "AdventureMods-aarch64.flatpak" ]; then
  echo "not ok - legacy bundle name is not selected" >&2
  exit 1
fi
pass "unversioned bundle names are selected when they are the only match"
jq '.tag_name = "latest"' "$metadata_file" > "$temporary_directory/bad-tag.json"
expect_failure \
  "bundle names are not derived from an invalid release tag" \
  release_bundle_name \
  "$temporary_directory/bad-tag.json" \
  astrovm/AdventureMods \
  x86_64
jq 'del(.tag_name)' "$metadata_file" > "$temporary_directory/no-tag.json"
expect_failure \
  "bundle names require a release tag" \
  release_bundle_name \
  "$temporary_directory/no-tag.json" \
  astrovm/AdventureMods \
  x86_64
expect_failure \
  "bundle names are not invented for unconfigured architectures" \
  release_bundle_name \
  "$metadata_file" \
  astrovm/AdventureMods \
  riscv64

short_bundles=$temporary_directory/short-bundles
mkdir "$short_bundles"
printf 'arm bundle\n' > "$short_bundles/AdventureMods-aarch64.flatpak"
printf 'not a bundle\n' > "$short_bundles/AdventureMods-x86_64.flatpak.sig"
if validate_downloaded_bundles "$metadata_file" "$short_bundles" astrovm/AdventureMods \
  2> "$temporary_directory/short-error" ||
  ! grep -Fq "Expected 2 Flatpak bundles, found 1" "$temporary_directory/short-error"; then
  echo "not ok - missing bundle count is not reported" >&2
  exit 1
fi
pass "too few downloaded bundles are rejected and non-bundle files are not counted"

duplicate_digest_bundles=$temporary_directory/duplicate-digest-bundles
mkdir "$duplicate_digest_bundles"
printf 'arm bundle\n' > "$duplicate_digest_bundles/AdventureMods-aarch64.flatpak"
printf 'x86 bundle\n' > "$duplicate_digest_bundles/AdventureMods-x86_64.flatpak"
jq '.assets += [{name: "AdventureMods-aarch64.flatpak", digest: .assets[0].digest}]' \
  "$metadata_file" > "$temporary_directory/duplicate-digest.json"
expect_failure \
  "duplicate release assets for one architecture are rejected" \
  validate_downloaded_bundles \
  "$temporary_directory/duplicate-digest.json" \
  "$duplicate_digest_bundles" \
  "astrovm/AdventureMods"
jq '.assets[1].digest |= "sha256:" + (ltrimstr("sha256:") | ascii_upcase)' "$metadata_file" > "$temporary_directory/uppercase-digest.json"
expect_library_error \
  "digests must use lowercase hexadecimal" \
  "$APP_REGISTRY" \
  "Release metadata has an invalid digest for AdventureMods-x86_64.flatpak" \
  validate_downloaded_bundles \
  "$temporary_directory/uppercase-digest.json" \
  "$duplicate_digest_bundles" \
  "astrovm/AdventureMods"

if [ "$(expected_ref astrovm/PkgDeck aarch64)" != "app/io.github.astrovm.PkgDeck/aarch64/master" ]; then
  echo "not ok - expected ref is incorrect" >&2
  exit 1
fi
pass "expected refs combine application ID, architecture, and branch"

# The subshell expands its own positional parameter.
# shellcheck disable=SC2016
per_arch_refs=$(env APP_REGISTRY="$multi_app_registry" bash -c '
  source "$1"
  printf "x86_64:\n"; expected_refs_for_arch x86_64
  printf "aarch64:\n"; expected_refs_for_arch aarch64
  printf "riscv64:\n"; expected_refs_for_arch riscv64
  printf "architectures:\n"; all_architectures
' _ "$library")
expected_per_arch_refs='x86_64:
app/io.github.astrovm.AdventureMods/x86_64/master
app/io.github.astrovm.PkgDeck/x86_64/master
app/io.github.astrovm.TestApp/x86_64/stable
aarch64:
app/io.github.astrovm.AdventureMods/aarch64/master
app/io.github.astrovm.PkgDeck/aarch64/master
riscv64:
architectures:
aarch64
x86_64'
if [ "$per_arch_refs" != "$expected_per_arch_refs" ]; then
  printf 'not ok - per-architecture refs are incorrect:\n%s\n' "$per_arch_refs" >&2
  exit 1
fi
pass "refs are listed per architecture, sorted, and only for applications that build it"

jq '.apps |= reverse' "$multi_app_registry" > "$temporary_directory/reversed-apps.json"
# The subshell expands its own positional parameter.
# shellcheck disable=SC2016
reversed_refs=$(env APP_REGISTRY="$temporary_directory/reversed-apps.json" \
  bash -c 'source "$1"; expected_refs_for_arch x86_64' _ "$library")
if [ "$reversed_refs" != "$(sed -n '2,4p' <<< "$expected_per_arch_refs")" ]; then
  printf 'not ok - refs are not sorted independently of registry order:\n%s\n' "$reversed_refs" >&2
  exit 1
fi
pass "refs per architecture are sorted regardless of registry order"

jq '.apps[0].name = "Tom & Jerry <\"Mods\">"' "$APP_REGISTRY" > "$temporary_directory/html-apps.json"
# The subshell expands its own positional parameter.
# shellcheck disable=SC2016
html_name=$(env APP_REGISTRY="$temporary_directory/html-apps.json" \
  bash -c 'source "$1"; app_html_value astrovm/AdventureMods name' _ "$library")
if [ "$html_name" != 'Tom &amp; Jerry &lt;&quot;Mods&quot;&gt;' ]; then
  printf 'not ok - HTML value is not escaped: %s\n' "$html_name" >&2
  exit 1
fi
pass "HTML values escape markup characters"

MOCK_REFS="" PATH="$ostree_mock_directory:$PATH" expect_library_error \
  "an empty repository is missing every registered application" \
  "$multi_app_registry" \
  "Repository is missing expected ref: app/io.github.astrovm." \
  validate_repository_refs "$temporary_directory/repository"
MOCK_REFS="$registered_refs"$'\nappstream2/riscv64' PATH="$ostree_mock_directory:$PATH" \
  expect_library_error \
  "repository validation rejects AppStream2 refs for unregistered architectures" \
  "$multi_app_registry" \
  "Repository contains unexpected AppStream ref: appstream2/riscv64" \
  validate_repository_refs "$temporary_directory/repository"
MOCK_REFS="${registered_refs/TestApp\/x86_64\/stable/TestApp/x86_64/master}" \
  PATH="$ostree_mock_directory:$PATH" \
  expect_library_error \
  "repository validation rejects a registered application on the wrong branch" \
  "$multi_app_registry" \
  "Repository contains unexpected application ref: app/io.github.astrovm.TestApp/x86_64/master" \
  validate_repository_refs "$temporary_directory/repository"

printf '1..%d\n' "$tests_run"
