"""Offline fixtures for the installed saver; never read host sysfs or config."""
import fnmatch
import hashlib
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[1] / 'pkgbuilds/aurora-scripts'


class BatteryChargeLimit(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.attribute = self.root / 'threshold'
        self.config = self.root / 'macsmc-battery.conf'
        self.writes = self.root / 'writes'
        self.config.write_text('CHARGE_CONTROL_END_THRESHOLD=80\n')
        self.attribute.write_text('80\n')
        script = (PACKAGE / 'battery-charge-limit-save').read_text()
        script = script.replace('/sys/class/power_supply/macsmc-battery/charge_control_end_threshold',
                                str(self.attribute))
        script = script.replace('/etc/udev', str(self.root))
        self.script = self.root / 'save'
        self.script.write_text(script)
        # Observe the publication boundary: target is still complete, source
        # is complete and on the same filesystem, then perform the real rename.
        tools = self.root / 'bin'
        tools.mkdir()
        (tools / 'mv').write_text('''#!/bin/sh
set -eu
[ "$1" = -f ]
[ "$(cat "$3")" = CHARGE_CONTROL_END_THRESHOLD=80 ]
[ "$(cat "$2")" = CHARGE_CONTROL_END_THRESHOLD=100 ]
[ "$(dirname "$2")" = "$(dirname "$3")" ]
printf 'write\\n' >> "$WRITES"
exec /bin/mv "$@"
''')
        (tools / 'mv').chmod(0o755)
        self.environment = dict(os.environ, PATH=f'{tools}:' + os.environ['PATH'],
                                WRITES=str(self.writes))

    def run_save(self):
        return subprocess.run(['sh', str(self.script)], env=self.environment,
                              capture_output=True, text=True)

    def snapshot(self):
        status = self.config.stat()
        return self.config.read_bytes(), status.st_ino, status.st_mtime_ns

    def test_unchanged_does_not_write(self):
        before = self.snapshot()
        self.assertEqual(self.run_save().returncode, 0)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.writes.exists())

    def test_changed_value_is_published_atomically(self):
        old_inode = self.config.stat().st_ino
        self.attribute.write_text('100\n')
        self.assertEqual(self.run_save().returncode, 0)
        self.assertEqual(self.config.read_text(), 'CHARGE_CONTROL_END_THRESHOLD=100\n')
        self.assertNotEqual(self.config.stat().st_ino, old_inode)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.writes.read_text(), 'write\n')
        self.assertEqual(list(self.root.glob('.macsmc-battery.conf.*')), [])

    def test_empty_invalid_or_failed_read_does_not_write(self):
        before = self.snapshot()
        for value in ('', '\n', '0\n', '101\n', '999999999999999999999\n',
                      '-1\n', '+75\n', '075\n', '01\n', '0100\n', '00\n',
                      ' 75\n', '75 \n', '\t75\n', '75\t\n', '75\r\n',
                      '75x\n', 'x75\n', '75.0\n', '80 100\n', 'oops\n',
                      '75\n80\n', '\n75\n'):
            with self.subTest(value=value):
                self.attribute.write_text(value)
                self.assertNotEqual(self.run_save().returncode, 0)
                self.assertEqual(self.snapshot(), before)
        self.attribute.unlink()
        self.assertNotEqual(self.run_save().returncode, 0)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.writes.exists())

    def test_rapid_repeated_invocations_write_once(self):
        self.attribute.write_text('100\n')
        for _ in range(20):
            self.assertEqual(self.run_save().returncode, 0)
        self.assertEqual(self.writes.read_text(), 'write\n')

    def test_valid_range_and_missing_config(self):
        # Use the real mv for creation and the reverse transition as well.
        self.environment['PATH'] = os.environ['PATH']
        self.config.unlink()
        self.assertEqual(self.run_save().returncode, 0)
        self.assertEqual(self.config.read_text(), 'CHARGE_CONTROL_END_THRESHOLD=80\n')
        for value in (75, 100, 1, 5, 80, *range(1, 101)):
            self.attribute.write_text(f'{value}\n')
            self.assertEqual(self.run_save().returncode, 0)
            self.assertEqual(self.config.read_text(), f'CHARGE_CONTROL_END_THRESHOLD={value}\n')

    def test_trailing_newlines_and_no_newline(self):
        self.environment['PATH'] = os.environ['PATH']
        for value in ('75', '75\n', '75\n\n'):
            with self.subTest(value=value):
                self.attribute.write_text(value)
                self.assertEqual(self.run_save().returncode, 0)
                self.assertEqual(self.config.read_text(), 'CHARGE_CONTROL_END_THRESHOLD=75\n')

    def test_restore_pattern_covers_saved_range(self):
        patch = (PACKAGE / '0002-macsmc-battery-debounce-persistence.patch').read_text()
        pattern = re.search(r'^\+.*ENV\{CHARGE_CONTROL_END_THRESHOLD\}=="([^"]+)"',
                            patch, re.M).group(1)
        # udev uses shell globs with | separating alternatives.
        def matches(value):
            return any(fnmatch.fnmatchcase(value, part) for part in pattern.split('|'))
        for value in range(1, 101):
            self.assertTrue(matches(str(value)), value)
        for value in ('', '0', '00', '01', '075', '101', '1000', '75x', ' 75', '75 '):
            self.assertFalse(matches(value), value)

    def test_recipe_integrates_helper_and_patch(self):
        recipe = (PACKAGE / 'PKGBUILD').read_text()
        for name in ('battery-charge-limit-save', '0002-macsmc-battery-debounce-persistence.patch'):
            self.assertIn(hashlib.sha256((PACKAGE / name).read_bytes()).hexdigest(), recipe)
        self.assertIn('install -Dm755 "$srcdir/battery-charge-limit-save" "$pkgdir/usr/libexec/aurora/battery-charge-limit-save"', recipe)
        patch = (PACKAGE / '0002-macsmc-battery-debounce-persistence.patch').read_text()
        self.assertIn('+Type=oneshot\n', patch)
        self.assertIn('+ExecStartPre=/usr/bin/sleep 3\n', patch)
        self.assertIn('+ExecStart=/usr/libexec/aurora/battery-charge-limit-save\n', patch)
        self.assertIn('+ACTION=="add", SUBSYSTEM=="power_supply"', patch)
        self.assertNotIn('StartLimit', patch)


if __name__ == '__main__':
    unittest.main()
