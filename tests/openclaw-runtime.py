#!/usr/bin/env python3
"""Exercise the shipped bootstrap against an isolated system Node/npm fixture, never the host runtime."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import signal
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'pkgbuilds/openclaw'

RUNTIME = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, signal, sys, time
home = pathlib.Path(os.environ['HOME'])
args = [pathlib.Path(sys.argv[0]).name, *sys.argv[1:]]
with open(home / 'calls', 'a') as log:
    log.write(json.dumps(args) + '\n')
assert pathlib.Path(shutil.which('node')).parent == pathlib.Path(__file__).parent
assert pathlib.Path(shutil.which('npm')).parent == pathlib.Path(__file__).parent
if args[0] == 'npm':
    assert args[1:3] == ['install', '--global'], args
    assert '--allow-scripts=openclaw' in args
    prefix = pathlib.Path(args[args.index('--prefix') + 1])
    assert os.environ['npm_config_prefix'] == str(prefix)
    assert 'NPM_CONFIG_PREFIX' not in os.environ
    package = prefix / 'lib/node_modules/openclaw'
    package.mkdir(parents=True, exist_ok=True)
    (package / 'openclaw.mjs').write_text('// fixture runtime\n')
    if os.environ.get('FAIL_NPM'):
        sys.exit(23)
    time.sleep(float(os.environ.get('NPM_DELAY', '0')))
    (package / 'package.json').write_text(json.dumps({'version': args[-1].split('@')[1]}))
    sys.exit(0)
assert args[0] == 'node', args
package = pathlib.Path(args[1]).parent
version = json.loads((package / 'package.json').read_text())['version']
if args[2:] == ['--version']:
    if os.environ.get('FAIL_VERSION'):
        sys.exit(29)
    print(version)
else:
    if os.environ.get('CREATE_SERVICE'):
        unit_dir = home / '.config/systemd/user'
        unit_dir.mkdir(parents=True, exist_ok=True)
        service = 'openclaw-' + os.environ['CREATE_SERVICE']
        unit = unit_dir / (service + '.service')
        dropin_dir = unit_dir / (service + '.service.d')
        # Reproduce upstream's first-unit artifact snapshot rejection.
        assert unit.exists() or not dropin_dir.exists(), 'drop-in predates native unit'
        entry = str(package / 'dist/index.js')
        if os.environ.get('FOREIGN_SERVICE'):
            entry = '/unrelated/openclaw/dist/index.js'
        entry = entry.replace('%', '%%')
        if any(character.isspace() or character in '"\\' for character in entry):
            entry = '"' + entry.replace('\\', '\\\\').replace('"', '\\"') + '"'
        unit.write_text('[Service]\nExecStart=/usr/bin/node --max-old-space-size=2048 ' + entry + ' gateway\nEnvironment=OPENCLAW_SERVICE_MARKER=openclaw\n')
        if os.environ.get('WAIT_SIGNAL'):
            def terminated(signum, frame):
                time.sleep(0.15)
                assert not dropin_dir.exists(), 'postflight raced unreaped CLI'
                (home / 'signal-forwarded').write_text(str(signum))
                sys.exit(0)
            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(sig, terminated)
            (home / 'child-ready').touch()
            while True:
                time.sleep(0.05)
    if os.environ.get('NEED_STDIN'):
        assert sys.stdin.readline().strip() == 'interactive input'
    if os.environ.get('RUNTIME_EXIT'):
        sys.exit(int(os.environ['RUNTIME_EXIT']))
    print(json.dumps({'version': version, 'args': args[2:],
                      'wrapper': os.environ.get('OPENCLAW_WRAPPER'),
                      'prefix': os.environ['npm_config_prefix'],
                      'uppercase_prefix': os.environ.get('NPM_CONFIG_PREFIX'),
                      'cwd': str(pathlib.Path.cwd())}))
'''


class Runtime(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='openclaw-bootstrap-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home with spaces'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.bootstrap = self.bin / 'bootstrap'
        self.system_bin = self.root / 'system/bin'
        self.system_bin.mkdir(parents=True)
        # Relocate only the fixed system runtime path; no production override.
        self.bootstrap.write_text((PACKAGE / 'bootstrap').read_text().replace(
            'node_bin=/usr/bin', 'node_bin="' + str(self.system_bin) + '"'))
        self.bootstrap.chmod(0o755)
        for tool in ('node', 'npm'):
            (self.system_bin / tool).write_text(RUNTIME)
            (self.system_bin / tool).chmod(0o755)
        # Every scenario starts with hostile interactive version-manager tools.
        # The bootstrap must neither invoke mise nor select its node/npm shims.
        for tool in ('mise', 'node', 'npm'):
            (self.bin / tool).write_text('#!/bin/bash\ntouch "$HOME/unexpected-version-manager-tool"\nprintf "unexpected version-manager tool\\n" >&2\nexit 91\n')
            (self.bin / tool).chmod(0o755)
        (self.bin / 'systemctl').write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$HOME/systemctl-calls"
case "$*" in
  *is-enabled*) [[ ${SERVICE_ENABLED:-0} == 1 ]] ;;
  *is-active*) [[ ${SERVICE_ACTIVE:-0} == 1 ]] ;;
  *) exit 0 ;;
esac
''')
        (self.bin / 'systemctl').chmod(0o755)
        # Relocate only the package-owned absolute path in this fixture install.
        wrapper = (PACKAGE / 'openclaw').read_text().replace(
            '/usr/lib/openclaw/bootstrap', '"' + str(self.bootstrap) + '"')
        (self.bin / 'openclaw').write_text(wrapper)
        (self.bin / 'openclaw').chmod(0o755)
        self.prefix = self.home / '.local/share/openclaw/runtime'
        self.env = {'HOME': str(self.home), 'PATH': f'{self.bin}:/usr/bin:/bin',
                    'NPM_CONFIG_PREFIX': '/must/not/be/used',
                    'OPENCLAW_WRAPPER': '/must/not/be/used'}
        self.user = 65534 if os.geteuid() == 0 else None

    def prepare(self):
        if self.user is not None:
            for path in [self.root, *self.root.rglob('*')]:
                if not path.is_symlink():
                    os.chown(path, self.user, self.user)

    def command(self, *args, launcher=False, **env):
        self.prepare()
        return subprocess.run([str(self.bin / 'openclaw' if launcher else self.bootstrap), *args],
                              env=dict(self.env, **env), user=self.user, text=True,
                              capture_output=True)

    def success(self, *args, **kw):
        result = self.command(*args, **kw)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def calls(self):
        path = self.home / 'calls'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def installs(self):
        return [c for c in self.calls() if c[:2] == ['npm', 'install']]

    def test_package_contains_only_integration_assets(self):
        staged = self.root / 'package'
        sources = self.root / 'sources'
        shutil.copytree(PACKAGE, sources)
        self.prepare()
        result = subprocess.run(['bash', '-c', 'source "$1/PKGBUILD"; srcdir="$1"; pkgdir="$2"; package',
                                 'package-test', str(sources), str(staged)],
                                env=self.env, user=self.user, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        files = {str(p.relative_to(staged)) for p in staged.rglob('*') if p.is_file()}
        self.assertEqual(files, {'usr/bin/openclaw', 'usr/lib/openclaw/bootstrap',
                                 'usr/share/pixmaps/openclaw.png', 'usr/share/licenses/openclaw/LICENSE'})
        self.assertTrue(os.access(staged / 'usr/bin/openclaw', os.X_OK))
        self.assertTrue(os.access(staged / 'usr/lib/openclaw/bootstrap', os.X_OK))

    def test_check_is_read_only_and_prefix_is_stable(self):
        self.assertEqual(self.success('--prefix').strip(), str(self.prefix))
        self.assertNotEqual(self.command('--check').returncode, 0)
        self.assertFalse(self.prefix.exists())
        self.assertEqual(self.calls(), [])

    def test_install_uses_system_tools_despite_shadowing_without_modifying_user_config(self):
        config = self.home / '.npmrc'
        config.write_text('prefix=/unrelated/prefix\n')
        self.success('--install', '2026.9.4')
        self.assertEqual(self.success('--check').strip(), '2026.9.4')
        self.assertEqual(config.read_text(), 'prefix=/unrelated/prefix\n')
        self.assertEqual(len(self.installs()), 1)
        self.assertFalse((self.home / '.config/mise/config.toml').exists())
        self.assertFalse((self.home / 'unexpected-version-manager-tool').exists())
        self.assertFalse((self.prefix / '.bootstrap-incomplete').exists())

    def test_wrapper_preserves_self_update_and_forwards_arguments(self):
        self.success('--install', '2026.9.4')
        package = self.prefix / 'lib/node_modules/openclaw/package.json'
        package.write_text('{"version":"2099.1.1"}')
        self.success('--install', '2026.9.4')
        result = json.loads(self.success('gateway', '--message', 'spaces remain intact', launcher=True))
        self.assertEqual(result['version'], '2099.1.1')
        self.assertEqual(result['args'], ['gateway', '--message', 'spaces remain intact'])
        self.assertIsNone(result['wrapper'])
        self.assertEqual(result['prefix'], str(self.prefix))
        self.assertIsNone(result['uppercase_prefix'])
        self.assertEqual(result['cwd'], str(Path.cwd()))
        self.assertEqual(len(self.installs()), 1)

    def test_first_launch_keeps_bootstrap_output_off_stdout(self):
        result = self.command('status', launcher=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['args'], ['status'])
        self.assertIn('latest', result.stderr)

    def test_unmanaged_directory_and_symlink_are_preserved(self):
        self.prefix.mkdir(parents=True)
        sentinel = self.prefix / 'keep'
        sentinel.write_text('user installation')
        for action in ('--install', '--remove'):
            self.assertNotEqual(self.command(action).returncode, 0)
            self.assertEqual(sentinel.read_text(), 'user installation')
        sentinel.unlink()
        self.prefix.rmdir()
        other = self.home / 'other'
        other.mkdir()
        (other / '.omarchy-managed').write_text('omarchy-openclaw-runtime-v1\n')
        self.prefix.symlink_to(other, target_is_directory=True)
        for action in ('--install', '--remove'):
            self.assertNotEqual(self.command(action).returncode, 0)
        self.assertTrue(self.prefix.is_symlink())
        self.assertTrue(other.exists())

    def test_failed_npm_install_is_retryable_and_error_propagates(self):
        self.assertEqual(self.command('--install', FAIL_NPM='1').returncode, 23)
        self.assertTrue((self.prefix / '.bootstrap-incomplete').exists())
        self.assertNotEqual(self.command('--check').returncode, 0)
        self.success('--install', '2026.9.4')
        self.assertEqual(self.success('--check').strip(), '2026.9.4')
        self.assertEqual(len(self.installs()), 2)

    def test_missing_node_or_failed_version_check_is_not_ready(self):
        node = self.system_bin / 'node'
        node.rename(self.system_bin / 'node.saved')
        result = self.command('--install')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Reinstall the nodejs and npm packages', result.stderr)
        self.assertEqual(self.installs(), [])
        (self.system_bin / 'node.saved').rename(node)
        self.assertNotEqual(self.command('--install', FAIL_VERSION='1').returncode, 0)
        self.assertNotEqual(self.command('--check').returncode, 0)
        self.success('--install')
        self.assertNotEqual(self.command('--check', FAIL_VERSION='1').returncode, 0)

    def test_missing_node_requires_explicit_repair_without_resetting_runtime(self):
        self.success('--install', '2026.9.4')
        (self.system_bin / 'node').rename(self.system_bin / 'node.saved')
        self.assertNotEqual(self.command('--version', launcher=True).returncode, 0)
        self.assertNotEqual(self.command('--check').returncode, 0)
        self.assertNotEqual(self.command('--install').returncode, 0)
        (self.system_bin / 'node.saved').rename(self.system_bin / 'node')
        self.success('--install')
        self.assertEqual(self.success('--check').strip(), '2026.9.4')
        self.assertEqual(len(self.installs()), 1)

    def test_missing_system_npm_does_not_fall_back_to_version_manager(self):
        self.success('--install', '2026.9.4')
        (self.system_bin / 'npm').rename(self.system_bin / 'npm.saved')
        result = self.command('update', launcher=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Reinstall the nodejs and npm packages', result.stderr)
        self.assertNotIn('unexpected version-manager tool', result.stderr)
        self.assertEqual(len(self.installs()), 1)
        package = self.prefix / 'lib/node_modules/openclaw/package.json'
        self.assertEqual(json.loads(package.read_text())['version'], '2026.9.4')

    def test_concurrent_first_installs_only_install_npm_once(self):
        self.prepare()
        first = subprocess.Popen([str(self.bootstrap), '--install', '2026.9.4'],
                                 env=dict(self.env, NPM_DELAY='0.3'), user=self.user,
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        second = self.command('--install', '2026.9.4')
        _, error = first.communicate(timeout=10)
        self.assertEqual(first.returncode, 0, error)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(len(self.installs()), 1)

    def test_removal_only_removes_managed_runtime_and_is_idempotent(self):
        state = self.home / '.openclaw'
        state.mkdir()
        credentials = state / 'credentials'
        credentials.write_text('keep credentials')
        self.success('--install')
        self.success('--remove')
        self.success('--remove')
        self.assertFalse(self.prefix.exists())
        self.assertEqual(credentials.read_text(), 'keep credentials')
        self.assertTrue((self.system_bin / 'node').exists())
        self.assertTrue((self.system_bin / 'npm').exists())

    def create_unit(self, service='gateway'):
        directory = self.home / '.config/systemd/user'
        directory.mkdir(parents=True, exist_ok=True)
        unit = directory / f'openclaw-{service}.service'
        unit.write_text('[Service]\nExecStart=/usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway\nEnvironment=OPENCLAW_SERVICE_MARKER=openclaw\n')
        return unit

    def test_service_environment_survives_unit_regeneration(self):
        self.create_unit('gateway')
        self.create_unit('node')
        self.success('--install')
        units = self.home / '.config/systemd/user'
        for service in ('openclaw-gateway', 'openclaw-node'):
            dropin = units / f'{service}.service.d/50-omarchy-runtime.conf'
            content = dropin.read_text()
            self.assertIn(f'Environment="npm_config_prefix={self.prefix}"', content)
            self.assertIn(f'Environment="PATH={self.system_bin}:', content)
            self.assertNotIn('mise', content)
            self.assertIn('UnsetEnvironment=NPM_CONFIG_PREFIX OPENCLAW_WRAPPER', content)
            # Upstream rewrites its main service file, leaving drop-ins intact.
            (units / f'{service}.service').write_text(
                f'[Service]\nExecStart=/usr/bin/node "{self.prefix}/lib/node_modules/openclaw/dist/index.js" gateway\n'
                'Environment=OPENCLAW_SERVICE_MARKER=openclaw\n')
            self.assertEqual(dropin.read_text(), content)
        self.success('--install')
        self.assertEqual(len(self.installs()), 1)

    def test_foreign_dropin_is_not_overwritten_or_removed(self):
        self.create_unit('gateway')
        self.create_unit('node')
        self.success('--install')
        directory = self.home / '.config/systemd/user/openclaw-gateway.service.d'
        own_name = directory / '50-omarchy-runtime.conf'
        own_name.write_text('# My settings\n')
        unrelated = directory / '99-personal.conf'
        unrelated.write_text('[Service]\nEnvironment=EXAMPLE=keep\n')
        self.assertNotEqual(self.command('--install').returncode, 0)
        self.assertEqual(own_name.read_text(), '# My settings\n')
        self.success('--remove')
        self.assertEqual(own_name.read_text(), '# My settings\n')
        self.assertTrue(unrelated.exists())
        self.assertFalse((self.home / '.config/systemd/user/openclaw-node.service.d/50-omarchy-runtime.conf').exists())

    def test_foreign_service_fails_before_mutating_runtime_or_environment(self):
        units = self.home / '.config/systemd/user'
        units.mkdir(parents=True)
        unit = units / 'openclaw-gateway.service'
        original = '[Service]\nExecStart=/usr/bin/node /other/openclaw/dist/index.js gateway\nEnvironment=OPENCLAW_SERVICE_MARKER=openclaw\n'
        unit.write_text(original)
        result = self.command('--install')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('another installation', result.stderr)
        self.assertFalse(self.prefix.exists())
        self.assertFalse((units / 'openclaw-gateway.service.d').exists())
        self.assertFalse((units / 'openclaw-node.service.d').exists())
        self.assertEqual(unit.read_text(), original)
        self.assertEqual(self.calls(), [])

    def test_legacy_generated_service_is_accepted_but_custom_exec_override_is_not(self):
        units = self.home / '.config/systemd/user'
        units.mkdir(parents=True)
        unit = units / 'openclaw-gateway.service'
        unit.write_text('[Service]\nExecStart=/usr/bin/node --max-old-space-size=2048 /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789\nEnvironment="OPENCLAW_SERVICE_MARKER=openclaw"\n')
        self.success('--install')
        override = units / 'openclaw-gateway.service.d/99-personal.conf'
        override.write_text('[Service]\nExecStart=\nExecStart=/other/command\n')
        old = (units / 'openclaw-gateway.service.d/50-omarchy-runtime.conf').read_text()
        self.assertNotEqual(self.command('--install').returncode, 0)
        self.assertEqual((units / 'openclaw-gateway.service.d/50-omarchy-runtime.conf').read_text(), old)
        self.assertEqual(len(self.installs()), 1)

    def test_known_heap_flags_are_accepted_but_custom_node_code_is_not(self):
        units = self.home / '.config/systemd/user'
        units.mkdir(parents=True)
        unit = units / 'openclaw-gateway.service'
        marker = 'Environment=OPENCLAW_SERVICE_MARKER=openclaw\n'
        for flags in ('--max-old-space-size=2048', '--max-old-space-size-percentage=12.5 --max-heap-size=4096'):
            unit.write_text(f'[Service]\nExecStart=/usr/bin/node {flags} /usr/lib/node_modules/openclaw/dist/index.js gateway\n' + marker)
            self.success('--install')
        unit.write_text('[Service]\nExecStart=/usr/bin/node --require /custom/code.js /usr/lib/node_modules/openclaw/dist/index.js gateway\n' + marker)
        self.assertNotEqual(self.command('--install').returncode, 0)
        self.assertEqual(len(self.installs()), 1)

    def test_custom_or_symlinked_units_are_not_claimed(self):
        units = self.home / '.config/systemd/user'
        units.mkdir(parents=True)
        unit = units / 'openclaw-node.service'
        # Even a known package path requires the upstream generated marker.
        unit.write_text('[Service]\nExecStart=/usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js node\n')
        self.assertNotEqual(self.command('--install').returncode, 0)
        unit.unlink()
        unit.symlink_to('/dev/null')
        self.assertNotEqual(self.command('--install').returncode, 0)
        self.assertTrue(unit.is_symlink())
        self.assertFalse(self.prefix.exists())

    def test_systemd_specifiers_are_escaped(self):
        self.home = self.root / 'percent%home'
        self.home.mkdir()
        self.env['HOME'] = str(self.home)
        self.prefix = self.home / '.local/share/openclaw/runtime'
        self.create_unit('gateway')
        self.success('--install')
        content = (self.home / '.config/systemd/user/openclaw-gateway.service.d/50-omarchy-runtime.conf').read_text()
        self.assertIn('percent%%home', content)
        self.assertNotIn('percent%home', content)

    def test_native_user_runtime_with_systemd_specifiers_is_recognized(self):
        for name in ('percent%home', 'percent% home'):
            with self.subTest(home=name):
                self.home = self.root / name
                self.home.mkdir()
                self.env['HOME'] = str(self.home)
                self.prefix = self.home / '.local/share/openclaw/runtime'
                self.success('--install')
                self.success('gateway', 'install', launcher=True, CREATE_SERVICE='gateway',
                             SERVICE_ACTIVE='1', SERVICE_ENABLED='1')
                units = self.home / '.config/systemd/user'
                unit = units / 'openclaw-gateway.service'
                self.assertIn(name.replace('%', '%%'), unit.read_text())
                dropin = units / 'openclaw-gateway.service.d/50-omarchy-runtime.conf'
                self.assertTrue(dropin.exists())
                inode = dropin.stat().st_ino
                self.success('--install')
                self.assertEqual(dropin.stat().st_ino, inode)
                self.assertEqual(len(self.installs()), 1)

    def test_first_unit_has_no_precreated_dropin_and_gets_live_environment_after_install(self):
        self.success('--install')
        units = self.home / '.config/systemd/user'
        self.assertFalse(units.exists())
        self.success('gateway', 'install', launcher=True, CREATE_SERVICE='gateway',
                     SERVICE_ACTIVE='1', SERVICE_ENABLED='1')
        dropin = units / 'openclaw-gateway.service.d/50-omarchy-runtime.conf'
        self.assertTrue(dropin.exists())
        calls = (self.home / 'systemctl-calls').read_text()
        self.assertIn('--user daemon-reload', calls)
        self.assertIn('--user try-restart openclaw-gateway.service', calls)
        inode = dropin.stat().st_ino
        (self.home / 'systemctl-calls').unlink()
        self.success('gateway', 'install', launcher=True, CREATE_SERVICE='gateway',
                     SERVICE_ACTIVE='1', SERVICE_ENABLED='1')
        self.assertEqual(dropin.stat().st_ino, inode)
        self.assertFalse((self.home / 'systemctl-calls').exists())

    def test_postflight_preserves_stopped_or_disabled_services(self):
        for active, enabled in [('0', '1'), ('1', '0')]:
            self.success('gateway', 'install', launcher=True, CREATE_SERVICE='gateway',
                         SERVICE_ACTIVE=active, SERVICE_ENABLED=enabled)
            dropin = self.home / '.config/systemd/user/openclaw-gateway.service.d/50-omarchy-runtime.conf'
            self.assertTrue(dropin.exists())
            self.assertNotIn('try-restart', (self.home / 'systemctl-calls').read_text())
            dropin.unlink()
            (self.home / 'systemctl-calls').unlink()

    def test_readonly_poll_does_not_race_new_unit_publication(self):
        self.success('--install')
        self.success('dashboard', '--json', launcher=True, CREATE_SERVICE='gateway')
        self.assertFalse((self.home / '.config/systemd/user/openclaw-gateway.service.d').exists())

    def test_postflight_rejects_foreign_unit_written_by_cli(self):
        self.success('--install')
        result = self.command('gateway', 'install', launcher=True,
                              CREATE_SERVICE='gateway', FOREIGN_SERVICE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / '.config/systemd/user/openclaw-gateway.service.d').exists())

    def test_interactive_stdin_and_cli_exit_status_are_preserved(self):
        self.success('--install')
        self.prepare()
        result = subprocess.run([str(self.bin / 'openclaw'), 'onboard'],
                                env=dict(self.env, NEED_STDIN='1'), user=self.user,
                                input='interactive input\n', text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.command('doctor', launcher=True, RUNTIME_EXIT='37').returncode, 37)

    def terminate_lifecycle(self, sig):
        self.success('--install')
        self.prepare()
        process = subprocess.Popen([str(self.bin / 'openclaw'), 'onboard'],
                                   env=dict(self.env, CREATE_SERVICE='gateway', WAIT_SIGNAL='1',
                                            SERVICE_ACTIVE='1', SERVICE_ENABLED='1'),
                                   user=self.user, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        deadline = time.monotonic() + 5
        while not (self.home / 'child-ready').exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue((self.home / 'child-ready').exists())
        process.send_signal(sig)
        _, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 128 + sig, error)
        self.assertEqual((self.home / 'signal-forwarded').read_text(), str(sig))
        self.assertTrue((self.home / '.config/systemd/user/openclaw-gateway.service.d/50-omarchy-runtime.conf').exists())
        self.assertIn('try-restart openclaw-gateway.service', (self.home / 'systemctl-calls').read_text())

    def test_termination_reaches_cli_and_postflight_waits_for_exit(self):
        self.terminate_lifecycle(signal.SIGTERM)

    def test_interrupt_reaches_cli_and_postflight_waits_for_exit(self):
        self.terminate_lifecycle(signal.SIGINT)

    def test_hangup_reaches_cli_and_postflight_waits_for_exit(self):
        self.terminate_lifecycle(signal.SIGHUP)

    def test_global_options_preserve_lifecycle_detection_and_full_argv(self):
        self.success('--install')
        result = json.loads(self.success('--no-color', '--log-level', 'debug', 'gateway', 'install',
                                         launcher=True, CREATE_SERVICE='gateway'))
        self.assertEqual(result['args'], ['--no-color', '--log-level', 'debug', 'gateway', 'install'])
        self.assertTrue((self.home / '.config/systemd/user/openclaw-gateway.service.d/50-omarchy-runtime.conf').exists())

    def test_global_options_between_command_and_subcommand_keep_postflight(self):
        self.success('--install')
        self.success('gateway', '--no-color', 'install', launcher=True, CREATE_SERVICE='gateway')
        self.assertTrue((self.home / '.config/systemd/user/openclaw-gateway.service.d/50-omarchy-runtime.conf').exists())

    def test_dashboard_yes_installs_receive_service_environment(self):
        self.success('--install')
        self.success('dashboard', '--yes', launcher=True, CREATE_SERVICE='gateway')
        self.assertTrue((self.home / '.config/systemd/user/openclaw-gateway.service.d/50-omarchy-runtime.conf').exists())

    def test_rejects_arbitrary_npm_specs(self):
        for version in ('file:/tmp/package', 'https://example.com/pkg.tgz', '--prefix=/tmp', ''):
            self.assertNotEqual(self.command('--install', version).returncode, 0)
        self.assertEqual(self.calls(), [])

    @unittest.skipUnless(os.geteuid() == 0, 'root rejection runs in CI container')
    def test_root_cannot_install(self):
        result = subprocess.run([str(self.bootstrap), '--install'], env=self.env,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('without sudo', result.stderr)
        self.assertFalse(self.prefix.exists())


if __name__ == '__main__':
    unittest.main()
