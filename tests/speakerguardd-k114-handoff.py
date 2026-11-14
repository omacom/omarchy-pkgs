#!/usr/bin/env python3
"""Synthetic service-command checks; no real systemd manager or mixer is contacted."""
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "pkgbuilds/speakerguardd-k114"


class Handoff(unittest.TestCase):
  def setUp(self):
    self.temp = tempfile.TemporaryDirectory(prefix="k114-handoff-")
    self.addCleanup(self.temp.cleanup)
    self.root = Path(self.temp.name)
    self.log = self.root / "calls"
    self.systemctl = self.root / "systemctl"
    self.systemctl.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$CALLS"
case "$*" in
  'show -P LoadState speakersafetyd.service')
    printf '%s\\n' "$LOAD_STATE"
    exit "$QUERY_RC" ;;
  'stop speakersafetyd.service') exit "$STOP_RC" ;;
  *) exit 99 ;;
esac
''')
    self.systemctl.chmod(0o755)

  def handoff(self, state="loaded", query_rc="0", stop_rc="0"):
    unit = (PACKAGE / "speakerguardd-k114.service").read_text()
    command, = [line.removeprefix("ExecStartPre=") for line in unit.splitlines()
                if line.startswith("ExecStartPre=") and "systemctl" in line]
    # shortcut: models only this command's prefix/$$ escaping; use a real unit for integration proof.
    ignore_failure = command.startswith("-")
    args = shlex.split(command.removeprefix("-").replace("$$", "$"))
    args = [arg.replace("/usr/bin/systemctl", str(self.systemctl)) for arg in args]
    result = subprocess.run(args, check=False, capture_output=True, text=True,
                            env=os.environ | {"CALLS": str(self.log), "LOAD_STATE": state,
                                              "QUERY_RC": query_rc, "STOP_RC": stop_rc})
    return (0 if ignore_failure else result.returncode), self.log.read_text().splitlines()

  def test_loaded_unit_is_stopped(self):
    rc, calls = self.handoff()
    self.assertEqual(rc, 0)
    self.assertEqual(calls, ["show -P LoadState speakersafetyd.service", "stop speakersafetyd.service"])

  def test_missing_unit_is_the_only_skip(self):
    rc, calls = self.handoff(state="not-found", stop_rc="5")
    self.assertEqual(rc, 0)
    self.assertEqual(calls, ["show -P LoadState speakersafetyd.service"])

  def test_stop_failure_blocks_handoff(self):
    rc, calls = self.handoff(stop_rc="23")
    self.assertEqual(rc, 23)
    self.assertEqual(calls[-1], "stop speakersafetyd.service")

  def test_query_failure_blocks_even_with_not_found_output(self):
    rc, calls = self.handoff(state="not-found", query_rc="7")
    self.assertNotEqual(rc, 0)
    self.assertEqual(calls, ["show -P LoadState speakersafetyd.service"])

  def test_failed_unit_still_requires_successful_stop(self):
    rc, calls = self.handoff(state="error", stop_rc="5")
    self.assertEqual(rc, 5)
    self.assertEqual(calls[-1], "stop speakersafetyd.service")


if __name__ == "__main__":
  unittest.main()
