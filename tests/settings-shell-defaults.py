#!/usr/bin/env python3
"""Check shell seeding without touching the host's system configuration."""

import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check(scriptlet, apple, missing=False):
    source = scriptlet.read_text()
    start = source.index('_etc_overrides_apply() {')
    end = source.index('\n}\n', start) + 3
    source = source[start:end]
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name in ('etc', 'usr/lib', 'usr/share/omarchy/etc-overrides'):
            (root / name).mkdir(parents=True, exist_ok=True)
        (root / 'usr/lib/os-release').write_text('ID=archarm\n')
        defaults = root / 'usr/share/omarchy/etc-overrides'
        for name in ('os-release', 'security-faillock.conf', 'nsswitch.conf',
                     'plymouth-plymouthd.conf'):
            (defaults / name).write_text('fixture\n')
        if not missing:
            (defaults / 'dot.bashrc').write_text('source omarchy-bash-rc\n')
        source = re.sub(r'/(?:etc|usr)(?=/)', directory + r'\g<0>', source)
        # Fail closed if a future scriptlet adds a host path we do not redirect.
        executable = '\n'.join(line for line in source.splitlines()
                               if not line.lstrip().startswith('#'))
        assert not re.search(r'(?<![\w/])/(?:etc|usr|run|var)(?:/|\b)', executable)
        source += '\n_apple_silicon() { ' + ('true' if apple else 'false') + '; }\n'
        source += '_etc_overrides_apply\n'
        result = subprocess.run(['bash', '-c', source], capture_output=True, text=True)
        if missing:
            assert result.returncode != 0, 'missing template must report failure'
            return
        assert result.returncode == 0, result.stderr
        target = root / 'etc/skel/.bashrc'
        assert target.read_text() == 'source omarchy-bash-rc\n'
        assert target.stat().st_mode & 0o777 == 0o644
        if apple:
            assert (root / 'etc/os-release').is_symlink()
            assert not (root / 'etc/nsswitch.conf').exists()
            assert not (root / 'etc/security/faillock.conf').exists()
            assert not (root / 'etc/plymouth/plymouthd.conf').exists()
        else:
            assert (root / 'etc/nsswitch.conf').read_text() == 'fixture\n'


for package in ('omarchy-settings', 'omarchy-settings-dev'):
    scriptlet = ROOT / 'pkgbuilds' / package / (package + '.install')
    for apple in (True, False):
        check(scriptlet, apple)
        check(scriptlet, apple, missing=True)
    print(f'{package}: Apple Silicon, other platforms, and missing template PASS')
