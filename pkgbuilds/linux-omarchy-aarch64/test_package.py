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
for option in ('ACPI_WMI', 'ASUS_WMI', 'ASUS_NB_WMI', 'SPI_HID_ACPI'):
    assert f'CONFIG_{option}=m' in config, option
for option in ('ASUS_ARMOURY', 'ASUS_WMI_DEPRECATED_ATTRS'):
    assert f'# CONFIG_{option} is not set' in config, option
sources = arrays[0]
ordered = [name for name in sources if name.startswith(('1120-', '1121-', '1122-', '1123-', '1124-', '1125-'))]
assert len(ordered) == 6 and ordered == sorted(ordered)
platform = [name for name in sources if name.startswith(('9100-', '9101-', '9102-', '9103-', '9104-', '9105-', '9106-', '9107-'))]
assert len(platform) == 8 and platform == sorted(platform)
assert '9105-mt7925-mld-membership.patch' in sources and 'test_mld.py' in sources
assert '9106-pinctrl-unsupported-debounce.patch' in sources and 'test_usb_debounce.py' in sources
assert '9107-xhci-acpi-gpio-wake.patch' in sources and 'test_usb_wake.py' in sources
for name in ('9110-n1x-sroot-noncoherent-dma.patch', '9111-spi-hid-serialize-get.patch',
             '9112-spi-hid-stream-only.patch', '9113-spi-hid-native-input-length.patch',
             'test_npu_cca.py', 'test_spi_get_requests.py', 'test_spi_lengths_stream.py'):
    assert sources.count(name) == 1, name
assert not any('p16-platform-bundle' in name for name in sources)
assert not any('rtc-diagnostic' in name or 'rtc-debug' in name for name in sources)
assert not any('p16-platform-support' in name for name in sources)
no_source = subprocess.run([sys.executable, str(package / 'test_npu_cca.py')],
                           text=True, capture_output=True)
assert no_source.returncode == 2, no_source.stderr
assert 'usage:' in no_source.stderr and 'kernel_source' in no_source.stderr
assert 'Traceback' not in no_source.stderr and not no_source.stdout
print('PASS SROOT coherency harness requires an explicit prepared kernel tree')
print(f'PASS package sources/checksums: {checked} local files; coordinated suspend config prerequisites')
