#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Compile the actual candidate callbacks with deterministic firmware mocks."""
from pathlib import Path
import os
import sys
import subprocess
import tempfile

root = Path(__file__).resolve().parent
source = Path(sys.argv[1]).resolve() / 'drivers/soc/mediatek/power_wrap/power_wrap_lps0.c'
with tempfile.TemporaryDirectory(prefix='n1x-lps0-test-') as tmp:
    tmp = Path(tmp)
    # Supply kernel API mocks; keep every function body byte-for-byte.
    tmp.joinpath('lps0-under-test.c').write_text(''.join(
        line for line in source.read_text().splitlines(keepends=True)
        if not line.startswith('#include ')))
    for sanitizer in ('', 'address,undefined'):
        cmd = [os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra',
               '-Werror', '-g', '-I', str(tmp), str(root / 'test_lps0.c'),
               '-o', str(tmp / 'test_lps0')]
        if sanitizer:
            cmd += [f'-fsanitize={sanitizer}', '-fno-omit-frame-pointer']
        subprocess.run(cmd, check=True)
        subprocess.run([str(tmp / 'test_lps0')], check=True)
print('plain and ASan/UBSan checks passed')
