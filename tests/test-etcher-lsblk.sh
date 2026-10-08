#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# Substitute only the external executable. Node still supplies real socket
# descriptors, and the production wrapper must convert all three streams.
cat > "$work/lsblk" <<'MOCK'
#!/usr/bin/env python3
import json
import os
import stat
import sys
assert stat.S_ISCHR(os.fstat(0).st_mode), 'stdin must be /dev/null'
assert stat.S_ISFIFO(os.fstat(1).st_mode), 'stdout must be a pipe'
assert stat.S_ISFIFO(os.fstat(2).st_mode), 'stderr must be a pipe'
print('scanner diagnostic', file=sys.stderr)
if '--fail' in sys.argv:
    sys.exit(42)
print(json.dumps(sys.argv[1:], ensure_ascii=False))
MOCK
chmod +x "$work/lsblk"
sed "s|/usr/bin/lsblk|$work/lsblk|" "${ETCHER_LSBLK_SCRIPT:-$root/scripts/etcher-lsblk.sh}" > "$work/wrapper"

node --input-type=module - "$work/wrapper" <<'JS'
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const run = promisify(execFile);
const wrapper = process.argv[2];
for (const args of [[], ['--json', '--bytes', 'image with spaces', 'ñ😀', 'a\nb', '$(literal)']]) {
  const { stdout, stderr } = await run('bash', [wrapper, ...args]);
  assert.deepEqual(JSON.parse(stdout), args);
  assert.equal(stderr, 'scanner diagnostic\n');
}
await assert.rejects(run('bash', [wrapper, '--fail']), error => {
  assert.equal(error.code, 42);
  assert.equal(error.stdout, '');
  assert.equal(error.stderr, 'scanner diagnostic\n');
  return true;
});
JS
echo 'ok - scanner subprocess uses pipes and preserves arguments, diagnostics and failures'
