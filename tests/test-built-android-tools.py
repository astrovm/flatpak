#!/usr/bin/env python3
"""Check the exported upstream binaries and resolve their runtime dependencies."""
import json
from pathlib import Path
import subprocess
import sys

build, recipe = map(Path, sys.argv[1:])
manifest = json.loads(recipe.read_text())
package = manifest['command']
files = build / 'files'
app_id = manifest['app-id']
for relative in [f'bin/{package}', 'bin/adb', f'share/applications/{app_id}.desktop',
                 f'share/metainfo/{app_id}.metainfo.xml', f'share/licenses/{package}/LICENSE',
                 'share/licenses/adb/NOTICE', f'share/icons/hicolor/256x256/apps/{app_id}.png']:
    assert (files / relative).stat().st_size > 0, relative
if package == 'qtscrcpy':
    for relative in ['qtscrcpy/bin/QtScrcpy', 'qtscrcpy/lib/qtscrcpy/scrcpy-server',
                     'qtscrcpy/share/config/config.ini', 'qtscrcpy/share/keymap']:
        assert (files / relative).exists(), relative
    assert not (files / 'qtscrcpy/lib/qtscrcpy/adb').exists()
    binary = '/app/qtscrcpy/bin/QtScrcpy'
    library_path = '/app/qtscrcpy/lib:/app/qtscrcpy/lib/x86_64-linux-gnu'
else:
    binary = '/app/libexec/uadng'
    library_path = '/app/lib'
run = ['flatpak-builder', '--run', str(build), str(recipe)]
version = subprocess.check_output([*run, 'adb', 'version'], text=True)
assert 'Android Debug Bridge version 1.0.41' in version, version
if package == 'qtscrcpy':
    plugin = subprocess.check_output([*run, 'env', f'LD_LIBRARY_PATH={library_path}', 'ldd', '/app/qtscrcpy/plugins/platforms/libqxcb.so'], text=True)
    assert 'not found' not in plugin, plugin
libraries = subprocess.check_output([*run, 'env', f'LD_LIBRARY_PATH={library_path}', 'ldd', binary], text=True)
assert 'not found' not in libraries, libraries
print(f'ok - {package} exports its binary/resources and runs bundled ADB in the Flatpak runtime')
