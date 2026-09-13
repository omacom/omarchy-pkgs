#!/usr/bin/env python3
"""Exercise the packaged CVS exclusion with real DKMS in temporary trees.

Native m/y configs must stop before building. Legacy configs must reach
DKMS's missing-header check (21), proving the legacy driver stays eligible.
No module is installed or loaded.
"""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[1]
conf = (repo / 'pkgbuilds/intel-ipu7-camera/dkms-vision-drivers.conf').read_text()
conf = conf.replace('@PKGVER@', '1.0.6')
with tempfile.TemporaryDirectory(prefix='native-cvs-dkms-') as directory:
    for mode in ('m', 'y', 'n', 'absent'):
        root = pathlib.Path(directory) / mode
        source = root / 'src/vision-drivers-1.0.6'
        source.mkdir(parents=True)
        (source / 'dkms.conf').write_text(conf)
        (source / 'Makefile').write_text('all:\n\tfalse\n')
        kernel = root / 'kernel'
        kernel.mkdir()
        (kernel / '.config').write_text(
            '' if mode == 'absent' else f'CONFIG_VIDEO_INTEL_CVS={mode}\n')
        (root / 'dkms').mkdir()
        (root / 'modules').mkdir()
        result = subprocess.run([
            'dkms', 'build', '-m', 'vision-drivers', '-v', '1.0.6', '-k', '7.2.3-test',
            '--sourcetree', str(root / 'src'), '--dkmstree', str(root / 'dkms'),
            '--installtree', str(root / 'modules'), '--kernelsourcedir', str(kernel),
        ], capture_output=True, text=True)
        expected = 77 if mode in ('m', 'y') else 21
        assert result.returncode == expected, result.stdout + result.stderr
        print(f'PASS: CONFIG_VIDEO_INTEL_CVS={mode}: ' + (
            'legacy module excluded' if expected == 77 else 'legacy build remains eligible'))
