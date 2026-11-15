"""Authorization cannot select another account or grant arbitrary service control."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from helpers import load_script

module = load_script('nvwb-spark-authorize')


class Authorization(unittest.TestCase):
    def test_bad_names_are_rejected_before_lookup(self):
        with patch.object(module.pwd, 'getpwnam') as lookup:
            for name in ('', 'root ALL', 'alice*', '../alice', 'alice,root', 'alice\\nroot'):
                with self.assertRaises(ValueError):
                    module.account({'SUDO_USER': name, 'SUDO_UID': '1000'})
            lookup.assert_not_called()

    def test_identity_and_home_must_match(self):
        for uid, home, sudo_uid in ((0, '/home/alice', '0'), (1000, '/srv/alice', '1000'), (1000, '/home/alice', '1001')):
            with patch.object(module.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=uid, pw_dir=home)):
                with self.assertRaises(ValueError):
                    module.account({'SUDO_USER': 'alice', 'SUDO_UID': sudo_uid})

    def test_policy_is_limited_to_own_packaged_unit(self):
        rule = module.policy('alice')
        self.assertEqual(rule, 'alice ALL=(root) NOPASSWD: /usr/bin/systemctl enable nvwb-spark@alice.service, /usr/bin/systemctl start nvwb-spark@alice.service, /usr/bin/systemctl stop nvwb-spark@alice.service\n')
        self.assertNotIn('*', rule)


class Platform(unittest.TestCase):
    def devices(self, root, *ids):
        for index, (vendor, device) in enumerate(ids):
            path = root / f'0000:0{index}:00.0'
            path.mkdir()
            (path / 'vendor').write_text(vendor + '\n')
            (path / 'device').write_text(device + '\n')
        (root / 'no-ids').mkdir()
        return root

    def test_only_the_gb10_gpu_counts(self):
        with tempfile.TemporaryDirectory() as temp:
            self.assertTrue(module.gb10_present(self.devices(Path(temp), ('0x8086', '0x2e12'), ('0x10de', '0x2e12'))))
        with tempfile.TemporaryDirectory() as temp:
            # An N1x GPU and a GB10 device ID under another vendor are not a GB10.
            self.assertFalse(module.gb10_present(self.devices(Path(temp), ('0x10de', '0x2e06'), ('0x8086', '0x2e12'))))


    def test_other_machines_are_refused_before_any_change(self):
        with patch.object(module.os, 'geteuid', return_value=0), patch.object(module.sys, 'argv', ['authorize']), \
                patch.object(module, 'gb10_present', return_value=False), \
                patch.object(module, 'account') as account, patch.object(module.subprocess, 'run') as run:
            with self.assertRaises(SystemExit):
                module.main()
            account.assert_not_called()
            run.assert_not_called()


class Docker(unittest.TestCase):
    def run_configure(self, active, runtimes):
        calls = []

        def run(command, check=False, capture_output=False, text=False):
            calls.append(command[1] if command[0] == '/usr/bin/systemctl' else command[0])
            if command[0] == '/usr/bin/docker':
                self.assertEqual(command[1:3], ['--host', 'unix:///run/docker.sock'])
            if command[1] == 'is-active':
                return SimpleNamespace(returncode=0 if active else 3)
            if command[0] == '/usr/bin/docker':
                return SimpleNamespace(stdout=json.dumps(runtimes) + '\n')
            return SimpleNamespace(returncode=0)

        with patch.object(module.subprocess, 'run', side_effect=run):
            module.configure_docker()
        return calls

    def test_running_daemon_without_the_runtime_restarts(self):
        # Also the retry after an interrupted restart: the file already holds
        # the runtime, but the running daemon has not loaded it.
        self.assertEqual(self.run_configure(True, {'runc': {}}),
                         ['/usr/bin/nvidia-ctk', 'is-active', '/usr/bin/docker', 'restart'])

    def test_running_daemon_with_the_runtime_keeps_running(self):
        self.assertEqual(self.run_configure(True, {'nvidia': {}, 'runc': {}}),
                         ['/usr/bin/nvidia-ctk', 'is-active', '/usr/bin/docker'])

    def test_stopped_daemon_is_not_started(self):
        self.assertEqual(self.run_configure(False, {}), ['/usr/bin/nvidia-ctk', 'is-active'])

    def test_runtime_is_registered_before_access_is_granted(self):
        steps = []
        with tempfile.TemporaryDirectory() as temp:
            policy_file = tempfile.mkstemp(dir=temp)
            with patch.object(module.os, 'geteuid', return_value=0), patch.object(module.sys, 'argv', ['authorize']), \
                    patch.object(module, 'gb10_present', return_value=True), \
                    patch.object(module, 'account', return_value=SimpleNamespace(pw_name='alice')), \
                    patch.object(module.tempfile, 'mkstemp', return_value=policy_file), \
                    patch.object(module.subprocess, 'run', side_effect=lambda command, check: steps.append(command[0])), \
                    patch.object(module, 'configure_docker', side_effect=lambda: steps.append('docker')), \
                    patch.object(module.os, 'replace', side_effect=lambda *_: steps.append('grant')):
                module.main()
        self.assertEqual(steps, ['/usr/bin/visudo', 'docker', '/usr/bin/usermod', 'grant'])


if __name__ == '__main__':
    unittest.main()
