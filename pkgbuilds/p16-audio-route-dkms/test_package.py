#!/usr/bin/env python3
"""Check DKMS family selection and the unchanged board-specific driver."""
import hashlib
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent


class PackageTests(unittest.TestCase):
    def test_new_versions_build_without_changing_the_family(self):
        text = (ROOT / 'dkms.conf').read_text()
        pattern = re.search(r'^BUILD_EXCLUSIVE_KERNEL="([^"]+)"$', text, re.M).group(1)
        for release in ('7.3.0-12-omarchy', '7.4.0-1-omarchy',
                        '7.5.0-2-omarchy', '8.0.0-2-omarchy'):
            self.assertIsNotNone(re.fullmatch(pattern, release), release)
        for release in ('7.3.0-12-custom', '7.4.0-1-arch',
                        '7.3.0-8-omarchy-n1x-pr1958-1', '7.3.0-12-omarchy-debug'):
            self.assertIsNone(re.fullmatch(pattern, release), release)

    def test_driver_scope_remains_exact(self):
        source = (ROOT / 'mt8901-acp-sdw-legacy-mach.c').read_bytes()
        self.assertEqual(hashlib.sha256(source).hexdigest(),
                         'c2f40519feadc69d6626953a04f57a4bc5345723c556d6b6eebf5134fff7c9ec')
        text = source.decode()
        for field, value in (('DMI_SYS_VENDOR', 'ASUS'), ('DMI_PRODUCT_NAME', 'ProArt P16 H7607BA'),
                             ('DMI_BOARD_NAME', 'H7607BA')):
            self.assertIn(f'DMI_EXACT_MATCH({field}, "{value}")', text)
        self.assertIn('acpi_dev_present("NVDA6210", NULL, -1)', text)
        self.assertEqual(text.count('{ "Speaker", NULL, "cs42l43 AMP'), 4)

    def test_recipe_local_sources_match_checksums(self):
        output = subprocess.check_output(['bash', '-c',
            'source "$1"; printf "%s\\0" "${source[@]}" END "${sha256sums[@]}"',
            'bash', str(ROOT / 'PKGBUILD')], cwd=ROOT)
        sources, sums = output.decode().rstrip('\0').split('\0END\0')
        for name, expected in zip(sources.split('\0'), sums.split('\0'), strict=True):
            self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), expected, name)


if __name__ == '__main__':
    unittest.main()
