import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "pkgbuilds/omarchy-aurora-firmware/aurora-peripheral-firmware.sh"


class FirmwareOrderingTests(unittest.TestCase):
    def run_probe(self, model, files=()):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            compatible = root / "compatible"
            compatible.write_bytes(model.encode() + b"\0")
            calls = root / "calls"
            probe = root / "modprobe"
            probe.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$AURORA_TEST_CALLS"\n')
            probe.chmod(0o755)
            for name in files:
                target = root / "firmware/vendor" / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b"fixture")
            environment = dict(os.environ, AURORA_DT_COMPATIBLE=str(compatible),
                               AURORA_FIRMWARE_ROOT=str(root / "firmware"),
                               AURORA_MODPROBE=str(probe), AURORA_TEST_CALLS=str(calls))
            result = subprocess.run(["bash", str(SCRIPT)], env=environment, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            return calls.read_text().splitlines() if calls.exists() else []

    def test_non_neo_keeps_aop_when_extraction_failed(self):
        self.assertEqual(self.run_probe("apple,j414s"), ["aop"])

    def test_missing_neo_inputs_defer_only_their_driver(self):
        self.assertEqual(self.run_probe("apple,j700"), [])
        self.assertEqual(self.run_probe("apple,j700", ["apple/j700-aop-als-cal.bin"]), ["aop"])

    def test_extraction_failure_cannot_skip_non_neo_admission_service(self):
        service = (SCRIPT.parent / "aurora-peripheral-firmware.service").read_text()
        self.assertIn("After=omarchy-vendorfw-initrd.service", service)
        self.assertNotIn("Requires=", service)
        self.assertNotIn("ConditionPathExists=", service)


if __name__ == "__main__":
    unittest.main()
