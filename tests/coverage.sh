#!/usr/bin/env bash
# Run the test suites under kcov and fail when line coverage of scripts/ is
# below COVERAGE_MIN percent. kcov traces bash through xtrace, so continuation
# lines of multi-line commands (such as jq programs) are reported as not run.
set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
coverage_directory=${COVERAGE_DIRECTORY:-$repository_root/coverage}
coverage_minimum=${COVERAGE_MIN:-85}

for tool in kcov jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required for coverage" >&2
    exit 1
  fi
done

rm -rf -- "$coverage_directory"
for suite in "$repository_root"/tests/test-*.sh; do
  kcov --include-path="$repository_root/scripts" "$coverage_directory" "$suite"
done

report=$coverage_directory/kcov-merged/coverage.json
jq -r '.files[] | "\(.file): \(.percent_covered)% (\(.covered_lines)/\(.total_lines) lines)"' "$report"
jq -r '"total: \(.percent_covered)% (\(.covered_lines)/\(.total_lines) lines)"' "$report"

if ! jq -e --argjson minimum "$coverage_minimum" '(.percent_covered | tonumber) >= $minimum' "$report" >/dev/null; then
  echo "coverage is below $coverage_minimum%" >&2
  exit 1
fi
