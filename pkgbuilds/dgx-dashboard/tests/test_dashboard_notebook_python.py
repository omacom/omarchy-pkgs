"""Only first-time Dashboard notebook creation should use managed Python."""
from pathlib import Path
import tempfile
import unittest
from helpers import load_script
m = load_script('notebook-python')


class NotebookPython(unittest.TestCase):
    def test_selects_pinned_python_for_new_dashboard_environment(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            target = home / 'jupyterlab/.venv'
            argv = m.command(['-m', 'venv', str(target)], home, 1000)
            self.assertEqual(argv[0], '/usr/bin/uv')
            self.assertEqual(argv[argv.index('--python') + 1], '3.12.14')
            self.assertIn('--seed', argv)
            self.assertEqual(argv[-1], str(target))
            self.assertFalse(target.exists())

    def test_preserves_existing_environment_and_refuses_root(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp); target = home / 'jupyterlab/.venv'
            target.mkdir(parents=True); marker=target/'keep';marker.write_text('notebook environment')
            with self.assertRaises(ValueError):m.command(['-m','venv',str(target)],home,1000)
            self.assertEqual(marker.read_text(),'notebook environment')
            marker.unlink();target.rmdir();target.symlink_to(home/'missing')
            with self.assertRaises(ValueError):m.command(['-m','venv',str(target)],home,1000)
            target.unlink()
            with self.assertRaises(ValueError):m.command(['-m','venv',str(target)],home,0)

    def test_other_python_operations_are_delegated_unchanged(self):
        for args in (['--version'], ['-m','venv','/tmp/unrelated'], ['-c','print(1)']):
            self.assertEqual(m.command(args,Path('/home/test'),1000),['/usr/bin/python3',*args])
