#!/usr/bin/env bash
# Verify that an untraced production script cannot disappear from the gate.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/tests" "$work/scripts" "$work/bin"
cp "$root/tests/coverage.sh" "$work/tests/coverage.sh"
printf '#!/bin/bash\ntrue\n' > "$work/tests/test-example.sh"
printf '#!/bin/bash\ntrue\n' > "$work/scripts/traced.sh"
printf '#!/bin/bash\necho untested\n' > "$work/scripts/forgotten.sh"
cat > "$work/bin/kcov" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$2/kcov-merged"
printf '%s\n' '{"percent_covered":"100.00","covered_lines":1,"total_lines":1,"files":[{"file":"scripts/traced.sh","percent_covered":"100.00","covered_lines":1,"total_lines":1}]}' > "$2/kcov-merged/coverage.json"
MOCK
chmod +x "$work/bin/kcov"
if PATH="$work/bin:$PATH" bash "$work/tests/coverage.sh" > "$work/result" 2>&1; then
  echo 'an untraced script incorrectly passed coverage' >&2
  exit 1
fi
grep -q 'missing executable lines for scripts/forgotten.sh' "$work/result"
rm "$work/scripts/forgotten.sh"
PATH="$work/bin:$PATH" bash "$work/tests/coverage.sh" > "$work/result" 2>&1
printf '%s\n' 'ok - coverage rejects missing production scripts and accepts complete reports'
