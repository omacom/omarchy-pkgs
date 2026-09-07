"""Check launch settings and sandbox gates without running Hermes or sudo."""
import ast
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source, patch_file, launcher = map(Path, sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="hermes-runtime-check-") as temporary:
    root = Path(temporary)
    destination = root / "scripts/desktop-update/posix.sh"
    destination.parent.mkdir(parents=True)
    shutil.copyfile(source / "scripts/desktop-update/posix.sh", destination)
    subprocess.run(["git", "apply", str(patch_file.resolve())], cwd=root, check=True)

    home = root / "home with spaces"
    runtime = home / ".hermes/hermes-agent"
    native = runtime / "apps/desktop/release/linux-unpacked"
    native.mkdir(parents=True)
    executable = native / "Hermes"
    executable.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
from pathlib import Path
Path(os.environ["TEST_OUTPUT"]).write_text(json.dumps({
    "args": sys.argv[1:], "home": os.environ["HERMES_HOME"],
    "store": os.environ["HERMES_DESKTOP_PASSWORD_STORE"],
    "gpu": os.environ.get("HERMES_DESKTOP_DISABLE_GPU"),
    "ozone": os.environ.get("ELECTRON_OZONE_PLATFORM_HINT"),
    "cwd": os.environ.get("HERMES_DESKTOP_CWD"),
    "inherited": [name for name in ("ELECTRON_RUN_AS_NODE", "PYTHONPATH", "PYTHONHOME") if name in os.environ],
}))
''')
    executable.chmod(0o755)
    sandbox = native / "chrome-sandbox"
    sandbox.write_text("fixture")
    sandbox.chmod(0o755)

    # Execute the release's real option parser, isolating config I/O and avoiding
    # unrelated CLI imports, startup hooks and third-party dependencies.
    module = runtime / "hermes_cli"
    module.mkdir()
    (module / "__init__.py").touch()
    upstream = ast.parse((source / "hermes_cli/main.py").read_text())
    option_parser = next(node for node in upstream.body
                        if isinstance(node, ast.FunctionDef) and node.name == "_desktop_launch_options")
    stores = next(node for node in upstream.body if isinstance(node, ast.Assign)
                  and any(isinstance(target, ast.Name) and target.id == "_LINUX_PASSWORD_STORES"
                          for target in node.targets))
    helper = "import os, shlex\n" + ast.unparse(stores) + "\n" + ast.unparse(option_parser) + "\n"
    (module / "main.py").write_text(helper)
    (module / "config.py").write_text('''import json, os
from pathlib import Path
def load_config():
    path = Path(os.environ["HERMES_HOME"], "config.yaml")
    return json.loads(path.read_text()) if path.exists() else {}
''')
    (runtime / "hermes_constants.py").write_text('''import os
def with_hermes_node_path(env=None):
    return (os.environ if env is None else env).copy()
''')

    mock_bin = root / "bin"
    mock_bin.mkdir()
    unshare = mock_bin / "unshare"
    unshare.write_text('#!/bin/bash\nexit "${TEST_NAMESPACE_RESULT:-0}"\n')
    unshare.chmod(0o755)
    forbidden = '#!/bin/bash\ntouch "$TEST_FORBIDDEN"\nexit 99\n'
    cli = runtime / "venv/bin/hermes"
    cli.parent.mkdir(parents=True)
    cli.write_text(forbidden)
    cli.chmod(0o755)
    (cli.parent / "python").symlink_to(sys.executable)
    for command in ("sudo", "omarchy-install-hermes-cli"):
        target = mock_bin / command
        target.write_text(forbidden if command == "sudo" else '#!/bin/bash\nexit 0\n')
        target.chmod(0o755)

    output = root / "launch.json"
    forbidden_output = root / "forbidden"
    env = {"HOME": str(home), "PATH": f"{mock_bin}:/usr/bin:/bin",
           "TEST_OUTPUT": str(output), "TEST_FORBIDDEN": str(forbidden_output)}
    launch = ["bash", str(launcher.resolve())]

    def check_launch(args=(), overrides=None, expected_args=(), store="gnome-libsecret", gpu=None, ozone=None):
        subprocess.run(launch + list(args), env={**env, **(overrides or {})}, cwd=home, check=True)
        result = json.loads(output.read_text())
        assert result == {"args": ["--disable-setuid-sandbox", *expected_args],
                          "home": str(home / ".hermes"), "store": store, "gpu": gpu,
                          "ozone": ozone, "cwd": str(home), "inherited": []}, result
        assert not forbidden_output.exists(), "launcher invoked CLI or sudo"
        output.unlink()

    wayland = {"WAYLAND_DISPLAY": "wayland-1"}
    check_launch(overrides=wayland, expected_args=["--ozone-platform=wayland"])
    url = "hermes://open?text=a%20b"
    check_launch(["--ozone-platform=x11", url], {**wayland, "HERMES_DESKTOP_PASSWORD_STORE": "kwallet6"},
                 ["--ozone-platform=x11", url], store="kwallet6")
    check_launch(overrides={"HERMES_HOME": str(home / ".hermes/profiles/work"),
                            "HERMES_DESKTOP_DISABLE_GPU": "1"}, gpu="1")
    check_launch(overrides={"ELECTRON_RUN_AS_NODE": "1", "PYTHONPATH": "/invalid", "PYTHONHOME": "/invalid"})

    config = home / ".hermes/config.yaml"
    config.write_text(json.dumps({"desktop": {"disable_gpu": True, "password_store": "kwallet5",
                                              "ozone_platform_hint": "x11",
                                              "electron_flags": '--force-device-scale-factor=1.5 "--test=a b"'}}))
    config_flags = ["--force-device-scale-factor=1.5", "--test=a b"]
    for args in ([], [url]):
        check_launch(args, wayland, config_flags + args, store="kwallet5", gpu="1", ozone="x11")
    check_launch(overrides={**wayland, "HERMES_DESKTOP_DISABLE_GPU": "0",
                            "HERMES_DESKTOP_PASSWORD_STORE": "basic", "ELECTRON_OZONE_PLATFORM_HINT": "wayland"},
                 expected_args=config_flags, store="basic", gpu="0", ozone="wayland")
    config.write_text(json.dumps({"desktop": {"electron_flags": ["--ozone-platform=x11"], "disable_gpu": False}}))
    check_launch(overrides=wayland, expected_args=["--ozone-platform=x11"], gpu="0")
    # New upstream revisions expose the same helper from main_desktop instead.
    (module / "main_desktop.py").write_text(helper)
    (module / "main.py").write_text('raise AssertionError("old helper import after update")\n')
    check_launch([url], wayland, ["--ozone-platform=x11", url], gpu="0")
    config.unlink()
    (module / "main_desktop.py").write_text(helper + '\nimport os\nos.environ.update(' + repr({
        "ELECTRON_RUN_AS_NODE": "1", "PYTHONPATH": "/invalid", "PYTHONHOME": "/invalid",
        "HERMES_HOME": "/invalid", "HERMES_DESKTOP_DISABLE_GPU": "1",
        "HERMES_DESKTOP_PASSWORD_STORE": "basic", "ELECTRON_OZONE_PLATFORM_HINT": "x11",
    }) + ')\n')
    check_launch(overrides={**wayland, "HERMES_DESKTOP_DISABLE_GPU": "0"},
                 expected_args=["--ozone-platform=wayland"], gpu="0")
    (module / "main_desktop.py").write_text(helper)

    def check_namespace_failure():
        for code in ("1", "127"):
            for args in ([], [url]):
                result = subprocess.run(launch + args, env={**env, "TEST_NAMESPACE_RESULT": code},
                                        capture_output=True, text=True)
                assert result.returncode != 0 and "user namespaces" in result.stderr, result
                assert not output.exists() and not forbidden_output.exists()

    check_namespace_failure()
    # Exercise the real fallback branch with only its absolute app path redirected.
    fallback = root / "packaged-Hermes"
    shutil.copyfile(executable, fallback)
    fallback.chmod(0o755)
    fallback_launcher = root / "fallback-launcher"
    fallback_launcher.write_text(launcher.read_text().replace("/opt/hermes-desktop/Hermes", str(fallback)))
    launch = ["bash", str(fallback_launcher)]
    executable.unlink()
    check_launch([url], wayland, ["--ozone-platform=wayland", url])
    (module / "main_desktop.py").write_text('raise ImportError("incomplete Python dependencies")\n')
    check_launch([url], wayland, ["--ozone-platform=wayland", url])
    shutil.rmtree(runtime / "venv")
    check_launch(overrides={"ELECTRON_RUN_AS_NODE": "1", "PYTHONPATH": "/invalid", "PYTHONHOME": "/invalid"})
    check_namespace_failure()

    gate = ["bash", str(destination), "--self-test-gate", "--install-root", str(runtime),
            "--relaunch-target", str(executable)]
    executable.touch()
    executable.chmod(0o755)
    assert subprocess.check_output(gate, env=env, text=True).strip() == "relaunch"
    assert subprocess.check_output(gate, env={**env, "TEST_NAMESPACE_RESULT": "1"}, text=True).startswith("manual:")
    gate[-1] = "/opt/hermes-desktop/Hermes"
    assert subprocess.check_output(gate, env=env, text=True).startswith("skew:")
print("PASS: desktop settings, environment, native/fallback namespace sandbox and updater gate")
