#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/publish-common.sh
source "$script_directory/lib/publish-common.sh"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <event-name> <github-output-file>" >&2
  exit 2
fi

event_name=$1
github_output_file=$2

validate_app_registry

case "$event_name" in
  repository_dispatch)
    repository=${DISPATCH_REPOSITORY:-}
    tag=${DISPATCH_TAG:-}
    ;;
  workflow_dispatch)
    repository=${MANUAL_REPOSITORY:-}
    tag=${MANUAL_TAG:-}
    ;;
  *)
    error "Unsupported publication event: $event_name"
    exit 1
    ;;
esac

validate_source_repository "$repository"

if [ -z "$tag" ]; then
  tag=$(gh release view --repo "$repository" --json tagName --jq .tagName)
  echo "::notice::No tag provided; using latest release $tag"
fi

validate_release_tag "$tag"

# Both values have been restricted to single-line allowlisted formats above.
printf 'repository=%s\ntag=%s\n' "$repository" "$tag" >> "$github_output_file"
