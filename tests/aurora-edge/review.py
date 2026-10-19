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
        self.assertIn('cp ../config build/base/.config', recipe)
        self.assertIn("grep -qx 'CONFIG_RUST=y'", recipe)
        self.assertNotIn('j700.config', recipe)
        self.assertNotIn('j700-device-parity.config', recipe)
        original = (package / 'config').read_text()
        fragment = (package / 'neo.config').read_text()
        for setting in ['CONFIG_USB4=m', 'CONFIG_DEBUG_INFO_BTF=y', 'CONFIG_KEXEC_FILE=y',
                        'CONFIG_RELR=y', 'CONFIG_RUST=y']:
            self.assertIn(setting, original)
        for line in fragment.splitlines():
            if line.startswith('CONFIG_'):
                name = line.split('=', 1)[0]
                self.assertNotIn('\n' + name + '=', original, 'Neo fragment overrides shared setting')
                self.assertNotIn('# ' + name + ' is not set', original, 'Neo fragment flips shared disabled setting')
        self.assertIn('CONFIG_MT7932_FULLMAC=m', fragment)

    def test_generated_release_keeps_boot_bundle_suffix(self):
        recipe = ROOT / 'pkgbuilds/linux-aurora/PKGBUILD'
        for release, expected in [('7.1.12-6-2-ARCH', 0), ('7.1.12-6-2-aurora', 1),
                                  ('7.1.12-6-2-ARCH-extra', 1), ('', 1)]:
            with self.subTest(release=release):
                result = shell('source "$1"; _check_kernelrelease "$2"', recipe, release)
                self.assertEqual(result.returncode, expected, result.stderr)
        self.assertIn('_check_kernelrelease "$(<build/base/version)"', recipe.read_text())

    def test_shared_capabilities_are_explicit_and_separate_from_neo_drivers(self):
        package = ROOT / 'pkgbuilds/linux-aurora'
        common = (package / 'common.config').read_text()
        expected = {'CONFIG_SERIAL_APPLE_DOCKCHANNEL', 'CONFIG_SERIAL_APPLE_DOCKCHANNEL_EARLYCON',
                    'CONFIG_SYSFB_SIMPLEFB', 'CONFIG_DMABUF_HEAPS', 'CONFIG_DMABUF_HEAPS_SYSTEM',
                    'CONFIG_UDMABUF', 'CONFIG_THERMAL_NETLINK', 'CONFIG_NVME_HWMON', 'CONFIG_TRUSTED_KEYS',
                    'CONFIG_APPLE_SEP', 'CONFIG_HID_APPLE_MTP_HAPTIC', 'CONFIG_SENSORS_APPLE_PMP_J613',
                    'CONFIG_SND_SOC_MAX98357A'}
        self.assertEqual({line.split('=', 1)[0] for line in common.splitlines()
                          if line.startswith('CONFIG_')}, expected)
        recipe = (package / 'PKGBUILD').read_text()
        self.assertIn('../common.config ../neo.config', recipe)
        self.assertIn('python3 ../validate-config.py ../common.config build/base/.config', recipe)

    def test_trusted_keys_cannot_downgrade_the_builtin_sep_driver(self):
        package = ROOT / 'pkgbuilds/linux-aurora'
        spec = importlib.util.spec_from_file_location('sep_config_check', package / 'validate-config.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        fragment = package / 'common.config'
        requested = module.values(fragment)
        self.assertEqual(requested['CONFIG_TRUSTED_KEYS'], 'y')
        self.assertEqual(requested['CONFIG_APPLE_SEP'], 'y')
        with tempfile.TemporaryDirectory() as temporary:
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
            fragment = validator.with_name('neo.config')
            resolved.write_text(fragment.read_text())
            module.validate(fragment, resolved)
            resolved.write_text(fragment.read_text().replace(
                'CONFIG_SND_SOC_APPLE_T8140_AOP_AUDIO=m', '# CONFIG_SND_SOC_APPLE_T8140_AOP_AUDIO is not set'))
            with self.assertRaisesRegex(ValueError, 'CONFIG_SND_SOC_APPLE_T8140_AOP_AUDIO'):
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
        recipe = ROOT / 'pkgbuilds/mesa-aurora/PKGBUILD'
        for test_status, runtime, reader_status, expected in [
            (0, '', 0, 0), (1, '', 0, 1), (0, 'libLLVM.so.23', 0, 1),
            (0, 'libSPIRV-Tools.so', 0, 1), (0, '', 1, 1)]:
            with self.subTest(tests=test_status, runtime=runtime, reader=reader_status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                stage = root / 'mesa-stage'
                stage.mkdir()
                (stage / 'driver.so').write_bytes(b'fixture')
                result = shell('source "$1"\nsrcdir="$2"\nmeson() { printf \'%s\\n\' "$*"; return "$TEST_STATUS"; }\nreadelf() { [[ -z $RUNTIME ]] || echo "NEEDED $RUNTIME"; return "$READER_STATUS"; }\ncheck\n', recipe, root, env=dict(os.environ, TEST_STATUS=str(test_status),
                          RUNTIME=runtime, READER_STATUS=str(reader_status)))
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn('test -C build --print-errorlogs', result.stdout)


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
                         AURORA_REGDOM_POLICY_DIR=str(root / 'policy')))
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
                         AURORA_REGDOM_POLICY_DIR=str(root / 'policy')))
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
touch "$policy/US.bin"
sleep() { SECONDS=$((SECONDS+$1)); current=US; }
current=PL; fall_back
[[ $calls == 2 && $current == US ]] || exit 12
current=00; fall_back
[[ $calls == 2 ]] || exit 13
'''
        with tempfile.TemporaryDirectory() as temporary:
            result = shell(code, env=dict(os.environ, AURORA_REGDOM_POLICY_DIR=temporary))
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
