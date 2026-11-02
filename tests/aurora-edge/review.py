#!/usr/bin/env python3
"""Execute package review regressions without building or booting a kernel."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def shell(script, *args, **kwargs):
    return subprocess.run(['bash', '-c', script, 'fixture', *map(str, args)],
                          text=True, capture_output=True, **kwargs)


class KernelRecipeTests(unittest.TestCase):
    def test_command_line_bindgen_wins_over_kbuild_assignment_in_every_phase(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Makefile').write_text('BINDGEN = ignored-system-bindgen\nprobe:\n\t@echo $(BINDGEN)\n\t@echo $$AURORA_BINDGEN_REAL\n\t@echo $$RUSTUP_TOOLCHAIN\n\t@echo $$RUSTFMT\n')
            recipe = ROOT / 'pkgbuilds/linux-aurora/PKGBUILD'
            result = shell('source "$1"; srcdir="$2"; rustup() { [[ "$*" == "which --toolchain 1.99.0 rustfmt" ]] && echo /qualified/rustfmt; }; _make -s -f "$2/Makefile" probe', recipe, root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [
                str(root / 'bindgen-kernel.py'),
                str(root / 'private-bindgen/rust-bindgen-0.73.2/target/release/bindgen'), '1.85.0',
                '/qualified/rustfmt'])

    def test_shared_config_keeps_existing_machine_behaviour(self):
        package = ROOT / 'pkgbuilds/linux-aurora'
        recipe = (package / 'PKGBUILD').read_text()
        helper = (package / 'configure.sh').read_text()
        self.assertIn('source ../configure.sh', recipe)
        self.assertIn('configure_kernel "$PWD/.." "$PWD/build/base"', recipe)
        self.assertIn('cp "$config_dir/config" "$output_dir/.config"', helper)
        self.assertIn("grep -qx 'CONFIG_RUST=y'", helper)
        gate = (ROOT / 'tests/aurora-edge/configure.py').read_text()
        self.assertIn('source "$1/configure.sh"', gate)
        self.assertIn('configure_kernel "$2" "$3" "$4"', gate)
        self.assertIn('resolve_kernel_config "$2" "$3" "$4"', gate)
        self.assertIn('resolve_kernel_config "$config_dir" "$output_dir" "${3:-}" || return', helper)
        self.assertNotIn('j700.config', recipe)
        self.assertNotIn('j700-device-parity.config', recipe)
        original = (package / 'config').read_text()
        for setting in ['CONFIG_USB4=m', 'CONFIG_DEBUG_INFO_BTF=y', 'CONFIG_KEXEC_FILE=y',
                        'CONFIG_RELR=y', 'CONFIG_RUST=y']:
            self.assertIn(setting, original)
        self.assertFalse((package / 'common.config').exists())
        self.assertFalse((package / 'neo.config').exists())

    def test_generated_release_keeps_boot_bundle_suffix(self):
        recipe = ROOT / 'pkgbuilds/linux-aurora/PKGBUILD'
        for release, expected in [('7.1.12-6-2-ARCH', 0), ('7.1.12-6-2-aurora', 1),
                                  ('7.1.12-6-2-ARCH-extra', 1), ('', 1)]:
            with self.subTest(release=release):
                result = shell('source "$1"; _check_kernelrelease "$2"', recipe, release)
                self.assertEqual(result.returncode, expected, result.stderr)
        self.assertIn('_check_kernelrelease "$(<build/base/version)"', recipe.read_text())

    def test_platform_choices_come_from_the_pinned_kernel(self):
        package = ROOT / 'pkgbuilds/linux-aurora'
        recipe = (package / 'PKGBUILD').read_text()
        helper = (package / 'configure.sh').read_text()
        self.assertNotIn('common.config', recipe)
        self.assertNotIn('neo.config', recipe)
        self.assertIn('fragments=(arch/arm64/configs/asahi.config)', helper)
        self.assertIn('python3 "$config_dir/validate-config.py" arch/arm64/configs/asahi.config', helper)
        self.assertFalse(any(line.startswith('CONFIG_') for line in helper.splitlines()))

    def test_trusted_keys_cannot_downgrade_the_builtin_sep_driver(self):
        package = ROOT / 'pkgbuilds/linux-aurora'
        spec = importlib.util.spec_from_file_location('sep_config_check', package / 'validate-config.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            fragment = Path(temporary) / 'asahi.config'
            fragment.write_text('CONFIG_TRUSTED_KEYS=y\nCONFIG_APPLE_SEP=y\n')
            resolved = Path(temporary) / 'config'
            resolved.write_text(fragment.read_text())
            module.validate(fragment, resolved)
            for actual in ('m', 'n'):
                resolved.write_text(fragment.read_text().replace('CONFIG_APPLE_SEP=y',
                                                                'CONFIG_APPLE_SEP=' + actual))
                with self.assertRaisesRegex(ValueError, 'CONFIG_APPLE_SEP'):
                    module.validate(fragment, resolved)

    def test_generated_config_must_keep_every_requested_capability(self):
        validator = ROOT / 'pkgbuilds/linux-aurora/validate-config.py'
        spec = importlib.util.spec_from_file_location('config_check', validator)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            resolved = Path(temporary) / 'config'
            fragment = Path(temporary) / 'asahi.config'
            fragment.write_text('CONFIG_SND_SOC_APPLE_T8140_AOP_AUDIO=m\n')
            resolved.write_text(fragment.read_text())
            module.validate(fragment, resolved)
            resolved.write_text(fragment.read_text().replace(
                'CONFIG_SND_SOC_APPLE_T8140_AOP_AUDIO=m', '# CONFIG_SND_SOC_APPLE_T8140_AOP_AUDIO is not set'))
            with self.assertRaisesRegex(ValueError, 'CONFIG_SND_SOC_APPLE_T8140_AOP_AUDIO'):
                module.validate(fragment, resolved)

    def test_inactive_parent_can_omit_a_requested_disabled_symbol(self):
        validator = ROOT / 'pkgbuilds/linux-aurora/validate-config.py'
        spec = importlib.util.spec_from_file_location('disabled_config_check', validator)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temporary:
            fragment = Path(temporary) / 'asahi.config'
            fragment.write_text('# CONFIG_TRUSTED_KEYS_TPM is not set\nCONFIG_VIDEO_APPLE_ISP=m\n')
            resolved = Path(temporary) / 'config'
            resolved.write_text('CONFIG_VIDEO_APPLE_ISP=m\n')
            module.validate(fragment, resolved)
            resolved.write_text('CONFIG_TRUSTED_KEYS_TPM=y\nCONFIG_VIDEO_APPLE_ISP=m\n')
            with self.assertRaisesRegex(ValueError, 'CONFIG_TRUSTED_KEYS_TPM'):
                module.validate(fragment, resolved)
            resolved.write_text('')
            with self.assertRaisesRegex(ValueError, 'CONFIG_VIDEO_APPLE_ISP'):
                module.validate(fragment, resolved)

    def test_headers_require_resolver_only_when_btf_enabled(self):
        recipe = ROOT / 'pkgbuilds/linux-aurora/PKGBUILD'
        for enabled, resolver, expected in [(False, False, 0), (True, False, 1), (True, True, 0)]:
            with self.subTest(btf=enabled, resolver=resolver), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                output = root / 'linux/build/base'
                output.mkdir(parents=True)
                (output / 'version').write_text('fixture\n')
                (output / '.config').write_text('CONFIG_DEBUG_INFO_BTF=y\n' if enabled else '# CONFIG_DEBUG_INFO_BTF is not set\n')
                if resolver:
                    binary = output / 'tools/bpf/resolve_btfids/resolve_btfids'
                    binary.parent.mkdir(parents=True)
                    binary.write_text('#!/bin/sh\n')
                    binary.chmod(0o755)
                result = shell('''source "$1"
cd "$2"
pkgdir="$2/pkg"; _srcname=linux
install() { :; }; cp() { :; }; rm() { :; }; find() { :; }; _make() { :; }
_package-headers
''', recipe, root)
                self.assertEqual(result.returncode, expected, result.stderr)


class MesaRecipeTests(unittest.TestCase):
    def test_cpu_tests_fail_the_package_and_runtime_abi_is_checked(self):
        # Only libgallium may link LLVM, exactly one libLLVM.so.<major>.<minor>,
        # and it must be executable so makepkg versions the 'libLLVM.so' depend
        # from it; it must link LLVM, or llvmpipe is missing. SPIRV-Tools stays
        # out everywhere.
        recipe = ROOT / 'pkgbuilds/mesa-aurora/PKGBUILD'
        llvm23, llvm24 = 'libLLVM.so.23.1', 'libLLVM.so.24.1'
        for test_status, gallium, other, reader_status, executable, expected in [
            (0, llvm23, '', 0, True, 0),
            (0, llvm24, '', 0, True, 0),
            (1, llvm23, '', 0, True, 1),
            (0, llvm23, '', 1, True, 1),
            (0, llvm23, '', 0, False, 1),
            (0, '', '', 0, True, 1),
            (0, f'{llvm23} {llvm24}', '', 0, True, 1),
            (0, llvm23, llvm23, 0, True, 1),
            (0, llvm23, 'libSPIRV-Tools.so', 0, True, 1)]:
            with self.subTest(tests=test_status, gallium=gallium, other=other, reader=reader_status, executable=executable), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                stage = root / 'mesa-stage'
                stage.mkdir()
                gallium_file = stage / 'libgallium-26.3.0-devel.so'
                gallium_file.write_bytes(b'fixture')
                gallium_file.chmod(0o755 if executable else 0o644)
                other_file = stage / 'libvulkan_asahi.so'
                other_file.write_bytes(b'fixture')
                other_file.chmod(0o755)
                result = shell('source "$1"\nsrcdir="$2"\nmeson() { printf \'%s\\n\' "$*"; return "$TEST_STATUS"; }\n'
                               'readelf() { local needed=$OTHER; [[ ${2##*/} == libgallium-* ]] && needed=$GALLIUM; '
                               'for lib in $needed; do echo " 0x1 (NEEDED) Shared library: [$lib]"; done; return "$READER_STATUS"; }\ncheck\n',
                               recipe, root, env=dict(os.environ, TEST_STATUS=str(test_status),
                               GALLIUM=gallium, OTHER=other, READER_STATUS=str(reader_status)))
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn('test -C build --print-errorlogs', result.stdout)



class M1n1RecipeTests(unittest.TestCase):
    def test_stage_roles_artwork_and_installer_compatibility(self):
        recipe = ROOT / 'pkgbuilds/m1n1-aurora/PKGBUILD'
        record = json.loads(recipe.with_name('build-qualification.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'm1n1'
            (source / 'data').mkdir(parents=True)
            (source / '3rdparty_licenses').mkdir()
            (source / 'LICENSE').write_text('fixture notice')
            (source / '3rdparty_licenses/fixture').write_text('fixture notice')
            for size in (48, 128, 256):
                (root / f'bootlogo_{size}.bin').write_bytes(recipe.with_name(f'bootlogo_{size}.bin').read_bytes())
            for name in ('build-qualification.json', 'validate-qualification.py'):
                (root / name).write_bytes(recipe.with_name(name).read_bytes())
            result = shell(r'''set -euo pipefail
source "$1"
srcdir="$2"
pkgdir="$2/package"
git() { [[ "$*" == "-C $srcdir/m1n1 rev-parse HEAD" ]] || return 91; printf '%s\n' "$TEST_PIN"; }
rustup() { [[ "$*" == 'toolchain install 1.89.0 --profile minimal --target aarch64-unknown-none-softfloat' ]] || return 92; }
make() {
  [[ "$PWD" == "$srcdir/m1n1" ]] || return 93
  if [[ "$*" == clean ]]; then rm -rf build; return; fi
  [[ " $* " == *' RELEASE=1 '* && " $* " == *' CHAINLOADING=1 '* && " $* " == *' USE_CLANG=1 '* && " $* " == *' EXTRA_CFLAGS=-Os '* ]] || return 94
  [[ "$RUSTUP_TOOLCHAIN" == '1.89.0' ]] || return 95
  for size in 48 128 256; do cmp "$srcdir/bootlogo_$size.bin" "data/bootlogo_$size.bin"; done
  mkdir build
  local role=stage1
  [[ " $* " != *' ESP_STAGE2=1 '* ]] || role=stage2
  printf '%s-raw' "$role" > build/m1n1.bin
  printf '%s-macho' "$role" > build/m1n1.macho
}
prepare
build
package
''', recipe, root, env=dict(os.environ, TEST_PIN=record['source_commit']))
            self.assertEqual(result.returncode, 0, result.stderr)
            package = root / 'package'
            expected = {
                'usr/lib/asahi-boot/m1n1.bin': 'stage2-raw',
                'usr/share/m1n1-aurora/stage1/m1n1-raw.bin': 'stage1-raw',
                'usr/share/m1n1-aurora/stage1/m1n1.macho': 'stage1-macho',
                'usr/share/aura/stage1/aura-raw.bin': 'stage1-raw',
                'usr/share/aura/stage1/aura.macho': 'stage1-macho',
            }
            for name, value in expected.items():
                self.assertEqual((package / name).read_text(), value)
                self.assertFalse((package / name).is_symlink())
            self.assertEqual((package / 'usr/lib/m1n1-neo/m1n1.bin').resolve(), package / 'usr/lib/asahi-boot/m1n1.bin')
            self.assertFalse((package / 'boot').exists())
            self.assertFalse((package / 'usr/share/libalpm/hooks').exists())
            self.assertIs(json.loads((package / 'usr/share/doc/m1n1-aurora/build-qualification.json').read_text())['hardware_tested'], False)

    def test_prepare_refuses_a_different_source_pin(self):
        recipe = ROOT / 'pkgbuilds/m1n1-aurora/PKGBUILD'
        pin = json.loads(recipe.with_name('build-qualification.json').read_text())['source_commit']
        for actual in (pin, '0' * 40):
            with self.subTest(pin_matches=actual == pin), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                data = root / 'm1n1/data'
                data.mkdir(parents=True)
                for size in (48, 128, 256):
                    (root / f'bootlogo_{size}.bin').write_bytes(b'new-logo')
                    (data / f'bootlogo_{size}.bin').write_bytes(b'original-logo')
                result = shell(r'''set -e
source "$1"
srcdir="$2"
git() { printf '%s\n' "$ACTUAL_PIN"; }
rustup() { printf 'toolchain touched' > "$srcdir/toolchain"; }
prepare
''', recipe, root, env=dict(os.environ, ACTUAL_PIN=actual))
                if actual == pin:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue((root / 'toolchain').is_file())
                else:
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertFalse((root / 'toolchain').exists())
                for size in (48, 128, 256):
                    self.assertEqual((data / f'bootlogo_{size}.bin').read_bytes(),
                                     b'new-logo' if actual == pin else b'original-logo')

    def test_canonical_candidate_cannot_claim_hardware_qualification(self):
        path = ROOT / 'pkgbuilds/m1n1-aurora/validate-qualification.py'
        spec = importlib.util.spec_from_file_location('m1n1_qualification', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        record = json.loads(path.with_name('build-qualification.json').read_text())
        module.validate(record, record['source_commit'], require_hardware=False)
        with self.assertRaisesRegex(ValueError, 'not hardware-qualified'):
            module.validate(record, record['source_commit'])


    def test_promotion_requires_each_legacy_boot_pair(self):
        path = ROOT / 'pkgbuilds/m1n1-aurora/validate-qualification.py'
        spec = importlib.util.spec_from_file_location('m1n1_promotion_qualification', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        record = json.loads(path.with_name('build-qualification.json').read_text())
        gates = ['native_build', 'matched_stage1_stage2_boot', 'repair', 'upgrade',
                 'legacy_stage1_omacom_stage2_m1_cold_boot',
                 'legacy_stage1_omacom_stage2_m2_cold_boot',
                 'aura_stage1_omacom_stage2_m1_cold_boot',
                 'aura_stage1_omacom_stage2_m2_cold_boot',
                 'aura_stage1_omacom_stage2_m3_cold_boot',
                 'aura_stage1_omacom_stage2_neo_cold_boot']
        record['hardware_tested'] = True
        record['evidence'] = {gate: {'passed': True, 'report': 'synthetic test fixture only'}
                              for gate in gates}
        module.validate(record, record['source_commit'])
        for gate in gates:
            with self.subTest(missing=gate):
                partial = dict(record, evidence={k: v for k, v in record['evidence'].items() if k != gate})
                with self.assertRaisesRegex(ValueError, gate):
                    module.validate(partial, record['source_commit'])



class QualificationTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / 'pkgbuilds/aura/validate-qualification.py'
        spec = importlib.util.spec_from_file_location('qualification', path)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.record = json.loads(path.with_name('build-qualification.json').read_text())

    def test_current_unqualified_pin_cannot_publish(self):
        with self.assertRaisesRegex(ValueError, 'not hardware-qualified'):
            self.module.validate(self.record, self.record['source_commit'])

    def test_candidate_build_preserves_unqualified_status_and_checks_identity(self):
        self.module.validate(self.record, self.record['source_commit'], require_hardware=False)
        self.assertIs(self.record['hardware_tested'], False)
        for record, commit in [(self.record, '0' * 40),
                               (dict(self.record, stage1_auto_enrollment=True), self.record['source_commit']),
                               (dict(self.record, hardware_tested='false'), self.record['source_commit'])]:
            with self.subTest(record=record, commit=commit), self.assertRaises(ValueError):
                self.module.validate(record, commit, require_hardware=False)

    def test_exact_pin_and_all_evidence_are_required(self):
        record = dict(self.record, hardware_tested=True)
        with self.assertRaises(ValueError):
            self.module.validate(record, record['source_commit'])
        record['evidence'] = {gate: {'passed': True, 'report': 'synthetic fixture only'}
                              for gate in ['native_build', 'matched_stage1_stage2_boot', 'repair', 'upgrade']}
        self.module.validate(record, record['source_commit'])
        with self.assertRaises(ValueError):
            self.module.validate(record, '0' * 40)


class FirmwareTests(unittest.TestCase):
    def test_legacy_initrd_warns_and_keeps_late_admission_without_adding_early_files(self):
        hook = ROOT / 'pkgbuilds/omarchy-aurora-firmware/aurora-vendor-order.install'
        functions = 'add_binary() { echo ADDED; }; add_module() { echo ADDED; }; add_file() { echo ADDED; }; add_symlink() { echo ADDED; }; '
        for hooks, expected in [('base udev', 0), ('base systemd', 0)]:
            result = shell(functions + 'source "$1"; read -ra HOOKS <<<"$2"; build', hook, hooks)
            self.assertEqual(result.returncode, expected, result.stderr)
            if hooks == 'base udev':
                self.assertIn('root vendor-firmware service', result.stderr)
                self.assertNotIn('ADDED', result.stdout)
            else:
                self.assertIn('ADDED', result.stdout)

    def test_hint_in_event_subscription_gap_is_reconciled_and_dead_watcher_fails(self):
        script = ROOT / 'pkgbuilds/omarchy-aurora-firmware/aurora-regdom-fallback'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            iw = root / 'iw'
            (root / 'country').write_text('00')
            iw.write_text('#!/bin/bash\ncase "$*" in\n  event)\n    sleep 0.2\n    # This hint arrives after the initial read, before subscription is ready.\n    echo PL > "$FIXTURE/country"\n    sleep 5.5\n    exit 0 ;;\n  \'reg reload\') exit 0 ;;\n  \'reg get\') printf \'country %s:\\n\' "$(cat "$FIXTURE/country")" ;;\n  \'reg set 00\') echo 00 > "$FIXTURE/country"; echo fallback >> "$FIXTURE/calls" ;;\n  *) exit 99 ;;\nesac\n')
            iw.chmod(0o755)
            code = script.read_text().replace('/usr/bin/set-wireless-regdom', str(root / 'no-host-helper'))
            result = subprocess.run(['bash', '-c', code], text=True, capture_output=True, timeout=9,
                env=dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'], FIXTURE=str(root),
                         AURORA_FIRMWARE_ROOT=str(root / 'firmware')))
            self.assertNotEqual(result.returncode, 0, 'systemd must restart a dead event stream')
            self.assertEqual((root / 'calls').read_text().splitlines(), ['fallback'])
            self.assertEqual((root / 'country').read_text().strip(), '00')

    def test_busy_unrelated_events_cannot_starve_country_readback(self):
        script = ROOT / 'pkgbuilds/omarchy-aurora-firmware/aurora-regdom-fallback'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'country').write_text('00')
            iw = root / 'iw'
            iw.write_text('''#!/bin/bash
case "$*" in
  event)
    sleep 0.2
    echo PL > "$FIXTURE/country"
    until [[ -e $FIXTURE/calls ]]; do
      echo 'unrelated scan event'
      sleep 0.02
    done
    exit 0 ;;
  'reg reload') exit 0 ;;
  'reg get') printf 'country %s:\\n' "$(cat "$FIXTURE/country")" ;;
  'reg set 00') echo 00 > "$FIXTURE/country"; echo fallback >> "$FIXTURE/calls" ;;
  *) exit 99 ;;
esac
''')
            iw.chmod(0o755)
            code = script.read_text().replace('/usr/bin/set-wireless-regdom', str(root / 'no-host-helper'))
            process = subprocess.Popen(['bash', '-c', code], text=True, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, start_new_session=True,
                env=dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'], FIXTURE=str(root),
                         AURORA_FIRMWARE_ROOT=str(root / 'firmware')))
            try:
                stdout, stderr = process.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                import signal
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                self.fail('unrelated events starved the five-second readback deadline')
            self.assertNotEqual(process.returncode, 0, 'systemd must restart the ended event stream')
            self.assertEqual((root / 'calls').read_text().splitlines(), ['fallback'], stdout + stderr)
            self.assertEqual((root / 'country').read_text().strip(), '00')

    def test_external_hints_are_rate_limited_and_world_does_not_loop(self):
        path = ROOT / 'pkgbuilds/omarchy-aurora-firmware/aurora-regdom-fallback'
        # Source only the function/state; no live iw process or regulatory change.
        setup = path.read_text().split('\n# An initramfs')[0]
        code = setup + '''
calls=0; current=PL
sleep() { SECONDS=$((SECONDS+$1)); }
iw() { if [[ $1 == reg && $2 == get ]]; then echo "country $current:"; else calls=$((calls+1)); current=00; fi; }
fall_back
[[ $calls == 1 ]] || exit 10
current=JP; fall_back
[[ $calls == 2 && $SECONDS -ge 60 ]] || exit 11
# A supported hint arriving during the delay must not be overwritten.
mkdir -p "$firmware/mediatek/mt7932/policy"; touch "$firmware/mediatek/mt7932/policy/US.bin"
sleep() { SECONDS=$((SECONDS+$1)); current=US; }
current=PL; fall_back
[[ $calls == 2 && $current == US ]] || exit 12
current=00; fall_back
[[ $calls == 2 ]] || exit 13
'''
        with tempfile.TemporaryDirectory() as temporary:
            result = shell(code, env=dict(os.environ, AURORA_FIRMWARE_ROOT=temporary))
        self.assertEqual(result.returncode, 0, result.stderr)


    def test_a_policy_extracted_into_vendor_firmware_keeps_its_country(self):
        path = ROOT / 'pkgbuilds/omarchy-aurora-firmware/aurora-regdom-fallback'
        # vendorfw puts per-machine files under vendor/, which the kernel's
        # firmware loader searches first; a US policy there must keep US.
        setup = path.read_text().split('\n# An initramfs')[0]
        code = setup + '''
calls=0; current=US
sleep() { SECONDS=$((SECONDS+$1)); }
iw() { if [[ $1 == reg && $2 == get ]]; then echo "country $current:"; else calls=$((calls+1)); current=00; fi; }
mkdir -p "$firmware/vendor/mediatek/mt7932/policy"
touch "$firmware/vendor/mediatek/mt7932/policy/US.bin"
fall_back
[[ $calls == 0 && $current == US ]] || exit 20
current=PL; fall_back
[[ $calls == 1 && $current == 00 ]] || exit 21
'''
        with tempfile.TemporaryDirectory() as temporary:
            result = shell(code, env=dict(os.environ, AURORA_FIRMWARE_ROOT=temporary))
        self.assertEqual(result.returncode, 0, result.stderr)

if __name__ == '__main__':
    unittest.main()
