#!/usr/bin/env python3
"""Inject behavioral faults into isolated copies; every mutant must be killed."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
mutations = [
    ('wrong Qt platform', 'scripts/qtscrcpy-launch.sh', 'QT_QPA_PLATFORM=xcb', 'QT_QPA_PLATFORM=wayland', 'test-android-tools.sh'),
    ('drop Qt graphics runtime', 'scripts/qtscrcpy-launch.sh', ':${LD_LIBRARY_PATH:-/usr/lib/x86_64-linux-gnu/GL/default/lib}', '', 'test-android-tools.sh'),
    ('collapse Qt arguments', 'scripts/qtscrcpy-launch.sh', '"$@"', '"$*"', 'test-android-tools.sh'),
    ('wrong Qt config directory', 'scripts/qtscrcpy-launch.sh', '/qtscrcpy"\nexport ANDROID', '/wrong"\nexport ANDROID', 'test-android-tools.sh'),
    ('wrong ADB key directory', 'scripts/uadng-launch.sh', '/android"', '/wrong"', 'test-android-tools.sh'),
    ('skip export directory', 'scripts/uadng-launch.sh', 'cd -- "$work_directory"', ':', 'test-android-tools.sh'),
    ('wrong ADB executable search', 'scripts/uadng-launch.sh', '$prefix/bin:$PATH', '$prefix/wrong:$PATH', 'test-android-tools.sh'),
    ('collapse UAD arguments', 'scripts/uadng-launch.sh', '"$@"', '"$*"', 'test-android-tools.sh'),
    ('ignore new apps', 'scripts/update-packages.sh', '.[] | select(has("id"))', '.[] | select(has("id")) | select(.package != "qtscrcpy")', 'test-package-updates.sh'),
    ('update only one dependency target', 'scripts/update-packages.sh', '.targets // [.package] | .[]', '.targets // [.package] | .[:1] | .[]', 'test-package-updates.sh'),
    ('require missing published app', 'scripts/update-packages.sh', ' && jq -e --arg package "$package" \'has($package)\' "$previous" >/dev/null', '', 'test-package-updates.sh'),
    ('keep stale release checksum', 'scripts/update-packages.sh', '.sha256 = $release[0].sha256', '.sha256 = .sha256', 'test-package-updates.sh'),
    ('skip ADB downgrade check', 'scripts/lib/package-versions.sh', "'keys[]'", "'keys[] | select(. != \"adb\")'", 'test-package-updates.sh'),
    ('accept empty saved publication', 'scripts/lib/package-versions.sh', ' and length > 0', '', 'test-package-updates.sh'),
    ('hash remote file as local', 'scripts/lib/package-versions.sh', ' and has("path")', '', 'test-package-updates.sh'),
    ('accept duplicate artifact refs', 'scripts/lib/package-versions.sh', 'select(length == 1)', 'select(length > 0)', 'test-package-updates.sh'),
]
for suite in ['test-android-tools.sh', 'test-package-updates.sh']:
    subprocess.run(['bash', str(root / 'tests' / suite)], check=True, stdout=subprocess.DEVNULL)
print('unmodified baseline passed', flush=True)
for label, file, old, new, suite in mutations:
    with tempfile.TemporaryDirectory(prefix='android-package-mutant-') as temporary:
        copy = Path(temporary)
        for directory in ['scripts', 'packages', 'tests']:
            shutil.copytree(root / directory, copy / directory)
        target = copy / file
        text = target.read_text()
        assert text.count(old) == 1, (label, text.count(old))
        target.write_text(text.replace(old, new))
        # A syntax error is not a killed behavioral mutant.
        subprocess.run(['bash', '-n', str(target)], check=True)
        with (copy / 'result.log').open('w') as log:
            result = subprocess.run(['bash', str(copy / 'tests' / suite)], stdout=log, stderr=log, timeout=180)
        if result.returncode == 0:
            raise SystemExit(f'SURVIVED: {label}')
        print(f'killed: {label}', flush=True)
print(f'{len(mutations)} behavioral mutants killed')
