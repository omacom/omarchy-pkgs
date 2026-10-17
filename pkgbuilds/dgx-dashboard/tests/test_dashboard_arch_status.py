from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from helpers import load_script
m = load_script('arch-package-status')

class DashboardStatus(unittest.TestCase):
    def test_no_update_candidates_do_not_query_repository_metadata(self):
        with patch.object(m, 'run') as command:
            m.metadata([], [], Path('/unused'))
        command.assert_not_called()

    def test_repository_metadata_matches_candidates(self):
        rows = m.parse_updates(subprocess.CompletedProcess([], 0, 'example 1:2.0-1 -> 1:2.1-2\n', ''))
        output = 'example 1:2.1-2 extra aarch64 4096 An example with spaces\n'
        with patch.object(m, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')):
            m.metadata(rows, [], Path('/unused'))
        self.assertEqual((rows[0]['repository'], rows[0]['size'], rows[0]['description']),
                         ('extra', 4096, 'An example with spaces'))
        for output in ('', 'example 1:2.0-1 extra aarch64 4096 Stale\n', 'example 1:2.1-2 extra aarch64 unknown\n'):
            with patch.object(m, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                with self.assertRaises(RuntimeError):
                    m.metadata([dict(r) for r in rows], [], Path('/unused'))

    def test_empty_query_and_failure_are_distinct(self):
        self.assertEqual(m.parse_updates(subprocess.CompletedProcess([], 1, '', '')), [])
        with self.assertRaises(RuntimeError):
            m.parse_updates(subprocess.CompletedProcess([], 1, '', 'database unavailable'))

    def test_versions_and_ignored_packages_preserved(self):
        rows = m.parse_updates(subprocess.CompletedProcess([], 0, 'example 1:2.0-1 -> 1:2.1-2\nheld 1-1 -> 2-1 [ignored]\n', ''))
        self.assertEqual(rows[0]['availableVersion'], '1:2.1-2')
        self.assertTrue(rows[1]['ignored'])
        with self.assertRaises(RuntimeError):
            m.parse_updates(subprocess.CompletedProcess([], 0, 'unexpected format', ''))

    def test_mutations_and_extra_options_never_invoke_backend(self):
        with patch.object(m, 'snapshot') as backend:
            for program, args in [('apt', ['install', 'bash']), ('apt', ['dist-upgrade']),
                                  ('apt', ['update', '--anything']), ('apt-cache', ['show', '--help']),
                                  ('dgx-arch-package-status', ['--install'])]:
                with self.assertRaises(RuntimeError):
                    m.dispatch(program, args)
            backend.assert_not_called()

    def test_failed_refresh_invalidates_successful_cache(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(m, 'CACHE', Path(directory)):
            cache = Path(directory) / 'status.json'
            cache.write_text('{"checkedAt": 1, "updates": []}')
            with patch.object(m, 'refresh', side_effect=RuntimeError('network failure')):
                with self.assertRaises(RuntimeError):
                    m.snapshot(force=True)
            self.assertFalse(cache.exists())

    def test_refresh_reuses_recent_snapshot(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(m, 'CACHE', Path(directory)):
            with patch.object(m, 'refresh', return_value={'checkedAt': m.time.time(), 'updates': []}) as refresh:
                m.snapshot(force=True)
                m.snapshot()
                self.assertEqual(refresh.call_count, 1)

if __name__ == '__main__':
    unittest.main()
