import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


VERIFIER = Path(__file__).with_name("verify-critical-action.py")


class CriticalActionVerifierTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.bin_dir = Path(self.tmp.name)
        busctl = self.bin_dir / "busctl"
        busctl.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "if os.environ.get('BUSCTL_FAIL'):\n"
            "    print('D-Bus unavailable', file=sys.stderr)\n"
            "    sys.exit(1)\n"
            "print(os.environ.get('BUSCTL_RESULT', ''), end='')\n"
        )
        busctl.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_verifier(self, **extra_env):
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}:{env['PATH']}"
        env.update(extra_env)
        return subprocess.run(
            [sys.executable, str(VERIFIER)],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def test_accepts_poweroff_reported_by_upower(self):
        result = self.run_verifier(BUSCTL_RESULT='s "PowerOff"')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_sleep_reported_by_upower(self):
        result = self.run_verifier(BUSCTL_RESULT='s "Sleep"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PowerOff", result.stderr)

    def test_rejects_dbus_failure(self):
        result = self.run_verifier(BUSCTL_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("D-Bus", result.stderr)


if __name__ == "__main__":
    unittest.main()
