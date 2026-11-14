"""Exercise the installed launcher's contract without running the application."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


LAUNCHER = Path(sys.argv.pop(1)).read_text()


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="stabilitymatrix-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.app = self.root / "system app"
        self.app.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Mock the UID and executable only; all path selection, jq parsing and
        # argument handling run through the actual launcher script.
        self.uid = self.bin / "id"
        self.uid.write_text("#!/bin/sh\nprintf '1000\\n'\n")
        self.uid.chmod(0o755)
        self.output = self.root / "invocation.json"
        executable = self.app / "StabilityMatrix.Avalonia"
        executable.write_text(
            "#!/usr/bin/env python3\nimport json,os,sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['TEST_OUTPUT']).write_text(json.dumps({"
            "'args':sys.argv[1:], 'cwd':os.getcwd(),"
            "'appimage':os.environ.get('APPIMAGE')}))\n"
        )
        executable.chmod(0o755)
        self.launcher = self.root / "launcher"
        self.launcher.write_text(LAUNCHER.replace(
            "app_dir=/opt/stabilitymatrix", f"app_dir='{self.app}'"
        ))
        self.env = {**os.environ, "HOME": str(self.home),
                    "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "TEST_OUTPUT": str(self.output)}
        self.env.pop("XDG_DATA_HOME", None)
        self.env.pop("XDG_CONFIG_HOME", None)

    def run_launcher(self, *args, success=True):
        result = subprocess.run(["bash", str(self.launcher), *args],
                                env=self.env, cwd=self.root,
                                capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            record = json.loads(self.output.read_text())
            self.assertEqual(record["cwd"], str(self.app))
            self.assertEqual(record["appimage"], "/usr/bin/stabilitymatrix")
            return record["args"]
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        return result.stderr

    def library(self, value, config_home=None):
        directory = config_home or self.home / ".config/StabilityMatrix"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / "library.json"
        path.write_text(json.dumps({"LibraryPath": str(value)}))
        return path

    def test_fresh_install_uses_user_storage(self):
        expected = self.home / ".local/share/StabilityMatrix"
        self.assertEqual(self.run_launcher(), ["--data-dir", str(expected)])
        self.assertTrue(expected.is_dir())
        self.assertEqual(list(self.app.iterdir()), [self.app / "StabilityMatrix.Avalonia"])

    def test_xdg_paths_and_saved_library(self):
        config = self.root / "custom config"
        data = self.root / "models with spaces"
        data.mkdir()
        self.env["XDG_CONFIG_HOME"] = str(config)
        path = self.library(data, config / "StabilityMatrix")
        before = path.read_bytes()
        self.assertEqual(self.run_launcher(), ["--data-dir", str(data)])
        self.assertEqual(path.read_bytes(), before)

    def test_xdg_data_default(self):
        self.env["XDG_DATA_HOME"] = str(self.root / "data")
        self.assertEqual(self.run_launcher()[1], str(self.root / "data/StabilityMatrix"))

    def test_relative_xdg_paths_are_ignored(self):
        self.env.update(XDG_DATA_HOME="relative", XDG_CONFIG_HOME="relative")
        self.assertEqual(self.run_launcher()[1], str(self.home / ".local/share/StabilityMatrix"))

    def test_legacy_user_library(self):
        data = self.home / "StabilityMatrix"
        data.mkdir()
        (data / "settings.json").write_text("{}")
        self.assertEqual(self.run_launcher()[1], str(data))

    def test_missing_drive_does_not_create_replacement(self):
        missing = self.root / "unmounted volume"
        self.library(missing)
        self.assertIn("unavailable", self.run_launcher(success=False))
        self.assertFalse(missing.exists())
        self.assertFalse((self.home / ".local/share/StabilityMatrix").exists())

    def test_invalid_saved_json_fails(self):
        path = self.library("/example")
        path.write_text("{broken")
        self.assertIn("Cannot read", self.run_launcher(success=False))
        self.assertEqual(path.read_text(), "{broken")

    def test_relative_saved_path_fails(self):
        self.library("relative-library")
        self.assertIn("Cannot read", self.run_launcher(success=False))

    def test_explicit_data_and_arguments_are_preserved(self):
        path = self.library("/missing")
        path.write_text("broken")
        data = self.root / "custom library"
        uri = "stabilitymatrix://app?text=a b&other=$(false)"
        self.assertEqual(self.run_launcher("--data-dir", str(data), "--uri", uri),
                         ["--data-dir", str(data), "--uri", uri])

    def test_relative_explicit_data_is_resolved_before_chdir(self):
        self.assertEqual(self.run_launcher("--data-dir=relative data"),
                         [f"--data-dir={self.root / 'relative data'}"])

    def test_home_override_reads_its_library(self):
        data = self.root / "other data"
        data.mkdir()
        app_home = self.root / "other home"
        self.library(data, app_home)
        self.assertEqual(self.run_launcher("--home-dir", str(app_home)),
                         ["--data-dir", str(data), "--home-dir", str(app_home)])

    def test_root_launch_is_rejected(self):
        self.uid.write_text("#!/bin/sh\nprintf '0\\n'\n")
        self.assertIn("without sudo", self.run_launcher(success=False))

    def test_missing_directory_argument_is_rejected(self):
        self.assertIn("requires a directory", self.run_launcher("--data-dir", success=False))


if __name__ == "__main__":
    unittest.main()
