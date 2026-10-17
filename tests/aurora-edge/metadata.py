#!/usr/bin/env python3
"""Check edge-only recipes and their declared compatibility upgrade versions."""
import json
import hashlib
import os
import tempfile
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
NAMES = ['linux-aurora', 'mesa-aurora', 'aura', 'uboot-aurora', 'aurora-bless',
         'speakerguardd', 'aurora-audio', 'alsa-ucm-conf-aurora', 'omarchy-aurora-firmware']


def srcinfo(name):
    # The checkout can be read-only in CI; makepkg still requires a writable build directory.
    with tempfile.TemporaryDirectory(prefix='aurora-srcinfo-') as build:
        output = subprocess.check_output(
            ['makepkg', '--printsrcinfo'], cwd=ROOT / 'pkgbuilds' / name,
            env={**os.environ, 'BUILDDIR': build, 'PKGDEST': build,
                 'SRCDEST': build, 'SRCPKGDEST': build, 'LOGDEST': build}, text=True)
    base, packages, current = {}, {}, None
    for raw in output.splitlines():
        if ' = ' not in raw:
            continue
        key, value = raw.strip().split(' = ', 1)
        if key == 'pkgname':
            current = packages.setdefault(value, {k: list(v) for k, v in base.items()})
        else:
            (base if current is None else current).setdefault(key, []).append(value)
    return packages


class EdgeMetadataTests(unittest.TestCase):
    def test_local_kernel_and_firmware_inputs_match_recipe_checksums(self):
        for name in ('linux-aurora', 'mesa-aurora', 'omarchy-aurora-firmware'):
            package = next(iter(srcinfo(name).values()))
            sources, digests = package['source'], package['sha256sums']
            self.assertEqual(len(sources), len(digests))
            for source, digest in zip(sources, digests):
                if '://' not in source:
                    with self.subTest(package=name, source=source):
                        actual = hashlib.sha256((ROOT / 'pkgbuilds' / name / source).read_bytes()).hexdigest()
                        self.assertEqual(actual, digest)

    def test_canonical_names_and_previous_draft_upgrades(self):
        for name in NAMES:
            for canonical in srcinfo(name):
                self.assertNotIn('asahi', canonical)
        for new, old in [('aurora-audio', 'asahi-audio-aurora'),
                         ('alsa-ucm-conf-aurora', 'alsa-ucm-conf-asahi-aurora'),
                         ('vulkan-aurora', 'vulkan-asahi-aurora')]:
            package = srcinfo('mesa-aurora' if new == 'vulkan-aurora' else new)[new]
            for field in ['conflicts', 'replaces']:
                self.assertIn(old, package[field])
            self.assertTrue(any(p.startswith(old + '=') for p in package['provides']))

    def test_only_edge_and_no_automatic_source_tracking(self):
        for name in NAMES:
            with self.subTest(name=name):
                value = json.loads((ROOT / 'pkgbuilds' / name / '.omarchy/package.json').read_text())
                self.assertEqual(value['channels'], ['edge'])
                self.assertFalse(value['sync'])
                self.assertEqual(value['source'], 'local')
                self.assertNotIn('release_ring', value)

    def test_stock_names_are_provided_but_never_replaced(self):
        # A replaces= on a stock name swaps it on every machine using [omarchy],
        # including Qualcomm and generic aarch64 ones, at their next update.
        for new, old in [('mesa-aurora', 'mesa'), ('vulkan-aurora', 'vulkan-asahi'),
                         ('aurora-bless', 'asahi-bless'), ('uboot-aurora', 'uboot-asahi'),
                         ('aurora-audio', 'asahi-audio'),
                         ('alsa-ucm-conf-aurora', 'alsa-ucm-conf-asahi'), ('aura', 'm1n1'),
                         ('aura', 'm1n1-aurora')]:
            base = 'mesa-aurora' if new.startswith('vulkan-') else new
            package = srcinfo(base)[new]
            self.assertIn(old, package['conflicts'])
            self.assertNotIn(old, package.get('replaces', []))
            if old != 'm1n1-aurora':
                self.assertTrue(any(p.startswith(old + '=') for p in package['provides']))

    def test_kernel_replaces_nothing(self):
        # linux-aurora sets its relations inside generated package functions,
        # which --printsrcinfo does not see.
        recipe = (ROOT / 'pkgbuilds' / 'linux-aurora' / 'PKGBUILD').read_text()
        self.assertNotIn('replaces=', recipe)

    def test_every_recipe_is_apple_silicon_only(self):
        for name in NAMES:
            for package in srcinfo(name).values():
                self.assertEqual(package['groups'], ['omarchy-platform-apple-silicon'])

    def test_mesa_follows_neither_llvm_nor_spirv_tools(self):
        for package in srcinfo('mesa-aurora').values():
            for dependency in ['llvm-libs', 'spirv-tools']:
                self.assertNotIn(dependency, package['depends'])

    def test_mesa_epoch_and_existing_neo_versions_upgrade(self):
        installed = {'mesa-aurora': '1:26.3.0_devel-932.a0bcbcb28528',
                     'linux-aurora': '7.1.12.aurora4-20261013.d08fd52e1619',
                     'speakerguardd': '0.1.0.aurora2-e03febfe52a5',
                     'aurora-audio': '4.1.aurora2-b2da7512e9bf',
                     'alsa-ucm-conf-aurora': '10.aurora2-e55107ad9ba2'}
        for name, old in installed.items():
            package = srcinfo(name)[name]
            prefix = package.get('epoch', ['0'])[0] + ':'
            new = prefix + package['pkgver'][0] + '-' + package['pkgrel'][0]
            self.assertGreater(int(subprocess.check_output(['vercmp', new, old], text=True)), 0)
        self.assertEqual(srcinfo('mesa-aurora')['mesa-aurora']['epoch'], ['1'])
        self.assertNotIn('epoch', srcinfo('linux-aurora')['linux-aurora'])

    def test_aura_independent_version_satisfies_legacy_kernel_dependency(self):
        package = srcinfo('aura')['aura']
        compatibility = next(p.split('=', 1)[1] for p in package['provides'] if p.startswith('m1n1='))
        self.assertGreaterEqual(int(subprocess.check_output(['vercmp', compatibility, '1.6.1.aurora19'], text=True)), 0)
        for old in ['m1n1', 'm1n1-aurora', 'm1n1-neo']:
            self.assertIn(old, package['conflicts'])
        self.assertEqual(package['replaces'], ['m1n1-neo'])


if __name__ == '__main__':
    unittest.main()
