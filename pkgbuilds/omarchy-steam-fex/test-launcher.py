#!/usr/bin/env python3
"""Offline launcher tests: fake Steam/muvm/FEX, real Bash and Python, temporary HOME."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


LAUNCHER = Path(os.environ.get(
    'STEAM_LAUNCHER_TEST_SCRIPT',
    Path(__file__).with_name('omarchy-launch-steam'),
))

# A representative minified Steam network initialization block, including
# surrounding code that must survive the patch. Deliberately not a regex.
ORIGINAL = (
    'before();const t=(0,Ab.cd)("System.Network.RegisterForDeviceChanges");'
    't&&SteamClient.System.Network.RegisterForDeviceChanges(this.OnNetworkDevicesChanged),'
    '(0,Ab.cd)("System.Network.GetProxyInfo")&&SteamClient.System.Network.GetProxyInfo().then(e=>this.m_proxyInfo=e),'
    '(0,Ab.cd)("System.Network.RegisterForConnectivityTestChanges")&&SteamClient.System.Network.RegisterForConnectivityTestChanges(this.OnConnectivityTestStateChanged),'
    't||(this.m_bIsAwaitingInitialNetworkState=!1);after();'
)

MOCK = '''
import json, os
from pathlib import Path
import shutil, sys
name = Path(sys.argv[0]).name
if name == 'uname':
    print(os.environ.get('TEST_ARCH', 'aarch64'))
    sys.exit(0)
with open(os.environ['TEST_CALLS'], 'a') as log:
    log.write(json.dumps([name, *sys.argv[1:]]) + '\\n')
if name == 'muvm':
    assert sys.argv[1:3] == ['--', 'FEXBash']
    os.execv(shutil.which('FEXBash'), sys.argv[2:])
if name == 'FEXBash':
    os.execv('/bin/bash', ['/bin/bash', *sys.argv[1:]])
sys.exit(int(os.environ.get('TEST_EXIT', '0')))
'''


class SteamLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='steam-fex-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.user_home = self.root / 'home with spaces'
        self.user_home.mkdir()
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.calls_path = self.root / 'calls.jsonl'
        self.env = dict(os.environ, HOME=str(self.user_home), PATH=str(self.tools),
                        TEST_CALLS=str(self.calls_path), TEST_ARCH='aarch64', TEST_EXIT='0')
        for name in ['mkdir', 'cat', 'python3']:
            (self.tools / name).symlink_to(shutil.which(name))
        for name in ['uname', 'muvm', 'FEXBash', 'steam']:
            self.mock(self.tools / name)
        self.fex_launcher = self.user_home / '.local/share/fex-steam/steam-launcher/bin_steam.sh'
        self.mock(self.fex_launcher)
        self.steam_root = self.user_home / '.local/share/Steam'
        self.ui = self.steam_root / 'steamui'
        self.desktop = self.user_home / '.local/share/applications/steam.desktop'

    def mock(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'#!{sys.executable}\n' + MOCK)
        path.chmod(0o755)

    def run_launcher(self, *args, expected=0):
        result = subprocess.run(['/bin/bash', str(LAUNCHER), *args], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stderr)
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()] if self.calls_path.exists() else []

    def chunk(self, content=ORIGINAL, name='chunk~network.js'):
        self.ui.mkdir(parents=True, exist_ok=True)
        path = self.ui / name
        path.write_text(content)
        return path

    def client_ready(self):
        self.ui.mkdir(parents=True, exist_ok=True)
        binary = self.steam_root / 'ubuntu12_64/steamui.so'
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.touch()

    def assert_desktop(self):
        text = self.desktop.read_text()
        self.assertIn('\nExec=omarchy-launch-steam %U\n', text)
        self.assertIn('x-scheme-handler/steam;x-scheme-handler/steamlink;', text)

    def assert_fex(self, calls, flags, user_args):
        args = [str(self.fex_launcher), *flags, *user_args]
        self.assertEqual(calls, [
            ['muvm', '--', 'FEXBash', '-c', 'exec "$@"', 'omarchy-steam', *args],
            ['FEXBash', '-c', 'exec "$@"', 'omarchy-steam', *args],
            ['bin_steam.sh', *flags, *user_args],
        ])

    def test_prepare_without_client_only_writes_user_desktop(self):
        self.assertEqual(self.run_launcher('--prepare'), [])
        self.assert_desktop()
        self.assertFalse(self.steam_root.exists())

    def test_prepare_patches_matching_chunks_and_preserves_original(self):
        for identifier in ['Ab.cd', '_A2.x9']:
            with self.subTest(identifier=identifier):
                original = ORIGINAL.replace('Ab.cd', identifier)
                path = self.chunk(original, f'chunk~{identifier}.js')
                self.assertEqual(self.run_launcher('--prepare'), [])
                patched = path.read_text()
                self.assertTrue(patched.startswith('before();'))
                self.assertTrue(patched.endswith(';after();'))
                self.assertIn(f'const t=(0,{identifier})("System.Network.RegisterForDeviceChanges")&&!!', patched)
                self.assertEqual(patched.count('catch(e){}'), 3)
                self.assertIn('this.m_bIsAwaitingInitialNetworkState=!1,this.m_bIsConnectedToANetwork=!0', patched)
                self.assertEqual(path.with_suffix('.js.omarchy-bak').read_text(), original)
        self.assert_desktop()

    def test_repeated_prepare_is_idempotent_and_keeps_first_backup(self):
        path = self.chunk()
        self.run_launcher('--prepare')
        patched, modified = path.read_bytes(), path.stat().st_mtime_ns
        self.run_launcher('--prepare')
        self.assertEqual(path.read_bytes(), patched)
        self.assertEqual(path.stat().st_mtime_ns, modified)
        path.write_text(ORIGINAL.replace('Ab.cd', 'New.api'))
        self.run_launcher('--prepare')
        self.assertIn('(0,New.api)', path.read_text())
        self.assertEqual(path.with_suffix('.js.omarchy-bak').read_text(), ORIGINAL)

    def test_unmatched_code_and_other_filenames_are_untouched(self):
        for name, content in [('chunk~changed.js', 'otherNetworkCode();'), ('other.js', ORIGINAL)]:
            path = self.chunk(content, name)
            self.run_launcher('--prepare')
            self.assertEqual(path.read_text(), content)
            self.assertFalse(path.with_suffix('.js.omarchy-bak').exists())

    def test_unrelated_connected_state_does_not_skip_original_block(self):
        original = 'other.m_bIsConnectedToANetwork=!0;' + ORIGINAL
        path = self.chunk(original)
        self.run_launcher('--prepare')
        self.assertIn('catch(e){}', path.read_text())
        self.assertTrue(path.read_text().startswith('other.m_bIsConnectedToANetwork=!0;'))
        self.assertEqual(path.with_suffix('.js.omarchy-bak').read_text(), original)
        patched, modified = path.read_bytes(), path.stat().st_mtime_ns
        self.run_launcher('--prepare')
        self.assertEqual(path.read_bytes(), patched)
        self.assertEqual(path.stat().st_mtime_ns, modified)

    def test_existing_desktop_override_is_preserved_during_prepare_and_launch(self):
        self.client_ready()
        self.chunk()
        self.desktop.parent.mkdir(parents=True)
        customized = '[Desktop Entry]\nName=My Steam\nExec=my-steam-wrapper %U\nX-User-Setting=keep\n'
        self.desktop.write_text(customized)
        modified = self.desktop.stat().st_mtime_ns
        for args in [('--prepare',), ()]:
            self.run_launcher(*args)
            self.assertEqual(self.desktop.read_text(), customized)
            self.assertEqual(self.desktop.stat().st_mtime_ns, modified)

    def test_existing_desktop_symlink_is_preserved_even_with_missing_target(self):
        self.desktop.parent.mkdir(parents=True)
        target = self.user_home / 'custom-steam.desktop'
        self.desktop.symlink_to(target)
        self.run_launcher('--prepare')
        self.assertTrue(self.desktop.is_symlink())
        self.assertFalse(target.exists())

    def test_repeated_prepare_does_not_rewrite_created_desktop_override(self):
        self.run_launcher('--prepare')
        original, modified = self.desktop.read_bytes(), self.desktop.stat().st_mtime_ns
        self.run_launcher('--prepare')
        self.assertEqual(self.desktop.read_bytes(), original)
        self.assertEqual(self.desktop.stat().st_mtime_ns, modified)

    def test_only_first_matching_block_is_patched(self):
        path = self.chunk(ORIGINAL + ORIGINAL)
        self.run_launcher('--prepare')
        self.assertEqual(path.read_text().count('m_bIsConnectedToANetwork=!0'), 1)
        self.assertIn(ORIGINAL, path.read_text())

    def test_initial_launch_keeps_bootstrap_enabled_and_preserves_arguments(self):
        args = ['steam://rungameid/123', 'argument with spaces', '$(touch unwanted)', '']
        calls = self.run_launcher(*args)
        self.assert_fex(calls, ['-cef-force-occlusion'], args)
        self.assert_desktop()
        self.assertFalse(self.steam_root.exists())

    def test_ui_directory_alone_does_not_disable_bootstrap(self):
        path = self.chunk()
        self.assert_fex(self.run_launcher(), ['-cef-force-occlusion'], [])
        self.assertEqual(path.read_text(), ORIGINAL)

    def test_ready_launch_patches_and_keeps_update_checks_enabled(self):
        path = self.chunk()
        self.client_ready()
        args = ['steam://open/main']
        self.assert_fex(self.run_launcher(*args), ['-cef-force-occlusion', '-noverifyfiles'], args)
        self.assertIn('m_bIsConnectedToANetwork=!0', path.read_text())
        self.assert_desktop()

    def test_missing_fex_components_fall_back_without_modifying_user_files(self):
        for missing in [self.tools / 'muvm', self.tools / 'FEXBash', self.fex_launcher]:
            with self.subTest(missing=missing.name):
                missing.unlink()
                self.env['TEST_EXIT'] = '23'
                self.assertEqual(self.run_launcher('arg with spaces', expected=23), [['steam', 'arg with spaces']])
                self.assertFalse(self.desktop.exists())
                self.calls_path.unlink()
                self.mock(missing)

    def test_x86_prepare_is_noop_and_launch_falls_back(self):
        self.env['TEST_ARCH'] = 'x86_64'
        path = self.chunk()
        self.assertEqual(self.run_launcher('--prepare'), [])
        self.assertFalse(self.desktop.exists())
        self.assertEqual(path.read_text(), ORIGINAL)
        self.assertEqual(self.run_launcher('steam://open/main'), [['steam', 'steam://open/main']])

    def test_fex_exit_status_is_preserved(self):
        self.env['TEST_EXIT'] = '29'
        self.assert_fex(self.run_launcher(expected=29), ['-cef-force-occlusion'], [])


if __name__ == '__main__':
    unittest.main()
