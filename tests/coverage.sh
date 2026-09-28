#!/usr/bin/env bash
# Run the test suites under kcov and fail when line coverage of scripts/ is
# below COVERAGE_MIN percent. kcov attributes each traced command to a single
# line, so executed code is reported as not run when it spans lines inside a
# multi-line string, a multi-line $(...), or a redirected `done` in a function.
# Put long jq programs in quoted heredocs passed with -f /dev/stdin instead.
set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
coverage_directory=${COVERAGE_DIRECTORY:-$repository_root/coverage}
coverage_minimum=${COVERAGE_MIN:-100}

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
# --include-path filters traced files; it does not discover unexecuted scripts.
# Refuse an incomplete report so new production scripts cannot escape the gate.
while IFS= read -r -d '' script; do
  relative_path=${script#"$repository_root/"}
  if ! jq -e --arg absolute "$script" --arg relative "$relative_path" \
    'any(.files[]; (.file == $absolute or .file == $relative) and (.total_lines | tonumber) > 0)' \
    "$report" >/dev/null; then
    echo "coverage report is missing executable lines for $relative_path" >&2
    exit 1
  fi
done < <(find "$repository_root/scripts" -type f -name '*.sh' -print0)

jq -r '.files[] | "\(.file): \(.percent_covered)% (\(.covered_lines)/\(.total_lines) lines)"' "$report"
jq -r '"total: \(.percent_covered)% (\(.covered_lines)/\(.total_lines) lines)"' "$report"

if ! jq -e --argjson minimum "$coverage_minimum" '(.percent_covered | tonumber) >= $minimum' "$report" >/dev/null; then
  echo "coverage is below $coverage_minimum%" >&2
  exit 1
fi
