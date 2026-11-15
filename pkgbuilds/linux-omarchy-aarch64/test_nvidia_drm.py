#!/usr/bin/env python3
"""Compile the packaged NVIDIA colorspace transaction with injected failures."""
from pathlib import Path
import importlib.util
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('drm_harness', root / 'nvidia-drm-harness.py')
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)
text = (Path(sys.argv[1]) / 'kernel-open/nvidia-drm/nvidia-drm-drv.c').read_text()
start = text.index('static\nint nv_drm_reset_input_colorspace(')
function = text[start:text.index('\n}\n', start) + 3]
with tempfile.TemporaryDirectory() as temp:
    source, binary = Path(temp) / 'drm.c', Path(temp) / 'drm'
    source.write_text(harness.PRELUDE + function + harness.MAIN)
    subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-function', '-fsanitize=address,undefined',
                    str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary), '1'], check=True)
print('PASS packaged NVIDIA DRM failure/backoff/cleanup cases')
