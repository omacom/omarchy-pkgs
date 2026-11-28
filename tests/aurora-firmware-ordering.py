#!/usr/bin/env python3
"""Check radio admission through the actual firmware helper and unit opt-in."""
import configparser
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[1] / 'pkgbuilds/omarchy-aurora-firmware'
INPUTS = (
    'apple/j700-aop-als-cal.bin',
    'mediatek/mt7932/IZUBA_WIFI_MT7932_patch_mcu_1_2_hdr.bin',
    'mediatek/mt7932/IZUBA_W7932_2.bin',
    'mediatek/mt7932/ppr.bin', 'mediatek/mt7932/oca2.bin',
    'mediatek/mt7932/wcal.bin', 'mediatek/mt7932/config-original.bin',
    'mediatek/MT7932B0_OS_TypeB_0.1.44.0_241001003711.bin',
    'mediatek/MT7932B1_OS_TypeB_0.1.133.0_260128190103.bin',
    'mediatek/MT7932_PTB_IzubaA_0.1.0.0_20251021141303.ptx',
    'mediatek/j700-mt7932-btcal.bin', 'mediatek/j700-mt7932-bdaddr.bin',
    'mediatek/mt7932/policy/world-XZ.bin',
)
# Country policies are optional: the driver falls back to world-XZ without them.
OPTIONAL = ('mediatek/mt7932/policy/US.bin',)


class AdmissionTests(unittest.TestCase):
    def probe(self, *, root=False, model='apple,j700', missing=None,
              fail_wifi=False, fail_aop=False, handshake=False):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            compatible = work / 'compatible'
            compatible.write_bytes(model.encode() + b'\0')
            for name in INPUTS + OPTIONAL:
                if name != missing:
                    target = work / 'firmware/vendor' / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b'admission fixture only')
            barrier = work / 'barrier'
            barrier.mkdir()
            probe = work / 'modprobe'
            probe.write_text(
                '#!/bin/sh\n'
                'if [ "${AURORA_HANDSHAKE:-0}" = 1 ]; then\n'
                '  case "$1" in\n'
                '    aop) self=aop; peer=mt7932-fullmac ;;\n'
                '    mt7932-fullmac) self=mt7932-fullmac; peer=aop ;;\n'
                '    *) self=; peer= ;;\n'
                '  esac\n'
                '  if [ -n "$self" ]; then\n'
                '    : > "$AURORA_BARRIER/$self"\n'
                '    i=0\n'
                '    while [ ! -e "$AURORA_BARRIER/$peer" ]; do\n'
                '      i=$((i + 1))\n'
                '      [ "$i" -lt 200 ] || exit 2\n'
                '      sleep 0.01\n'
                '    done\n'
                '  fi\n'
                'fi\n'
                'printf "%s\\n" "$1" >> "$AURORA_TEST_CALLS"\n'
                '[ "${AURORA_FAIL_WIFI:-0}:$1" != 1:mt7932-fullmac ] && '
                '[ "${AURORA_FAIL_AOP:-0}:$1" != 1:aop ]\n'
            )
            probe.chmod(0o755)
            calls = work / 'calls'
            env = dict(os.environ, AURORA_FIRMWARE_ROOT=str(work / 'firmware'),
                       AURORA_DT_COMPATIBLE=str(compatible), AURORA_MODPROBE=str(probe),
                       AURORA_TEST_CALLS=str(calls), AURORA_FAIL_WIFI=str(int(fail_wifi)),
                       AURORA_FAIL_AOP=str(int(fail_aop)),
                       AURORA_HANDSHAKE=str(int(handshake)),
                       AURORA_BARRIER=str(barrier))
            env.pop('AURORA_ADMIT_BLUETOOTH', None)
            unit = configparser.ConfigParser()
            unit.read(PACKAGE / ('20-aurora-vendor-order.conf' if root
                                 else 'aurora-peripheral-firmware.service'))
            env.update(item.split('=', 1) for item in
                       shlex.split(unit['Service'].get('Environment', '')))
            result = subprocess.run(['bash', str(PACKAGE / 'aurora-peripheral-firmware.sh')],
                                    env=env, capture_output=True, text=True)
            return result.returncode, calls.read_text().splitlines() if calls.exists() else []

    def test_initrd_never_admits_bluetooth(self):
        rc, calls = self.probe()
        self.assertEqual(rc, 0)
        self.assertCountEqual(calls, ['aop', 'mt7932-fullmac'])

    def test_existing_root_unit_admits_wifi_then_bluetooth(self):
        rc, calls = self.probe(root=True)
        self.assertEqual(rc, 0)
        self.assertCountEqual(calls, ['aop', 'mt7932-fullmac', 'mt7932_bt_pcie'])
        self.assertLess(calls.index('mt7932-fullmac'), calls.index('mt7932_bt_pcie'))

    def test_missing_radio_inputs_cannot_admit_either_radio(self):
        for name in INPUTS[1:]:
            with self.subTest(missing=name):
                self.assertEqual(self.probe(root=True, missing=name), (0, ['aop']))

    def test_missing_country_policy_still_admits_both_radios(self):
        for name in OPTIONAL:
            with self.subTest(missing=name):
                rc, calls = self.probe(root=True, missing=name)
                self.assertEqual(rc, 0)
                self.assertCountEqual(calls, ['aop', 'mt7932-fullmac', 'mt7932_bt_pcie'])
                self.assertLess(calls.index('mt7932-fullmac'), calls.index('mt7932_bt_pcie'))

    def test_failed_wifi_load_cannot_admit_bluetooth(self):
        rc, calls = self.probe(root=True, fail_wifi=True)
        self.assertEqual(rc, 1)
        self.assertCountEqual(calls, ['aop', 'mt7932-fullmac'])

    def test_failed_aop_load_propagates_failure(self):
        rc, calls = self.probe(root=True, fail_aop=True)
        self.assertEqual(rc, 1)
        self.assertCountEqual(calls, ['aop', 'mt7932-fullmac', 'mt7932_bt_pcie'])

    def test_neo_probes_aop_in_parallel_with_radios(self):
        rc, calls = self.probe(root=False, handshake=True)
        self.assertEqual(rc, 0)
        self.assertCountEqual(calls, ['aop', 'mt7932-fullmac'])

    def test_other_macs_keep_their_existing_admission(self):
        self.assertEqual(self.probe(root=True, model='apple,j414s'), (0, ['aop']))

    def test_root_dropin_does_not_block_display_manager(self):
        unit = configparser.ConfigParser()
        unit.read(PACKAGE / '20-aurora-vendor-order.conf')
        before = set(unit['Unit'].get('Before', '').split())
        self.assertIn('NetworkManager.service', before)
        self.assertIn('iwd.service', before)
        self.assertIn('bluetooth.service', before)
        self.assertNotIn('display-manager.service', before)


if __name__ == '__main__':
    unittest.main()
