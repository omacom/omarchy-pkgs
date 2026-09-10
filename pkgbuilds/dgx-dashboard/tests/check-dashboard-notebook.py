#!/usr/bin/python3
"""Exercise first launch in a disposable native container; see Dashboard README."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import time


def main():
    if not Path('/.dockerenv').exists() or os.geteuid() != 0:
        raise SystemExit('Run only as root inside a disposable container')
    proof = Path('/proof')
    home = Path('/home/builder')
    assert not (home / 'jupyterlab/.venv').exists()
    assert not (home / '.local/share/uv/python').exists()
    notebook = home / 'jupyterlab/keep.ipynb'
    notebook.parent.mkdir(exist_ok=True)
    notebook.write_text('{"cells": [], "metadata": {}, "nbformat": 4, "nbformat_minor": 5}\n')
    subprocess.run(['chown', '-R', 'builder:builder', str(notebook.parent)], check=True)
    before = notebook.read_bytes()
    env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=os.environ['DBUS_SESSION_BUS_ADDRESS'],
               PATH='/usr/lib/dgx-dashboard-arch:/usr/local/sbin:/usr/local/bin:/usr/bin')

    def call(method, *args):
        return subprocess.run([
            'busctl', '--address=' + env['DBUS_SYSTEM_BUS_ADDRESS'], 'call',
            'com.nvidia.dgx.dashboard.admin1', '/com/nvidia/dgx/dashboard/admin',
            'com.nvidia.dgx.dashboard.admin1', method, *args,
        ], env=env, capture_output=True, text=True, check=True)

    with (proof / 'admin.log').open('w') as log:
        admin = subprocess.Popen(['/opt/nvidia/dgx-dashboard/dashboard-admin'],
                                 env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            for _ in range(30):
                try:
                    call('GetJupyterlabInfo', 's', 'builder')
                    break
                except subprocess.CalledProcessError:
                    time.sleep(1)
            else:
                raise RuntimeError('Dashboard admin did not start')
            call('ActivateJupyterlab', 'ss', 'builder', str(notebook.parent))
            deadline = time.monotonic() + 1800
            previous = None
            while time.monotonic() < deadline:
                state = shlex.split(call('GetJupyterlabInfo', 's', 'builder').stdout)[2]
                if state != previous:
                    print('Dashboard notebook state:', state, flush=True)
                    previous = state
                if state == 'running':
                    break
                if state == 'error':
                    raise RuntimeError('Dashboard provisioning failed; inspect private admin.log')
                time.sleep(2)
            else:
                raise RuntimeError('Notebook provisioning timeout')
            assert notebook.read_bytes() == before, 'Existing notebook changed'
            python = str(home / 'jupyterlab/.venv/bin/python')
            version = subprocess.check_output([
                'runuser', '-u', 'builder', '--', python, '--version'], text=True).strip()
            assert version == 'Python 3.12.14', version
            assert (home / 'jupyterlab/.venv').stat().st_uid == 1000
            with (proof / 'authentication.log').open('w') as output:
                subprocess.run([
                    'runuser', '-u', 'builder', '--', 'env', 'HOME=' + str(home),
                    'PATH=' + str(home / 'jupyterlab/.venv/bin') + ':/usr/bin',
                    python, '/source/tests/check-jupyter-runtime.py',
                ], check=True, stdout=output, stderr=subprocess.STDOUT)
            config = home / 'jupyterlab/.venv/pyvenv.cfg'
            stamp = config.stat().st_mtime_ns
            call('ActivateJupyterlab', 'ss', 'builder', str(notebook.parent))
            time.sleep(3)
            assert config.stat().st_mtime_ns == stamp, 'Repeat activation recreated environment'
            report = dict(python=version, initial_environment='absent',
                          initial_managed_python='absent', existing_notebook_preserved=True,
                          repeat_activation_preserved_environment=True,
                          authentication_checks='passed', notebook_state=state)
            (proof / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps(report), flush=True)
        finally:
            admin.terminate()
            try:
                admin.wait(timeout=15)
            except subprocess.TimeoutExpired:
                admin.kill()
                admin.wait()


if __name__ == '__main__':
    main()
