"""Exercise the launcher's real Qt-scale selection without launching VibeCAD."""

import os
from pathlib import Path
import subprocess
import unittest

LAUNCHER = Path(__file__).resolve().parents[1] / 'vibecad'
MARKER = "# VibeCAD's AppImage bundles"


class Scaling(unittest.TestCase):
    def test_scale_selection(self):
        launcher = LAUNCHER.read_text()
        self.assertIn(MARKER, launcher, 'Update the fixture when launcher structure changes')
        selection = launcher.split(MARKER, 1)[0]
        selection += '\nprintf "%s" "${QT_SCALE_FACTOR-unset}"\n'
        base = {key: value for key, value in os.environ.items()
                if not key.startswith('QT_')}
        base['HYPRLAND_INSTANCE_SIGNATURE'] = 'test-session'
        cases = (
            ('Retina', '[{"scale":1},{"focused":true,"scale":2}]', '2', {}, True, True),
            ('fractional', '[{"focused":true,"scale":1.5}]', '1.5', {}, True, True),
            ('enabled fallback', '[{"disabled":true,"scale":3},{"scale":2}]', '2', {}, True, True),
            ('explicit scale', '[{"scale":2}]', '1.25', {'QT_SCALE_FACTOR': '1.25'}, True, True),
            ('per-screen override', '[{"scale":2}]', 'unset', {'QT_SCREEN_SCALE_FACTORS': '1.5'}, True, True),
            ('malformed', 'invalid', 'unset', {}, True, True),
            ('empty', '[]', 'unset', {}, True, True),
            ('invalid scale', '[{"scale":-2}]', 'unset', {}, True, True),
            ('unreachable', '', 'unset', {}, False, True),
            ('outside Hyprland', '[{"scale":2}]', 'unset', {}, True, False),
        )
        for name, monitors, expected, overrides, reachable, session in cases:
            with self.subTest(name=name):
                env = dict(base, TEST_MONITORS=monitors, **overrides)
                if not session:
                    env.pop('HYPRLAND_INSTANCE_SIGNATURE', None)
                stub = ('hyprctl() { printf "%s" "$TEST_MONITORS"; }\n'
                        if reachable else 'hyprctl() { return 1; }\n')
                stub += 'timeout() { shift; "$@"; }\n'
                result = subprocess.run(['bash', '-c', stub + selection], env=env,
                                        text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)


if __name__ == '__main__':
    unittest.main()
