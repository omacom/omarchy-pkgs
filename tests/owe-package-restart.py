#!/usr/bin/env python3
"""Package restart fixtures; no real systemd managers are contacted."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "pkgbuilds/owe"


class Restart(unittest.TestCase):
  def setUp(self):
    self.temp = tempfile.TemporaryDirectory(prefix="owe-restart-")
    self.addCleanup(self.temp.cleanup)
    self.root = Path(self.temp.name)
    self.log = self.root / "calls"
    self.env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}", CALLS=str(self.log))
    self.command("systemd-detect-virt", 'exit "${CHROOT:-1}"')
    self.command("systemd-notify", 'exit "${BOOTED:-0}"')
    self.command("systemctl", '''
printf '%s\\n' "$*" >> "$CALLS"
case "$1" in
  list-units)
    printf '%s\\n' "${MANAGERS:-}"
    exit "${LIST_FAILED:-0}"
    ;;
esac
[[ $* != *"--machine=${FAIL_USER:-none}@.host"* ]]
''')

  def command(self, name, body):
    path = self.root / name
    path.write_text("#!/bin/bash\n" + body + "\n")
    path.chmod(0o755)

  def run_hook(self, **values):
    return subprocess.run(["bash", str(PACKAGE / "package-restart")],
                          env=self.env | values, capture_output=True, text=True)

  def calls(self):
    return self.log.read_text().splitlines() if self.log.exists() else []

  def test_offline_and_chroot_skip_managers(self):
    for values in ({"CHROOT": "0"}, {"BOOTED": "1"}):
      with self.subTest(values=values):
        self.assertEqual(self.run_hook(**values).returncode, 0)
        self.assertEqual(self.calls(), [])

  def test_no_running_managers(self):
    self.assertEqual(self.run_hook().returncode, 0)
    self.assertEqual(len(self.calls()), 1)

  def test_all_running_managers_use_conditional_restart(self):
    result = self.run_hook(MANAGERS="user@1000.service loaded active running User Manager\nuser@1001.service loaded active running User Manager")
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(self.calls(), [
      "list-units user@*.service --state=running --no-legend --plain",
      "--user --machine=1000@.host try-restart owed.service",
      "--user --machine=1001@.host try-restart owed.service",
    ])

  def test_failure_reports_user_and_continues(self):
    result = self.run_hook(MANAGERS="user@1000.service loaded active running\nuser@1001.service loaded active running", FAIL_USER="1000")
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("Could not restart OWE for user 1000", result.stderr)
    self.assertIn("--user --machine=1001@.host try-restart owed.service", self.calls())

  def test_list_failure_is_not_silently_successful(self):
    self.assertNotEqual(self.run_hook(LIST_FAILED="1").returncode, 0)
    self.assertEqual(len(self.calls()), 1)

  def test_only_user_manager_units_are_accepted(self):
    self.assertEqual(self.run_hook(MANAGERS="invalid.service loaded active running\nuser@oops.service loaded active running").returncode, 0)
    self.assertEqual(len(self.calls()), 1)

  def test_packaged_hook_and_sources(self):
    hook = (PACKAGE / "90-owe-restart.hook").read_text()
    self.assertIn("Operation = Upgrade\n", hook)
    self.assertNotIn("Operation = Install", hook)
    self.assertNotIn("Operation = Remove", hook)
    self.assertIn("When = PostTransaction\n", hook)
    self.assertIn("Exec = /usr/lib/owe/package-restart\n", hook)
    recipe = (PACKAGE / "PKGBUILD").read_text()
    for source in ("90-owe-restart.hook", "package-restart"):
      self.assertIn(hashlib.sha256((PACKAGE / source).read_bytes()).hexdigest(), recipe)
    self.assertIn('"$pkgdir/usr/share/libalpm/hooks/90-owe-restart.hook"', recipe)
    self.assertIn('"$pkgdir/usr/lib/owe/package-restart"', recipe)


if __name__ == "__main__":
  unittest.main()
