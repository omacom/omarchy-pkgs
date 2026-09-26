"""Setup must validate everything before it changes ~/.nvwb, and needs only its own unit."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import yaml
from helpers import load_script


class SetupOrdering(unittest.TestCase):
    def setUp(self):
        self.module = load_script('nvwb-spark-setup')
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / 'tester'
        self.base = self.home / '.nvwb'
        self.base.mkdir(parents=True, mode=0o700)
        self.calls = []
        self.contexts = []
        self.patches = [
            patch.object(self.module, 'HOME_ROOT', Path(self.temp.name)),
            patch.object(self.module.Path, 'home', return_value=self.home),
            patch.object(self.module.getpass, 'getuser', return_value='tester'),
            patch.object(self.module.os, 'geteuid', return_value=1000),
            patch.object(self.module.subprocess, 'check_output', side_effect=self.fake_check_output),
            patch.object(self.module.subprocess, 'run', side_effect=self.fake_run),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in self.patches:
            item.stop()
        self.temp.cleanup()

    def snapshot(self):
        return {str(p.relative_to(self.home)): (os.readlink(p) if p.is_symlink() else p.read_bytes())
                for p in self.home.rglob('*') if p.is_symlink() or p.is_file()}

    def fake_check_output(self, argv, **kwargs):
        self.calls.append(argv)
        self.assertEqual(argv, ['/usr/bin/id', '-nG', 'tester'])
        return 'tester docker\n'

    def fake_run(self, argv, **kwargs):
        self.calls.append(argv)
        if argv[1:4] == ['list', 'contexts', '-o']:
            self.assertEqual(argv[0], self.module.CLI, 'contexts must be listed through the packaged CLI')
            self.assertEqual(self.snapshot(), self.before, 'nothing may change before the context check')
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps({'result': self.contexts}), stderr='')
        return subprocess.CompletedProcess(argv, 0, stdout='', stderr='')

    def test_invalid_nested_configuration_and_link_directory_do_not_write(self):
        for text in ('[]\n', 'container: []\n', 'service: null\n'):
            (self.base / 'config.yaml').write_text(text)
            self.before = self.snapshot()
            with self.assertRaises(SystemExit):
                self.module.main([])
            self.assertEqual(self.snapshot(), self.before)
            self.assertEqual(self.calls, [])
        (self.base / 'config.yaml').write_text('{}\n')
        (self.base / 'bin' / 'nvwb-cli').mkdir(parents=True)
        self.before = self.snapshot()
        with self.assertRaises(SystemExit):
            self.module.main([])
        self.assertFalse((self.base / 'spark-backups').exists())

    def test_vendor_failure_has_backups_of_contexts_and_shell_before_mutation(self):
        (self.base / 'contexts.json').write_text('{"original": true}\n')
        (self.home / '.bashrc').write_text('# original shell\n')
        self.before = self.snapshot()
        original = self.fake_run
        def failing(argv, **kwargs):
            if 'create' in argv:
                (self.base / 'contexts.json').write_text('{"partial": true}\n')
                raise subprocess.CalledProcessError(9, argv)
            return original(argv, **kwargs)
        with patch.object(self.module.subprocess, 'run', side_effect=failing):
            with self.assertRaises(subprocess.CalledProcessError):
                self.module.main([])
        backup = next((self.base / 'spark-backups').iterdir())
        self.assertEqual((backup / 'contexts.json').read_text(), '{"original": true}\n')
        self.assertEqual((backup / '.bashrc').read_text(), '# original shell\n')
        self.assertFalse(any(argv[0] == '/usr/bin/sudo' for argv in self.calls))

    def test_conflicting_context_leaves_state_untouched(self):
        (self.base / 'config.yaml').write_text('container:\n  runtime: docker\nextra: keep\n')
        (self.base / 'bin').mkdir()
        (self.base / 'bin/nvwb-cli').write_bytes(b'vendor binary')
        self.contexts = [{'name': 'local', 'hostname': 'localhost', 'workbenchDir': '/srv/other-workbench'}]
        self.before = self.snapshot()
        with self.assertRaises(SystemExit) as raised:
            self.module.main([])
        self.assertIn('points elsewhere', str(raised.exception))
        self.assertEqual(self.snapshot(), self.before)
        self.assertFalse((self.base / 'spark-backups').exists())
        self.assertFalse(any('sudo' in argv[0] for argv in self.calls))

    def test_non_docker_runtime_is_refused_before_any_command(self):
        (self.base / 'config.yaml').write_text('container:\n  runtime: podman\n')
        self.before = self.snapshot()
        with self.assertRaises(SystemExit):
            self.module.main([])
        self.assertEqual(self.calls, [])
        self.assertEqual(self.snapshot(), self.before)

    def test_clean_setup_backs_up_and_manages_only_its_unit(self):
        (self.base / 'config.yaml').write_text('extra: keep\n')
        (self.base / 'bin').mkdir()
        (self.base / 'bin/nvwb-cli').write_bytes(b'vendor binary')
        (self.base / 'bin/wb-svc.spark-new').symlink_to('/stale')
        (self.home / '.bashrc').write_text('# shell\n')
        self.before = self.snapshot()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.module.main([]), 0)
        self.assertFalse((self.base / 'bin/wb-svc.spark-new').is_symlink())
        self.assertEqual(json.loads((self.base / 'inventory.json').read_text()), [])
        config = yaml.safe_load((self.base / 'config.yaml').read_text())
        self.assertEqual(config['extra'], 'keep')
        self.assertEqual(config['container'], {'runtime': 'docker', 'buildtime': 'docker'})
        self.assertEqual(config['service']['working_dir'], str(self.base))
        self.assertEqual((self.base / 'config.yaml').stat().st_mode & 0o777, 0o600)
        for name, target in self.module.LINKS.items():
            self.assertEqual(os.readlink(self.base / 'bin' / name), target)
        backups = list((self.base / 'spark-backups').iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'config.yaml').read_text(), 'extra: keep\n')
        self.assertEqual((backups[0] / 'nvwb-cli').read_bytes(), b'vendor binary')
        self.assertEqual((backups[0] / '.bashrc').read_text(), '# shell\n')
        cli = str(self.base / 'bin/nvwb-cli')
        self.assertIn([cli, 'create', 'context', 'local', 'localhost', '--context-workbench-dir', str(self.base),
                       '--description', 'Native Arch ARM'], self.calls)
        self.assertIn([cli, 'internal', 'install-hook', 'tester', str(os.getuid()), str(os.getgid())], self.calls)
        privileged = [argv for argv in self.calls if argv[0] == '/usr/bin/sudo']
        self.assertEqual(privileged, [['/usr/bin/sudo', '-n', '/usr/bin/systemctl', verb, 'nvwb-spark@tester.service']
                                      for verb in ('enable', 'start')])
        self.assertFalse(any('daemon-reload' in argv for argv in self.calls))

    def test_existing_inventory_is_preserved(self):
        inventory = self.base / 'inventory.json'
        original = '[{"name": "existing-project", "path": "/home/tester/project"}]\n'
        inventory.write_text(original)
        self.before = self.snapshot()
        with contextlib.redirect_stdout(io.StringIO()):
            self.module.main([])
        self.assertEqual(inventory.read_text(), original)

    def test_existing_local_context_is_reused_and_service_started(self):
        self.contexts = [{'name': 'local', 'hostname': 'localhost', 'workbenchDir': str(self.base)}]
        self.before = self.snapshot()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.module.main([]), 0)
        self.assertFalse(any('create' in argv for argv in self.calls))
        privileged = [argv[3:] for argv in self.calls if argv[0] == '/usr/bin/sudo']
        self.assertEqual(privileged, [['enable', 'nvwb-spark@tester.service'], ['start', 'nvwb-spark@tester.service']])

    def test_fresh_install_with_null_context_listing_creates_local_context(self):
        # The vendor CLI reports {"result": null} when no context exists yet.
        self.contexts = None
        self.before = self.snapshot()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.module.main([]), 0)
        self.assertTrue(any('create' in argv for argv in self.calls), 'a local context must be created')


if __name__ == '__main__':
    unittest.main()
