import importlib.machinery
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / 'arch-package-status'
loader = importlib.machinery.SourceFileLoader('dashboard_arch', str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

class DashboardStatus(unittest.TestCase):
    def test_no_update_candidates_do_not_scan_repository_metadata(self):
        with patch.object(m, 'run') as command, patch.object(m.tarfile, 'open') as archive:
            m.metadata(Path('/unused'), [])
        command.assert_not_called()
        archive.assert_not_called()

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
