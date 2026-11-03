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
        systemctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> ' + shlex.quote(str(self.log)) + '\n')
        systemctl.chmod(0o755)
        self.helper = self.root / 'install-user-config'
        self.helper.write_bytes((PACKAGE / 'install-user-config').read_bytes())
        self.helper.chmod(0o755)
        source = (PACKAGE / 'install-user-units').read_text()
        for name, path in {'dmi_root': self.dmi, 'acpi_root': self.acpi,
                           'config_source': self.config, 'service_source': self.service,
                           'config_installer': self.helper, 'legacy_config': self.legacy,
                           'runtime_root': self.runtime}.items():
            import re
            source, count = re.subn(r'^readonly ' + name + r'=.*$',
                                    lambda m: 'readonly ' + name + '=' + shlex.quote(str(path)),
                                    source, flags=re.M)
            self.assertEqual(count, 1, name)
        source = source.replace('systemctl --user', shlex.quote(str(systemctl)) + ' --user')
        self.installer = self.root / 'installer'
        self.installer.write_text(source)
        self.installer.chmod(0o755)
        self.env = os.environ | {'PATH': str(self.bindir) + ':/usr/bin:/bin',
                                 'SUDO_UID': str(self.account.pw_uid)}

    def tearDown(self):
        self.tmp.cleanup()

    def run_installer(self):
        return subprocess.run([str(self.installer)], env=self.env, text=True, capture_output=True)

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


if __name__ == '__main__':
    unittest.main()
