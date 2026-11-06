#!/usr/bin/env bash
set -euo pipefail
# Node captures child output with Unix sockets. Some host AppArmor lsblk
# profiles reject those inherited sockets. Keep lsblk confined and give it
# ordinary pipes instead, preserving stdout, stderr, arguments and failures.
/usr/bin/lsblk "$@" </dev/null 2> >(cat >&2) | cat
