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
    def probe(self, *, root=False, model='apple,j700', missing=None, fail_wifi=False):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            compatible = work / 'compatible'
            compatible.write_bytes(model.encode() + b'\0')
            for name in INPUTS + OPTIONAL:
                if name != missing:
                    target = work / 'firmware/vendor' / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b'admission fixture only')
            probe = work / 'modprobe'
            probe.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$AURORA_TEST_CALLS"\n'
                             '[ "${AURORA_FAIL_WIFI:-0}:$1" != 1:mt7932-fullmac ]\n')
            probe.chmod(0o755)
            calls = work / 'calls'
            env = dict(os.environ, AURORA_FIRMWARE_ROOT=str(work / 'firmware'),
                       AURORA_DT_COMPATIBLE=str(compatible), AURORA_MODPROBE=str(probe),
                       AURORA_TEST_CALLS=str(calls), AURORA_FAIL_WIFI=str(int(fail_wifi)))
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
        self.assertEqual(self.probe(), (0, ['aop', 'mt7932-fullmac']))

    def test_existing_root_unit_admits_wifi_then_bluetooth(self):
        self.assertEqual(self.probe(root=True), (0, ['aop', 'mt7932-fullmac', 'mt7932_bt_pcie']))

    def test_missing_radio_inputs_cannot_admit_either_radio(self):
        for name in INPUTS[1:]:
            with self.subTest(missing=name):
                self.assertEqual(self.probe(root=True, missing=name), (0, ['aop']))

    def test_missing_country_policy_still_admits_both_radios(self):
        for name in OPTIONAL:
            with self.subTest(missing=name):
                self.assertEqual(self.probe(root=True, missing=name),
                                 (0, ['aop', 'mt7932-fullmac', 'mt7932_bt_pcie']))

    def test_failed_wifi_load_cannot_admit_bluetooth(self):
        self.assertEqual(self.probe(root=True, fail_wifi=True), (1, ['aop', 'mt7932-fullmac']))

    def test_other_macs_keep_their_existing_admission(self):
        self.assertEqual(self.probe(root=True, model='apple,j414s'), (0, ['aop']))


if __name__ == '__main__':
    unittest.main()
