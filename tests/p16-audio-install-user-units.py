"""Exercise the installer as root while home writes use the real nobody UID."""
from pathlib import Path
import os
import pwd
import shlex
import socket
import subprocess
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[1] / 'pkgbuilds/p16-audio'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.root.chmod(0o755)
        self.account = pwd.getpwnam('nobody')
        self.home = self.root / 'configured home'
        self.home.mkdir()
        os.chown(self.home, self.account.pw_uid, self.account.pw_gid)
        self.other = self.root / 'unconfigured home'
        self.other.mkdir()
        self.bindir = self.root / 'bin'
        self.bindir.mkdir()
        self.dmi = self.root / 'dmi'
        self.dmi.mkdir()
        (self.dmi / 'product_name').write_text('ProArt P16 H7607BA\n')
        (self.dmi / 'board_name').write_text('H7607BA\n')
        self.acpi = self.root / 'acpi'
        (self.acpi / 'NVDA6210:00').mkdir(parents=True)
        self.config = self.root / 'rules.conf'
        self.config.write_bytes((PACKAGE / '80-p16-internal-sinks.conf').read_bytes())
        self.service = self.root / 'p16-audio-jack.service'
        self.service.touch()
        self.legacy = self.root / 'global.conf'
        self.legacy.parent.mkdir(parents=True, exist_ok=True)
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir()
        self.log = self.root / 'systemctl.log'
        self.log.touch(mode=0o666)
        self.log.chmod(0o666)
        getent = self.bindir / 'getent'
        entry = f'nobody:x:{self.account.pw_uid}:{self.account.pw_gid}::{self.home}:/bin/false'
        getent.write_text('#!/bin/sh\nprintf "%s\\n" ' + shlex.quote(entry) + '\n')
        getent.chmod(0o755)
        systemctl = self.bindir / 'systemctl'
        rules = self.home / '.config/wireplumber/wireplumber.conf.d/80-p16-internal-sinks.conf'
        systemctl.write_text('#!/bin/sh\n'
            'if [ "$*" = "--user try-restart wireplumber.service" ]; then\n'
            '  test ! -e ' + shlex.quote(str(rules)) + ' || exit 42\n'
            'fi\nprintf "%s\\n" "$*" >> ' + shlex.quote(str(self.log)) + '\n')
        systemctl.chmod(0o755)
        self.helper = self.root / 'install-user-config'
        self.helper.write_bytes((PACKAGE / 'install-user-config').read_bytes())
        self.helper.chmod(0o755)
        self.runtime_root = self.root / 'runtime'
        self.logged_out_installer = self.root / 'installer-logged-out'
        source = (PACKAGE / 'install-user-units').read_text()
        for name, path in {'dmi_root': self.dmi, 'acpi_root': self.acpi,
                           'config_source': self.config, 'service_source': self.service,
                           'config_installer': self.helper, 'legacy_config': self.legacy,
                           'runtime_root': self.runtime_root}.items():
            import re
            source, count = re.subn(r'^readonly ' + name + r'=.*$',
                                    lambda m: 'readonly ' + name + '=' + shlex.quote(str(path)),
                                    source, flags=re.M)
            self.assertEqual(count, 1, name)
        source = source.replace(
            'readonly config_source=' + shlex.quote(str(self.config)),
            'config_source=' + shlex.quote(str(self.config)))
        source = source.replace(
            'readonly service_source=' + shlex.quote(str(self.service)),
            'service_source=' + shlex.quote(str(self.service)))
        source = source.replace(
            'readonly config_installer=' + shlex.quote(str(self.helper)),
            'config_installer=' + shlex.quote(str(self.helper)))
        source = source.replace('systemctl --user', shlex.quote(str(systemctl)) + ' --user')
        self.installer = self.root / 'installer'
        self.installer.write_text(source)
        self.installer.chmod(0o755)
        self.logged_out_installer.write_text(source.replace(
            'readonly runtime_root=' + shlex.quote(str(self.runtime_root)),
            'readonly runtime_root=' + shlex.quote(str(self.root / 'no-runtime'))))
        self.logged_out_installer.chmod(0o755)
        self.env = os.environ | {'PATH': str(self.bindir) + ':/usr/bin:/bin',
                                 'SUDO_UID': str(self.account.pw_uid)}

    def tearDown(self):
        self.tmp.cleanup()

    def run_installer(self):
        return subprocess.run([str(self.installer)], env=self.env, text=True, capture_output=True)

    def run_logged_out(self):
        return subprocess.run([str(self.logged_out_installer)], env=self.env, text=True, capture_output=True)

    def test_offline_user_gets_graph_and_scoped_rules(self):
        self.legacy.write_bytes(self.config.read_bytes())
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        config = self.home / '.config/wireplumber/wireplumber.conf.d/80-p16-internal-sinks.conf'
        self.assertEqual(config.read_bytes(), self.config.read_bytes())
        self.assertEqual(config.stat().st_uid, self.account.pw_uid)
        link = self.home / '.config/systemd/user/pipewire.service.wants/p16-audio-jack.service'
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.lstat().st_uid, self.account.pw_uid)
        self.assertFalse(self.legacy.exists())
        self.assertFalse((self.other / '.config').exists())
        self.assertNotIn('try-restart', self.log.read_text())
        self.assertEqual(self.log.read_text(), '')

    def test_online_user_gets_rules_and_reload(self):
        directory = self.runtime / str(self.account.pw_uid)
        directory.mkdir()
        with socket.socket(socket.AF_UNIX) as bus:
            bus.bind(str(directory / 'bus'))
            result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / '.config/wireplumber/wireplumber.conf.d/80-p16-internal-sinks.conf').is_file())
        self.assertIn('--user daemon-reload', self.log.read_text())
        self.assertIn('--user enable p16-audio-jack.service', self.log.read_text())

    def test_hostile_systemd_symlink_cannot_write_protected_directory(self):
        protected = self.root / 'protected-systemd'
        protected.mkdir(mode=0o700)
        (protected / 'sentinel').write_text('untouched')
        parent = self.home / '.config/systemd'
        parent.mkdir(parents=True)
        for directory in (self.home / '.config', parent):
            os.chown(directory, self.account.pw_uid, self.account.pw_gid)
        (parent / 'user').symlink_to(protected)
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sorted(p.name for p in protected.iterdir()), ['sentinel'])
        self.assertEqual((protected / 'sentinel').read_text(), 'untouched')

    def test_preserves_unrelated_administrator_rules(self):
        self.legacy.write_text('administrator custom rules\n')
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.legacy.read_text(), 'administrator custom rules\n')

    def test_uninstall_removes_only_exact_user_rules_and_own_service_link_offline(self):
        offline = self.run_logged_out()
        self.assertEqual(offline.returncode, 0, offline.stderr)
        rules = self.home / '.config/wireplumber/wireplumber.conf.d/80-p16-internal-sinks.conf'
        link = self.home / '.config/systemd/user/pipewire.service.wants/p16-audio-jack.service'
        self.assertTrue(rules.is_file())
        self.assertTrue(link.is_symlink())

        uninstall = subprocess.run([str(self.installer), '--remove'], env=self.env,
                                   text=True, capture_output=True)
        self.assertEqual(uninstall.returncode, 0, uninstall.stderr)
        self.assertFalse(rules.exists())
        self.assertFalse(link.exists())
        self.assertFalse(self.legacy.exists())
        self.assertFalse((self.other / '.config').exists())

        again = subprocess.run([str(self.installer), '--remove'], env=self.env,
                               text=True, capture_output=True)
        self.assertEqual(again.returncode, 0, again.stderr)

    def test_uninstall_preserves_custom_user_rules_and_similar_link(self):
        config_dir = self.home / '.config/wireplumber/wireplumber.conf.d'
        config_dir.mkdir(parents=True)
        custom = config_dir / '80-p16-internal-sinks.conf'
        custom.write_text('customized user rule\n')
        wants = self.home / '.config/systemd/user/pipewire.service.wants'
        wants.mkdir(parents=True)
        other_link = wants / 'p16-audio-jack.service'
        other_link.symlink_to('/usr/lib/systemd/user/custom-audio.service')

        uninstall = subprocess.run([str(self.installer), '--remove'], env=self.env,
                                   text=True, capture_output=True)
        self.assertEqual(uninstall.returncode, 0, uninstall.stderr)
        self.assertEqual(custom.read_text(), 'customized user rule\n')
        self.assertEqual(os.readlink(other_link), '/usr/lib/systemd/user/custom-audio.service')

    def test_online_uninstall_restarts_monitor_after_rule_removal(self):
        directory = self.runtime / str(self.account.pw_uid)
        directory.mkdir()
        with socket.socket(socket.AF_UNIX) as bus:
            bus.bind(str(directory / 'bus'))
            self.assertEqual(self.run_installer().returncode, 0)
            self.log.write_text('')
            result = subprocess.run([str(self.installer), '--remove'], env=self.env,
                                    text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(calls[-1], '--user try-restart wireplumber.service')
        self.assertTrue(calls[0].startswith('--user disable --now'))

    def test_online_uninstall_does_not_restart_for_custom_rule(self):
        self.assertEqual(self.run_installer().returncode, 0)
        rules = self.home / '.config/wireplumber/wireplumber.conf.d/80-p16-internal-sinks.conf'
        rules.write_text('customized user rule\n')
        directory = self.runtime / str(self.account.pw_uid)
        directory.mkdir()
        with socket.socket(socket.AF_UNIX) as bus:
            bus.bind(str(directory / 'bus'))
            result = subprocess.run([str(self.installer), '--remove'], env=self.env,
                                    text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('try-restart', self.log.read_text())
        self.assertEqual(rules.read_text(), 'customized user rule\n')

    def test_uninstall_symlinked_config_path_cannot_touch_protected_file(self):
        protected = self.root / 'protected-rules'
        protected.mkdir()
        sentinel = protected / 'custom.conf'
        sentinel.write_text('protected admin content\n')
        config_dir = self.home / '.config/wireplumber/wireplumber.conf.d'
        config_dir.mkdir(parents=True)
        (config_dir / '80-p16-internal-sinks.conf').symlink_to(sentinel)

        uninstall = subprocess.run([str(self.installer), '--remove'], env=self.env,
                                   text=True, capture_output=True)
        self.assertEqual(uninstall.returncode, 0, uninstall.stderr)
        self.assertEqual(sentinel.read_text(), 'protected admin content\n')
        self.assertTrue((config_dir / '80-p16-internal-sinks.conf').is_symlink())


if __name__ == '__main__':
    unittest.main()
