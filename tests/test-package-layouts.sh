#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root" <<'PY'
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = Path(sys.argv[1])
manifest = json.loads((root / 'packages/ventoy/io.github.astrovm.Ventoy.json').read_text())
module = manifest['modules'][0]
source = next(s for s in module['sources'] if s['type'] == 'archive')
with tempfile.TemporaryDirectory() as temporary:
    work = Path(temporary)
    archive = work / 'upstream.tar.gz'
    # Upstream archives have both a leading ./ and a version directory.
    files = {'VentoyGUI.x86_64': b'#!/bin/sh\nexit 0\n', 'VentoyGUI.aarch64': b'#!/bin/sh\nexit 0\n', 'tool/VentoyGTK.glade': b'<interface/>', 'ventoy/version': b'1.2.3'}
    with tarfile.open(archive, 'w:gz') as tar:
        for name, data in files.items():
            info = tarfile.TarInfo('./ventoy-1.2.3/' + name)
            info.mode = 0o755 if name.startswith('VentoyGUI') else 0o644
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    build = work / 'build'
    build.mkdir()
    upstream = build / source['dest']
    upstream.mkdir()
    subprocess.run(['tar', '-xzf', str(archive), '-C', str(upstream), f"--strip-components={source.get('strip-components', 1)}"], check=True)
    for entry in module['sources']:
        if entry['type'] == 'file':
            original = root / 'packages/ventoy' / entry['path']
            shutil.copy(original, build / original.name)
    app = work / 'app'
    for command in module['build-commands']:
        subprocess.run(command.replace('/app', str(app)), shell=True, cwd=build, check=True)
    for arch in ('x86_64', 'aarch64'):
        executable = app / 'ventoy' / f'VentoyGUI.{arch}'
        subprocess.run([str(executable)], check=True)
    assert (app / 'ventoy/tool/VentoyGTK.glade').is_file()
    assert (app / 'ventoy/ventoy/version').is_file()
print('ok - actual Ventoy recipe installs both GUI launchers and companion files at the expected paths')
PY
