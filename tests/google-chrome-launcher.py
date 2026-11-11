#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise the packaged entry point without launching Chrome."""
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

LAUNCHER = Path(__file__).resolve().parents[1] / "pkgbuilds/google-chrome/google-chrome-stable.py"


class LauncherTest(unittest.TestCase):
    def launch(self, flags=None, env_flags="", xdg=True):
        with tempfile.TemporaryDirectory(prefix="chrome flags ") as home:
            config = Path(home) / ("custom config" if xdg else ".config")
            config.mkdir()
            if flags is not None:
                (config / "chrome-flags.conf").write_text(flags)
            env = {"HOME": home, "CHROME_USER_FLAGS": env_flags}
            if xdg:
                env["XDG_CONFIG_HOME"] = str(config)
            with patch.dict(os.environ, env, clear=True), patch("sys.argv", [str(LAUNCHER), "--new-window", "https://example.test/a b"]), patch("os.execv") as execute:
                runpy.run_path(str(LAUNCHER), run_name="__main__")
                return execute.call_args.args

    def test_quotes_comments_and_cli_arguments(self):
        executable, argv = self.launch('# comment\n"--user-agent=Mozilla/5.0 (Linux; Android) Mobile"\n--ozone-platform=wayland # inline\n--name="two words"\n')
        self.assertEqual(executable, "/opt/google/chrome/google-chrome")
        self.assertEqual(argv, [executable, "--user-agent=Mozilla/5.0 (Linux; Android) Mobile", "--ozone-platform=wayland", "--name=two words", "--new-window", "https://example.test/a b"])

    def test_shell_code_and_globs_are_literal(self):
        _, argv = self.launch("'--value=$(touch sentinel)' '--other=`id`' '*.desktop' '--hash=#value'\n")
        self.assertEqual(argv[1:-2], ["--value=$(touch sentinel)", "--other=`id`", "*.desktop", "--hash=#value"])

    def test_environment_fallback_and_default_config(self):
        _, argv = self.launch(env_flags="'--name=two words'")
        self.assertEqual(argv[1], "--name=two words")
        _, argv = self.launch('--name="home config"', xdg=False)
        self.assertEqual(argv[1], "--name=home config")

    def test_empty_file_overrides_environment(self):
        _, argv = self.launch("", env_flags="--disable-gpu")
        self.assertEqual(argv[1:], ["--new-window", "https://example.test/a b"])

    def test_malformed_quoting_does_not_launch(self):
        with self.assertRaisesRegex(SystemExit, "Cannot read Chrome flags"):
            self.launch('"--user-agent=unterminated')


if __name__ == "__main__":
    unittest.main()
