#!/usr/bin/env python3
"""Check the Aurora recipes and their declared compatibility upgrade versions."""
import concurrent.futures
import functools
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NAMES = ['linux-aurora', 'mesa-aurora', 'aura', 'm1n1-aurora', 'uboot-aurora', 'aurora-bless',
         'speakerguardd', 'aurora-audio', 'alsa-ucm-conf-aurora', 'omarchy-aurora-firmware',
         'speakersafetyd', 'bankstown', 'triforce-lv2', 'lzfse', 'aurora-scripts', 'aurora-fwextract',
         'muvm', 'fex-emu', 'widevine']
# Same-name imports from asahi-alarm, with the version each replaces on installed Macs.
# Each tracks its upstream through a reviewed watch (docs/upstream-sources.md).
ASAHI_ALARM_IMPORTS = {'speakersafetyd': '2.0.1-1', 'bankstown': '1.1.0-2', 'triforce-lv2': '0.3.2-1',
                       'lzfse': '1.0-1', 'muvm': '0.7.0-1'}
REVIEWED = [*ASAHI_ALARM_IMPORTS, 'aurora-scripts', 'aurora-fwextract', 'fex-emu', 'widevine']


_FAST_LIB_DIR = None
_FAST_LIB_TMP = None


def _cpu_limit():
    n = len(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else (os.cpu_count() or 1)
    try:
        parts = Path('/sys/fs/cgroup/cpu.max').read_text().split()
        if len(parts) == 2 and parts[0] != 'max':
            quota, period = int(parts[0]), int(parts[1])
            if period > 0:
                n = min(n, max(1, (quota + period - 1) // period))
    except OSError:
        pass
    return n


def _makepkg_library():
    global _FAST_LIB_DIR, _FAST_LIB_TMP
    existing = os.environ.get('MAKEPKG_LIBRARY')
    if existing:
        return existing
    if _FAST_LIB_DIR is None:
        helper = ROOT / 'helpers/fast-makepkg.sh'
        if helper.is_file():
            _FAST_LIB_TMP = tempfile.mkdtemp(prefix='aurora-libmakepkg-')
            _FAST_LIB_DIR = subprocess.check_output(
                ['bash', str(helper), os.path.join(_FAST_LIB_TMP, 'lib')], text=True).strip()
    return _FAST_LIB_DIR


@functools.lru_cache(maxsize=None)
def srcinfo(name):
    # The checkout can be read-only in CI; makepkg still requires a writable build directory.
    with tempfile.TemporaryDirectory(prefix='aurora-srcinfo-') as build:
        env = {**os.environ, 'BUILDDIR': build, 'PKGDEST': build,
               'SRCDEST': build, 'SRCPKGDEST': build, 'LOGDEST': build}
        lib = _makepkg_library()
        if lib:
            env['MAKEPKG_LIBRARY'] = lib
        output = subprocess.check_output(
            ['makepkg', '--printsrcinfo'], cwd=ROOT / 'pkgbuilds' / name,
            env=env, text=True)
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


def setUpModule():
    # Pre-warm the read-only .SRCINFO cache in parallel across available CPUs.
    _makepkg_library()
    unique = list(dict.fromkeys([*NAMES, 'omarchy-steam-fex', 'omarchy-mac-boot', 'omarchy-mac']))
    with concurrent.futures.ThreadPoolExecutor(max_workers=_cpu_limit()) as pool:
        list(pool.map(srcinfo, unique))


def tearDownModule():
    global _FAST_LIB_DIR, _FAST_LIB_TMP
    if _FAST_LIB_TMP:
        shutil.rmtree(_FAST_LIB_TMP, ignore_errors=True)
    _FAST_LIB_DIR = None
    _FAST_LIB_TMP = None


class EdgeMetadataTests(unittest.TestCase):
    def test_runtime_only_dependencies_remain_in_packages_not_build_environments(self):
        expected = {
            'aura': ['aurora-scripts>=20260127.1', 'uboot-aurora'],
            'm1n1-aurora': ['aurora-scripts>=20260127.1', 'uboot-asahi'],
            'aurora-fwextract': ['python', 'aurora-scripts', 'lzfse'],
            'omarchy-steam-fex': ['bash', 'coreutils', 'python', 'steam', 'muvm', 'FEX-Emu'],
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
        # Aurora's own recipes are pinned by hand. The asahi-alarm imports follow
        # their upstreams, but every bump waits for the owner as a draft PR.
        for name in NAMES:
            with self.subTest(name=name):
                value = json.loads((ROOT / 'pkgbuilds' / name / '.omarchy/package.json').read_text())
                self.assertEqual(value['source'], 'local')
                self.assertNotIn('release_ring', value)
                self.assertNotIn('auto_merge', value)
                if name in REVIEWED:
                    self.assertNotIn('sync', value)
                    self.assertIs(value['review'], True)
                    self.assertIn('watch', value['upstream'])
                else:
                    self.assertFalse(value['sync'])

    def test_asahi_alarm_imports_take_over_installed_packages(self):
        # [omarchy] is listed first, so a renamed import replaces the asahi-alarm package.
        # fex-emu is renamed only because package names here are lower case.
        for new, old in [('aurora-scripts', 'asahi-scripts'), ('aurora-fwextract', 'asahi-fwextract'),
                         ('fex-emu', 'FEX-Emu')]:
            with self.subTest(package=new):
                package = srcinfo(new)[new]
                self.assertIn(old + '=' + package['pkgver'][0], package['provides'])
                self.assertEqual(package['conflicts'], [old])
                self.assertEqual(package['replaces'], [old])
        for name, asahi_alarm in [('aurora-scripts', '20261023-1'), ('aurora-fwextract', '0.9.2-1'),
                                  ('fex-emu', '2604-1')]:
            with self.subTest(package=name):
                package = srcinfo(name)[name]
                new = package['pkgver'][0] + '-' + package['pkgrel'][0]
                self.assertGreaterEqual(int(subprocess.check_output(['vercmp', new, asahi_alarm], text=True)), 0)
        for name in ('aura', 'm1n1-aurora', 'omarchy-mac-boot'):
            with self.subTest(package=name):
                depends = srcinfo(name)[name]['depends']
                self.assertIn('aurora-scripts>=20260127.1', depends)
                self.assertFalse([d for d in depends if d.startswith('asahi-scripts')])
        for name in ('aurora-scripts', 'aurora-fwextract', 'lzfse'):
            with self.subTest(package=name):
                self.assertIn('install -Dm644', (ROOT / 'pkgbuilds' / name / 'PKGBUILD').read_text())
                self.assertIn('/usr/share/licenses/$pkgname/LICENSE', (ROOT / 'pkgbuilds' / name / 'PKGBUILD').read_text())

    def test_fex_emu_declares_the_libraries_its_tools_link(self):
        package = srcinfo('fex-emu')['fex-emu']
        self.assertIn('xxhash', package['depends'])
        self.assertNotIn('qt6-declarative', package['depends'])
        self.assertTrue(any(o.startswith('qt6-declarative: FEXConfig') for o in package['optdepends']))

    def test_stock_names_are_provided_but_never_replaced(self):
        # A replaces= on a stock name swaps it on every machine using [omarchy],
        # including Qualcomm and generic aarch64 ones, at their next update.
        for new, old in [('mesa-aurora', 'mesa'), ('vulkan-aurora', 'vulkan-asahi'),
                         ('aurora-bless', 'asahi-bless'), ('uboot-aurora', 'uboot-asahi'),
                         ('aurora-audio', 'asahi-audio'),
                         ('alsa-ucm-conf-aurora', 'alsa-ucm-conf-asahi'), ('aura', 'm1n1')]:
            base = 'mesa-aurora' if new.startswith('vulkan-') else new
            package = srcinfo(base)[new]
            self.assertIn(old, package['conflicts'])
            self.assertNotIn(old, package.get('replaces', []))
            if old != 'm1n1-aurora':
                self.assertTrue(any(p.startswith(old + '=') for p in package['provides']))

    def test_asahi_alarm_imports_upgrade_in_place(self):
        # The [omarchy] build must win by version alone: same name, same pkgver,
        # higher pkgrel, and no relations that would touch other machines.
        for name, old in ASAHI_ALARM_IMPORTS.items():
            with self.subTest(package=name):
                package = srcinfo(name)[name]
                self.assertNotIn('epoch', package)
                # At least asahi-alarm's pkgver: a reviewed bump may move past it.
                self.assertGreaterEqual(int(subprocess.check_output(['vercmp', package['pkgver'][0], old.split('-')[0]], text=True)), 0)
                new = package['pkgver'][0] + '-' + package['pkgrel'][0]
                self.assertGreater(int(subprocess.check_output(['vercmp', new, old], text=True)), 0)
                for field in ['provides', 'conflicts', 'replaces']:
                    self.assertNotIn(field, package)
        triforce = srcinfo('triforce-lv2')['triforce-lv2']['pkgver'][0]
        self.assertGreaterEqual(int(subprocess.check_output(['vercmp', triforce, '0.2.0'], text=True)), 0)

    def test_speakersafetyd_unit_stays_where_its_drop_in_and_preset_expect(self):
        # speakerguardd's drop-in and omarchy-mac's preset name this unit path.
        recipe = (ROOT / 'pkgbuilds' / 'speakersafetyd' / 'PKGBUILD').read_text()
        self.assertIn('UNITDIR=/usr/lib/systemd/system', recipe)
        guard = (ROOT / 'pkgbuilds' / 'speakerguardd' / 'PKGBUILD').read_text()
        self.assertIn('"$pkgdir/usr/lib/systemd/system/speakersafetyd.service.d/50-j700-guard.conf"', guard)

    def test_kernel_replaces_nothing(self):
        # linux-aurora sets its relations inside generated package functions,
        # which --printsrcinfo does not see.
        recipe = (ROOT / 'pkgbuilds' / 'linux-aurora' / 'PKGBUILD').read_text()
        self.assertNotIn('replaces=', recipe)

    def test_kernel_and_platform_hold_mesa_to_the_aurora_gpu_driver(self):
        # The 7.3 kernel names its GPU driver "aurora": stock mesa and older
        # mesa-aurora have no aurora_dri.so and leave a black screen.
        mesa = srcinfo('mesa-aurora')['mesa-aurora']
        built = mesa['epoch'][0] + ':' + mesa['pkgver'][0]
        recipe = (ROOT / 'pkgbuilds' / 'linux-aurora' / 'PKGBUILD').read_text()
        floor = next(line.split('=', 1)[1] for line in recipe.splitlines()
                     if line.startswith('_mesa_version='))
        self.assertGreaterEqual(int(subprocess.check_output(['vercmp', built, floor], text=True)), 0)
        # A floor as a conflict, so a headless install does not pull Mesa in.
        self.assertIn('"mesa-aurora<$_mesa_version" "vulkan-aurora<$_mesa_version"', recipe)
        self.assertNotIn('mesa-aurora', ''.join(l for l in recipe.splitlines() if 'depends=' in l))
        depends = srcinfo('omarchy-mac')['omarchy-mac']['depends']
        self.assertIn('mesa-aurora>=' + floor, depends)
        self.assertIn('vulkan-aurora>=' + floor, depends)
        self.assertNotIn('vulkan-asahi', depends)

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

    def test_mesa_follows_llvm_by_soname_and_only_rusticl_links_spirv_tools(self):
        # llvmpipe and Rusticl link the system LLVM. Both packages depend on
        # 'libLLVM.so', which makepkg versions from the NEEDED soname, so an
        # LLVM major bump blocks the upgrade instead of breaking either driver.
        # SPIRV-Tools has no versioned soname, so only OpenCL may follow it.
        packages = srcinfo('mesa-aurora')
        self.assertEqual(sorted(packages), ['mesa-aurora', 'opencl-aurora', 'vulkan-aurora'])
        for name, package in packages.items():
            if name != 'opencl-aurora':
                self.assertNotIn('spirv-tools', package['depends'])
            self.assertNotIn('llvm-libs', package['depends'])
        for name in ('mesa-aurora', 'opencl-aurora'):
            self.assertEqual([d for d in packages[name]['depends'] if d.startswith('libLLVM')],
                             ['libLLVM.so'])
        self.assertFalse([d for d in packages['vulkan-aurora']['depends'] if d.startswith('libLLVM')])
        opencl = packages['opencl-aurora']
        mesa = packages['mesa-aurora']
        self.assertIn(f"mesa-aurora={mesa['epoch'][0]}:{mesa['pkgver'][0]}-{mesa['pkgrel'][0]}",
                      opencl['depends'])
        self.assertEqual(opencl['provides'], ['opencl-driver'])
        self.assertEqual(opencl['conflicts'], ['opencl-mesa'])

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
        # On edge, aura replaces m1n1-aurora; replacing it back would swap on every update.
        self.assertEqual(package['replaces'], ['m1n1-neo'])
        self.assertEqual(package['conflicts'], ['m1n1', 'aura', 'm1n1-neo', 'linux-aurora<7.2.11.aurora16'])
        # The kernel floor is a conflict: linux-aurora depends on m1n1, so a dependency would loop.
        self.assertFalse(any(d.startswith('linux-aurora') for d in package['depends']))
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
        # The edge boot loader: a system update moves m1n1-aurora Macs to aura, and
        # aura has no monitor without the 7.3 kernel's CONFIG_ARM64_CTXR_EXECMEM.
        self.assertEqual(package['replaces'], ['m1n1-aurora', 'm1n1-neo'])
        self.assertIn('linux-aurora<7.3.0', package['conflicts'])
        self.assertNotIn('aura', srcinfo('m1n1-aurora')['m1n1-aurora']['replaces'])


if __name__ == '__main__':
    unittest.main()
