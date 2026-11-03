#!/usr/bin/env python3
"""Check the Aurora recipes and their declared compatibility upgrade versions."""
import json
import hashlib
import os
import tempfile
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
NAMES = ['linux-aurora', 'mesa-aurora', 'aura', 'm1n1-aurora', 'uboot-aurora', 'aurora-bless',
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
    def test_runtime_only_dependencies_remain_in_packages_not_build_environments(self):
        expected = {
            'aura': ['asahi-scripts>=20260127.1', 'uboot-aurora'],
            'm1n1-aurora': ['asahi-scripts>=20260127.1', 'uboot-asahi'],
            'aurora-audio': ['alsa-ucm-conf-aurora', 'pipewire-audio', 'wireplumber',
                             'bankstown', 'lsp-plugins-lv2', 'triforce-lv2>=0.2.0',
                             'speakersafetyd', 'speakerguardd'],
            'omarchy-aurora-firmware': ['bash', 'iw', 'kmod', 'omarchy-mac-boot',
                                       'wireless-regdb', 'linux-aurora>=7.1.12.aurora5'],
        }
        for name, dependencies in expected.items():
            with self.subTest(package=name):
                self.assertEqual(srcinfo(name)[name]['depends'], dependencies)
                build_dependencies = subprocess.check_output(
                    ['bash', '-c', 'source "$1"; printf "%s\\n" "${depends[@]}"',
                     'fixture', str(ROOT / 'pkgbuilds' / name / 'PKGBUILD')], text=True)
                self.assertEqual(build_dependencies.strip(), '')

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

    def test_no_automatic_source_tracking(self):
        for name in NAMES:
            with self.subTest(name=name):
                value = json.loads((ROOT / 'pkgbuilds' / name / '.omarchy/package.json').read_text())
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

    def test_kernel_ships_the_calibration_extractor_beside_aurora_touchid(self):
        # The extractor is installed from the kernel's own tree. Its path must stay
        # clear of aurora-touchid's copy so both packages can be installed at once.
        recipe = (ROOT / 'pkgbuilds' / 'linux-aurora' / 'PKGBUILD').read_text()
        self.assertIn('install -Dm755 tools/aurora-sep/extract-mesa-calibration.py', recipe)
        self.assertIn('"$pkgdir/usr/lib/linux-aurora/extract-mesa-calibration"', recipe)
        self.assertNotIn('/usr/lib/aurora-touchid/', recipe)
        self.assertIn('python -I tools/aurora-sep/tests/test_extract_mesa_calibration.py', recipe)
        self.assertIn('python: extract-mesa-calibration, for Touch ID', recipe)

    def test_every_recipe_is_apple_silicon_only(self):
        for name in NAMES:
            for package in srcinfo(name).values():
                self.assertEqual(package['groups'], ['omarchy-platform-apple-silicon'])

    def test_mesa_follows_llvm_by_soname_and_never_spirv_tools(self):
        # llvmpipe links the system LLVM. mesa-aurora depends on 'libLLVM.so',
        # which makepkg versions from libgallium's NEEDED soname, so an LLVM
        # major bump blocks the upgrade instead of breaking libgallium.
        packages = srcinfo('mesa-aurora')
        for package in packages.values():
            self.assertNotIn('spirv-tools', package['depends'])
            self.assertNotIn('llvm-libs', package['depends'])
        self.assertEqual([d for d in packages['mesa-aurora']['depends'] if d.startswith('libLLVM')],
                         ['libLLVM.so'])
        self.assertFalse([d for d in packages['vulkan-aurora']['depends'] if d.startswith('libLLVM')])

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

    def test_omacom_loader_migrates_only_downstream_providers(self):
        package = srcinfo('m1n1-aurora')['m1n1-aurora']
        self.assertEqual(package['replaces'], ['aura', 'm1n1-neo'])
        self.assertEqual(package['conflicts'], ['m1n1', 'aura', 'm1n1-neo'])
        self.assertNotIn('install', package)
        version = package['pkgver'][0]
        self.assertGreater(int(subprocess.check_output(['vercmp', version, '1.6.1.aurora1'], text=True)), 0)
        self.assertGreaterEqual(int(subprocess.check_output(['vercmp', version, '1.6.1.aurora19'], text=True)), 0)
        self.assertIn('m1n1=' + version, package['provides'])
        self.assertEqual(package['url'], ['https://github.com/omacom/m1n1'])
        # Upgrading must not force a U-Boot swap: either installed provider satisfies it.
        self.assertIn('uboot-asahi', package['depends'])
        self.assertNotIn('uboot-aurora', package['depends'])
        uboot = srcinfo('uboot-aurora')['uboot-aurora']
        self.assertTrue(any(p.startswith('uboot-asahi=') for p in uboot['provides']))
        record = json.loads((ROOT / 'pkgbuilds/m1n1-aurora/build-qualification.json').read_text())
        self.assertIn('m1n1::git+https://github.com/omacom/m1n1.git#commit=' + record['source_commit'], package['source'])
        self.assertEqual(len(package['source']), len(package['sha256sums']))
        for source, digest in zip(package['source'], package['sha256sums']):
            if '://' not in source:
                self.assertEqual(hashlib.sha256((ROOT / 'pkgbuilds/m1n1-aurora' / source).read_bytes()).hexdigest(), digest)

    def test_aura_independent_version_satisfies_legacy_kernel_dependency(self):
        package = srcinfo('aura')['aura']
        compatibility = next(p.split('=', 1)[1] for p in package['provides'] if p.startswith('m1n1='))
        self.assertGreaterEqual(int(subprocess.check_output(['vercmp', compatibility, '1.6.1.aurora19'], text=True)), 0)
        for old in ['m1n1', 'm1n1-aurora', 'm1n1-neo']:
            self.assertIn(old, package['conflicts'])
        self.assertEqual(package['replaces'], ['m1n1-neo'])


if __name__ == '__main__':
    unittest.main()
