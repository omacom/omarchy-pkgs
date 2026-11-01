#!/usr/bin/env python3
"""Validate expanded source/checksum alignment without downloading anything."""
import hashlib
from pathlib import Path
import subprocess
import sys

package = Path(sys.argv[1]).resolve()
script = '''
source "$1"
printf '%s\\0' "${source[@]}" ARRAY_END "${sha256sums[@]}" ARRAY_END "${b2sums[@]}" ARRAY_END "${source_aarch64[@]}" ARRAY_END "${sha256sums_aarch64[@]}" ARRAY_END "${b2sums_aarch64[@]}"
'''
parts = subprocess.check_output(
    ['bash', '-c', script, 'bash', str(package / 'PKGBUILD')]
).decode().rstrip('\0').split('\0ARRAY_END\0')
arrays = [part.split('\0') for part in parts]
assert len(arrays) == 6
checked = 0
for sources, sha, b2 in (arrays[:3], arrays[3:]):
    assert len(sources) == len(sha) == len(b2), 'source/checksum count mismatch'
    for name, sha_expected, b2_expected in zip(sources, sha, b2):
        if '://' in name:
            continue
        path = package / name
        assert path.is_file(), name
        for algorithm, expected in [('sha256', sha_expected), ('blake2b', b2_expected)]:
            if expected == 'SKIP':
                assert name.endswith(('.sig', '.sign', '.asc')), name
                continue
            assert hashlib.new(algorithm, path.read_bytes()).hexdigest() == expected, name
        checked += 1
config = (package / 'config.aarch64').read_text().splitlines()
for option in ['ACPI_PROCESSOR', 'ACPI_PROCESSOR_IDLE', 'PM_GENERIC_DOMAINS', 'CPU_IDLE', 'ARM_PSCI_FW', 'CRYPTO_LIB_SHA256']:
    assert f'CONFIG_{option}=y' in config, option
sources = arrays[0]
ordered = [name for name in sources if name.startswith(('1120-', '1121-', '1122-', '1123-'))]
assert len(ordered) == 4 and ordered == sorted(ordered)
print(f'PASS package sources/checksums: {checked} local files; coordinated suspend config prerequisites')
