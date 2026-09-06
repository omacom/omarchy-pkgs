#!/usr/bin/env python3
"""Exercise the packaged entry point with a disposable HOME and installer."""
import json
import os
import pty
import signal
import time
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'pkgbuilds/hermes-desktop/hermes-desktop.sh'
INSTALLER = r'''#!/bin/bash
set -eu
while (( $# )); do
  case $1 in --dir) root=$2; shift;; --stage) stage=$2; shift;; esac
  shift
done
printf '%s\n' "$stage" >> "$TEST_LOG"
[[ ${FAIL_STAGE:-} != "$stage" ]] || exit 42
case $stage in
repository)
  mkdir -p "$root/venv/bin"
  git init -q "$root"
  git -C "$root" remote add origin https://github.com/NousResearch/hermes-agent.git
  touch "$root/hermes"
  cp "$TEST_PYTHON" "$root/venv/bin/python"
  git -C "$root" add hermes venv
  git -C "$root" -c user.email=test@example.com -c user.name=Test commit -qm initial
  ;;
desktop)
  mkdir -p "$root/apps/desktop/release/linux-unpacked"
  cp "$TEST_GUI" "$root/apps/desktop/release/linux-unpacked/Hermes"
  printf '/apps/\n/.hermes-bootstrap-complete\n' >> "$root/.git/info/exclude"
  ;;
complete) touch "$root/.hermes-bootstrap-complete";;
path)
  mkdir -p "$HOME/.local/bin"
  for command in hermes hermes-agent hermes-acp; do
    entry=hermes; suffix=''
    [[ $command != hermes-agent ]] || entry=run_agent.py
    [[ $command != hermes-acp ]] || suffix=' acp'
    printf '#!/usr/bin/env bash\nunset PYTHONPATH\nunset PYTHONHOME\nexec "%s/venv/bin/python" "%s/%s"%s "$@"\n' "$root" "$root" "$entry" "$suffix" > "$HOME/.local/bin/$command"
    chmod +x "$HOME/.local/bin/$command"
  done
  [[ ${FAIL_AFTER_PATH:-} != 1 ]] || exit 43
  ;;
esac
'''

class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hermes-package-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / 'home with spaces'
        self.home.mkdir()
        self.root = self.home / '.hermes/hermes-agent'
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.log = self.base / 'stages'
        self.output = self.base / 'launch.json'
        self.env = dict(os.environ, HOME=str(self.home), HERMES_HOME=str(self.home / '.hermes'),
                        PATH=f'{self.bin}:/usr/bin:/bin', TEST_LOG=str(self.log),
                        TEST_GUI=str(self.base / 'gui'), TEST_PYTHON=str(self.base / 'python'),
                        TEST_OUTPUT=str(self.output), GIT_CONFIG_NOSYSTEM='1',
                        GIT_CONFIG_GLOBAL='/dev/null')
        for k in ['FAIL_STAGE', 'FAIL_AFTER_PATH', 'PYTHONHOME', 'PYTHONPATH']:
            self.env.pop(k, None)
        self.write(self.base / 'installer', INSTALLER)
        self.write(self.base / 'python', '#!/bin/bash\n[[ ${FAIL_READY:-} != 1 ]]\n')
        self.write(self.base / 'gui', '''#!/usr/bin/env python3
import json,os,sys,time
json.dump({'pid':os.getpid(),'args':sys.argv[1:],'root':os.environ['HERMES_DESKTOP_HERMES_ROOT'],'node':os.environ.get('ELECTRON_RUN_AS_NODE'),'password':os.environ['HERMES_DESKTOP_PASSWORD_STORE']},open(os.environ['TEST_OUTPUT'],'w'))
if os.environ.get('TEST_GUI_WAIT'): time.sleep(30)
''')
        self.write(self.bin / 'unshare', '#!/bin/bash\nexit 0\n')
        self.write(self.bin / 'xdg-terminal-exec', '#!/bin/bash\nprintf "%s\\n" "$@" > "$TEST_OUTPUT"\n')
        source = SOURCE.read_text().replace('/usr/share/hermes-desktop/install.sh', str(self.base / 'installer'))
        source = source.replace('/usr/bin/hermes-desktop', str(self.base / 'launcher'))
        self.write(self.base / 'launcher', source)

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def run_launcher(self, *args, ok=True, **env):
        result = subprocess.run(['bash', str(self.base / 'launcher'), *args], env=self.env | env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode == 0, ok, result.stdout)
        return result

    def install(self):
        self.run_launcher('--install')
        self.run_launcher('--check')

    def test_fresh_install_publishes_cli_after_desktop(self):
        self.install()
        stages = self.log.read_text().splitlines()
        self.assertLess(stages.index('desktop'), stages.index('path'))
        self.assertEqual((self.root / '.omarchy-hermes-desktop').read_text(), 'ready\n')
        self.assertEqual(subprocess.check_output(['git','-C',str(self.root),'status','--porcelain'],env=self.env),b'')

    def test_warm_launch_and_package_reinstall_leave_runtime_untouched(self):
        self.install()
        before = self.log.read_bytes()
        self.run_launcher('--install')
        self.run_launcher('hermes://test?a=b', 'two words', WAYLAND_DISPLAY='wayland-1', ELECTRON_RUN_AS_NODE='1')
        observed = json.loads(self.output.read_text())
        self.assertEqual(observed['args'], ['--ozone-platform=wayland','--disable-setuid-sandbox','hermes://test?a=b','two words'])
        self.assertEqual(observed['root'],str(self.root))
        self.assertIsNone(observed['node'])
        self.assertEqual(observed['password'],'gnome-libsecret')
        self.assertEqual(before,self.log.read_bytes())

    def test_explicit_platform_and_password_are_preserved(self):
        self.install()
        self.run_launcher('--ozone-platform=x11', WAYLAND_DISPLAY='wayland-1', HERMES_DESKTOP_PASSWORD_STORE='kwallet6')
        result=json.loads(self.output.read_text())
        self.assertNotIn('--ozone-platform=wayland',result['args'])
        self.assertEqual(result['password'],'kwallet6')

    def test_foreign_command_and_symlink_are_preserved(self):
        wrapper=self.home/'.local/bin/hermes'
        self.write(wrapper,'#!/bin/bash\necho custom\n')
        before=wrapper.read_bytes()
        self.run_launcher('--install',ok=False)
        self.assertEqual(before,wrapper.read_bytes())
        self.assertFalse(self.log.exists())
        wrapper.unlink()
        wrapper.symlink_to(self.base/'missing')
        self.run_launcher('--install',ok=False)
        self.assertTrue(wrapper.is_symlink())

    def test_customized_native_wrapper_is_preserved(self):
        self.install()
        wrapper=self.home/'.local/bin/hermes'
        wrapper.write_text(wrapper.read_text().replace('unset PYTHONPATH','export CUSTOM=yes\nunset PYTHONPATH'))
        before=wrapper.read_bytes()
        self.run_launcher('--install',ok=False)
        self.assertEqual(wrapper.read_bytes(),before)

    def test_failed_build_preserves_old_cli_and_retry_succeeds(self):
        wrapper=self.home/'.local/bin/hermes'
        self.write(wrapper,'#!/bin/bash\n# Written by omarchy-install-hermes-cli.\necho old\n')
        before=wrapper.read_bytes()
        self.run_launcher('--install',ok=False,FAIL_STAGE='desktop')
        self.assertEqual(wrapper.read_bytes(),before)
        self.run_launcher('--check',ok=False)
        self.install()
        self.assertNotEqual(wrapper.read_bytes(),before)

    def test_late_path_failure_restores_old_cli(self):
        wrapper=self.home/'.local/bin/hermes'
        self.write(wrapper,'#!/bin/bash\n# Written by omarchy-install-hermes-cli.\necho old\n')
        before=wrapper.read_bytes()
        self.run_launcher('--install',ok=False,FAIL_AFTER_PATH='1')
        self.assertEqual(wrapper.read_bytes(),before)
        self.run_launcher('--check',ok=False)
        self.install()

    def test_dirty_pending_checkout_is_preserved(self):
        self.run_launcher('--install',ok=False,FAIL_STAGE='desktop')
        (self.root/'hermes').write_text('user changes')
        before=self.log.read_bytes()
        self.run_launcher('--install',ok=False)
        self.assertEqual((self.root/'hermes').read_text(),'user changes')
        self.assertEqual(self.log.read_bytes(),before)

    def test_cold_graphical_launch_opens_visible_setup(self):
        self.run_launcher('hermes://open')
        self.assertEqual(self.output.read_text().splitlines(),[str(self.base/'launcher'),'--setup','hermes://open'])
        self.assertFalse(self.log.exists())

    def test_unexecutable_native_cli_is_repaired(self):
        self.install()
        wrapper=self.home/'.local/bin/hermes'
        wrapper.chmod(0o644)
        self.run_launcher('--check',ok=False)
        self.install()
        self.assertTrue(os.access(wrapper,os.X_OK))

    def test_old_cli_ownership_survives_package_only_setup(self):
        wrapper=self.home/'.local/bin/hermes'
        self.write(wrapper,'#!/bin/bash\n# Written by omarchy-install-hermes-cli.\necho old\n')
        self.install()
        receipt=self.root/'.git/omarchy-mise-predecessor'
        self.assertEqual(receipt.read_text(),'pipx:hermes-agent[extras=all]\n')

    def test_graphical_setup_detaches_and_releases_install_lock(self):
        started=time.monotonic()
        self.run_launcher('--setup', 'hermes://open', TEST_GUI_WAIT='1')
        self.assertLess(time.monotonic()-started,5)
        for _ in range(100):
            if self.output.exists(): break
            time.sleep(.02)
        observed=json.loads(self.output.read_text())
        self.addCleanup(lambda: os.kill(observed['pid'],signal.SIGTERM))
        self.assertIn('hermes://open',observed['args'])
        self.run_launcher('--install')
        lock=self.home/'.hermes/.omarchy-hermes-desktop.lock'
        self.assertEqual(subprocess.run(['flock','--nonblock',str(lock),'true']).returncode,0)

    def test_cold_terminal_launch_releases_lock_before_exec(self):
        master,slave=pty.openpty()
        process=subprocess.Popen(['bash',str(self.base/'launcher')],stdin=slave,stdout=slave,stderr=slave,env=self.env | {'TEST_GUI_WAIT':'1'})
        os.close(slave)
        def cleanup():
            if process.poll() is None: process.terminate()
            process.wait(timeout=5)
            os.close(master)
        self.addCleanup(cleanup)
        for _ in range(100):
            if self.output.exists(): break
            time.sleep(.02)
        self.assertTrue(self.output.exists())
        self.assertIsNone(process.poll())
        lock=self.home/'.hermes/.omarchy-hermes-desktop.lock'
        self.assertEqual(subprocess.run(['flock','--nonblock',str(lock),'true']).returncode,0)

    def test_pending_marker_overrides_old_completion(self):
        self.install()
        (self.root/'.omarchy-hermes-desktop').write_text('pending\n')
        self.run_launcher('--check',ok=False)

if __name__=='__main__':
    unittest.main()
