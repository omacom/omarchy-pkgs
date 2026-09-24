#!/usr/bin/env python3
"""Removal regression fixtures. No real systemd manager, user home or package is touched."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

# Characters that make systemd's shell_maybe_quote() quote a value, a copy of
# SHELL_NEED_ESCAPE, GLOB_CHARS and the rest of SHELL_NEED_QUOTES in escape.h.
SHELL_NEED_QUOTES = '"\\`$*?[]' + "'()<>|&;!"


def systemd_environment_value(value):
    r"""Return VALUE as ``systemctl show-environment`` would print it.

    print_variable() in systemctl-set-environment.c hands every value to
    shell_maybe_quote(SHELL_ESCAPE_POSIX) quotes special values and uses
    cescape_char() for control bytes.
    """
    if not any(c in SHELL_NEED_QUOTES or c.isspace() or ord(c) < 0x20 or c == "\x7f"
               for c in value):
        return value
    escapes = dict(zip("\a\b\f\n\r\t\v\\'", (r"\a", r"\b", r"\f", r"\n", r"\r", r"\t", r"\v", r"\\", r"\'")))
    return "$'" + "".join(escapes.get(c, f"\\{ord(c):03o}" if ord(c) < 0x20 or c == "\x7f" else c)
                         for c in value) + "'"


class Removal(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="oma-removal-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.runtime = self.root / "runtime"
        self.units = self.home / ".config/systemd/user"
        self.units.mkdir(parents=True)
        self.runtime.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", CALLS=str(self.log))
        self.executable("systemctl", '''#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
case "$*" in
  *show-environment*) [[ -z ${MANAGER_FAIL-} ]] || exit 1
    # print_variable() prints every value the way a shell would read it, so the
    # fixture, not this stub, decides how the value is quoted.
    echo "XDG_CONFIG_HOME=${CONFIG_HOME_RAW-${CONFIG_HOME-}}" ;;
  *property=ExecStart*) echo "${EFFECTIVE-}" ;;
  *property=LoadState*) echo "${LOAD_STATE-loaded}" ;;
  # A unit that failed stays failed after it is stopped, and systemd refuses
  # reset-failed for every other state, reporting the unit as not loaded.
  *property=ActiveState*) echo "${ACTIVE_STATE-inactive}" ;;
  *" reset-failed "*) [[ ${ACTIVE_STATE-inactive} == failed && -z ${RESET_FAIL-} ]] || {
      printf 'Failed to reset failed state of unit: Unit is not loaded.\n' >&2; exit 1; } ;;
  *" stop "*) [[ -z ${STOP_FAIL-} ]] || exit 1 ;;
esac
''')

    def executable(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def online(self):
        sock = socket.socket(socket.AF_UNIX)
        sock.bind(str(self.runtime / "bus"))
        self.addCleanup(sock.close)

    def install(self, app, binary=None):
        unit = self.units / f"{app}.service"
        unit.write_text(f'[Service]\nExecStart="{binary or "/usr/bin/" + app}" --config "{self.home}/config.toml" daemon\n')
        target = self.units / "graphical-session.target.wants"
        target.mkdir(exist_ok=True)
        link = target / unit.name
        link.symlink_to(f"../{unit.name}")
        return unit, link

    def run_remove(self, app):
        self.log.unlink(missing_ok=True)  # Every run is judged on its own calls.
        return subprocess.run(["bash", str(ROOT / f"pkgbuilds/{app}-bin/package-remove"),
                               "--user", app, str(self.home), str(self.runtime)],
                              env=self.env, text=True, capture_output=True)

    def test_logged_out_users_and_data_preservation(self):
        for app in ("omawake", "omaspeak"):
            unit, link = self.install(app)
            config = self.home / f"{app}.toml"
            config.write_text("keep settings and models")
            result = self.run_remove(app)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(unit.exists())
            self.assertFalse(link.is_symlink())
            self.assertEqual(config.read_text(), "keep settings and models")
        self.assertFalse(self.log.exists(), "offline cleanup contacted systemd")

    def test_active_unit_is_stopped_before_removing_it(self):
        self.online()
        for app in ("omawake", "omaspeak"):
            unit, link = self.install(app)
            self.env["EFFECTIVE"] = f"{{ path=/usr/bin/{app} ; argv[]=/usr/bin/{app} daemon ; }}"
            result = self.run_remove(app)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(unit.exists())
            self.assertFalse(link.is_symlink())
            calls = self.log.read_text().splitlines()
            self.assertLess(calls.index(f"--user stop {app}.service"), calls.index(f"--user disable {app}.service"))
            self.assertEqual(calls[-1], "--user daemon-reload")

    def test_failed_stop_prevents_unit_deletion_and_fails_hook(self):
        self.online()
        unit, link = self.install("omawake")
        self.env.update(STOP_FAIL="1", EFFECTIVE="{ path=/usr/bin/omawake ; }")
        result = self.run_remove("omawake")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(unit.exists())
        self.assertTrue(link.is_symlink())
        self.assertNotIn("disable", self.log.read_text())

    def test_reset_failed_is_requested_only_for_a_unit_that_failed(self):
        self.online()
        for app in ("omawake", "omaspeak"):
            unit, link = self.install(app)
            self.env["EFFECTIVE"] = f"{{ path=/usr/bin/{app} ; argv[]=/usr/bin/{app} daemon ; }}"
            # A loaded unit that never failed is not failed, and asking systemd to
            # reset it fails with "Unit is not loaded": that must not abort removal.
            self.env["ACTIVE_STATE"] = "active"
            result = self.run_remove(app)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [call for call in self.log.read_text().splitlines() if call.startswith("--user")]
            self.assertNotIn(f"--user reset-failed {app}.service", calls)
            # Reading the manager's state is welcome; the only changes asked for
            # are the stop, the disable and the reload that follow them.
            self.assertEqual([call for call in calls
                              if "show-environment" not in call and "--property=" not in call],
                             [f"--user stop {app}.service",
                              f"--user disable {app}.service", "--user daemon-reload"])
            self.assertFalse(unit.exists())
            self.assertFalse(link.is_symlink())

            # A unit that failed does keep that state once stopped, and there the
            # reset belongs between stopping the service and disabling the unit.
            unit, link = self.install(app)
            self.env["ACTIVE_STATE"] = "failed"
            result = self.run_remove(app)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = self.log.read_text().splitlines()
            reset = f"--user reset-failed {app}.service"
            self.assertIn(reset, calls)
            self.assertLess(calls.index(f"--user stop {app}.service"), calls.index(reset))
            self.assertLess(calls.index(reset), calls.index(f"--user disable {app}.service"))
            self.assertFalse(unit.exists())
            self.assertFalse(link.is_symlink())
        del self.env["ACTIVE_STATE"]

    def test_reset_refused_by_a_healthy_manager_still_fails_the_transaction(self):
        self.online()
        unit, link = self.install("omaspeak")
        self.env.update(EFFECTIVE="{ path=/usr/bin/omaspeak ; }",
                        ACTIVE_STATE="failed", RESET_FAIL="1")
        result = self.run_remove("omaspeak")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(unit.exists())
        self.assertTrue(link.is_symlink())

    def test_custom_build_and_mask_are_preserved(self):
        unit, link = self.install("omawake", "/home/user/dev/omawake")
        self.assertEqual(self.run_remove("omawake").returncode, 0)
        self.assertTrue(unit.exists())
        self.assertTrue(link.is_symlink())
        unit.unlink()
        unit.symlink_to("/dev/null")
        self.assertEqual(self.run_remove("omawake").returncode, 0)
        self.assertTrue(unit.is_symlink())
        self.assertFalse(self.log.exists())

    def test_effective_override_and_missing_online_unit(self):
        self.online()
        unit, _ = self.install("omaspeak")
        self.env["EFFECTIVE"] = "{ path=/home/user/development/omaspeak ; }"
        self.assertEqual(self.run_remove("omaspeak").returncode, 0)
        self.assertTrue(unit.exists())
        self.assertNotIn(" stop ", self.log.read_text())
        unit.unlink()
        self.env.update(EFFECTIVE="", LOAD_STATE="not-found")
        self.assertEqual(self.run_remove("omaspeak").returncode, 0)
        self.assertNotIn(" stop ", self.log.read_text())

    def test_manager_config_home_and_unavailable_manager(self):
        self.online()
        default = self.units
        self.units = self.home / "custom-config/systemd/user"
        self.units.mkdir(parents=True)
        unit, link = self.install("omawake")
        self.env.update(CONFIG_HOME=str(self.home / "custom-config"), MANAGER_FAIL="1")
        self.assertNotEqual(self.run_remove("omawake").returncode, 0)
        self.assertTrue(unit.exists())
        del self.env["MANAGER_FAIL"]
        self.assertEqual(self.run_remove("omawake").returncode, 0)
        self.assertFalse(unit.exists())
        self.assertFalse(link.is_symlink())
        self.assertTrue(default.exists())

    def test_root_dispatch_drops_privileges_and_propagates_failure(self):
        passwd = f"fixture:x:12345:12345::{self.home}:/bin/bash"
        self.executable("getent", f"#!/bin/sh\nprintf '%s\\n' '{passwd}'\n")
        self.executable("runuser", '#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\nexit 1\n')
        result = subprocess.run(["bash", str(ROOT / "pkgbuilds/omawake-bin/package-remove"), "omawake"], env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("-u fixture -- env", self.log.read_text())
        self.assertIn("--user omawake", self.log.read_text())

    def test_offline_executable_overrides_are_preserved(self):
        for app in ("omawake", "omaspeak"):
            for spacing in ("ExecStart=\nExecStart={command}",
                           # systemd's parser throws the whitespace around an
                           # assignment away, so both of these spellings still
                           # name a development build, exactly as the first does.
                           "ExecStart =\nExecStart = {command}",
                           "\tExecStart\t=\t{command}"):
                unit, link = self.install(app)
                dropins = Path(str(unit) + ".d")
                dropins.mkdir(exist_ok=True)
                (dropins / "override.conf").write_text("[Service]\n" + spacing.format(
                    command=f"/home/user/build/{app} daemon") + "\n")
                try:
                    with self.subTest(app=app, spacing=spacing):
                        self.assertEqual(self.run_remove(app).returncode, 0)
                        self.assertTrue(unit.exists(), "removed a service with an override")
                        self.assertTrue(link.is_symlink(), "unlinked a service with an override")
                finally:
                    unit.unlink(missing_ok=True)
                    link.unlink(missing_ok=True)
        self.assertFalse(self.log.exists(), "offline cleanup contacted systemd")

    def test_shell_quoted_manager_config_home_is_resolved(self):
        self.online()
        default_units = self.units
        for app in ("omawake", "omaspeak"):
            config_home = self.home / f"{app} custom's \\ config"
            self.units = config_home / "systemd/user"
            self.units.mkdir(parents=True)
            unit, link = self.install(app)
            # A unit in the directory the manager reads nothing from is no unit of
            # the manager's, and the helper has no business reaching for it.
            stray = default_units / f"{app}.service"
            stray.write_text(f'[Service]\nExecStart="/usr/bin/{app}" daemon\n')
            printed = self.env["CONFIG_HOME_RAW"] = systemd_environment_value(str(config_home))
            with self.subTest(app=app, printed=printed):
                self.assertTrue(printed.startswith("$'") and printed.endswith("'"),
                                "a path of spaces is not what a plain value looks like")
                result = self.run_remove(app)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(unit.exists())
                self.assertFalse(link.is_symlink())
                self.assertTrue(stray.is_file(), "guessed at a directory no manager reads")
        del self.env["CONFIG_HOME_RAW"]

    def test_control_character_manager_config_home_is_resolved(self):
        self.online()
        for app in ("omawake", "omaspeak"):
            for suffix in ("tab\tpath", "newline\npath\n", "\a\b\f\r\v", "\x01\x1b\x7f"):
                config_home = self.home / (app + suffix)
                self.units = config_home / "systemd/user"
                self.units.mkdir(parents=True)
                unit, link = self.install(app)
                self.env["CONFIG_HOME_RAW"] = systemd_environment_value(str(config_home))
                with self.subTest(app=app, suffix=suffix):
                    result = self.run_remove(app)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(unit.exists())
                    self.assertFalse(link.is_symlink())

    def test_unreadable_manager_config_home_aborts_the_cleanup(self):
        self.online()
        for app in ("omawake", "omaspeak"):
            unit, link = self.install(app)
            # Truncated output must not make cleanup guess at a directory.
            self.env["CONFIG_HOME_RAW"] = "$'" + str(self.home / f"broken {app} config")
            with self.subTest(app=app):
                result = self.run_remove(app)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(unit.exists())
                self.assertTrue(link.is_symlink())
                self.assertNotIn(" stop ", self.log.read_text())
        del self.env["CONFIG_HOME_RAW"]

    def test_relative_manager_config_home_keeps_the_default_directory(self):
        self.online()
        for app in ("omawake", "omaspeak"):
            unit, link = self.install(app)
            # An XDG_CONFIG_HOME that is not absolute is no setting at all: the
            # manager itself reads the home's .config directory then.
            self.env["CONFIG_HOME_RAW"] = systemd_environment_value(f"relative {app} config")
            with self.subTest(app=app):
                result = self.run_remove(app)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(unit.exists())
                self.assertFalse(link.is_symlink())
        del self.env["CONFIG_HOME_RAW"]

    def test_packaging_installs_hooks_and_helpers(self):
        import shutil
        for app, version in (("omawake", "0.0.3"), ("omaspeak", "0.0.3")):
            source = self.root / app / "src"
            package = self.root / app / "pkg"
            release = source / f"{app}-{version}-linux-x86_64"
            release.mkdir(parents=True)
            for path in [app, "lib/libaudiocpp.so.0.1.0", f"packaging/systemd/{app}.service",
                         "README.md", "INSTALL.md", "ACCELERATOR_SETUP.md", "CHANGELOG.md",
                         "RELEASE_NOTES.md", "DEMO.md", "RUNTIME.md", "config.example.toml",
                         "licenses/LICENSE", "assets/fixture", "benchmarks/fixture"]:
                target = release / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("fixture")
            directory = ROOT / f"pkgbuilds/{app}-bin"
            for name in ("package-remove", "remove-user-services.hook"):
                shutil.copyfile(directory / name, source / name)
            env = dict(self.env, srcdir=str(source), pkgdir=str(package), CARCH="x86_64")
            result = subprocess.run(["bash", "-c", 'source "$1"; package', "package-fixture", str(directory / "PKGBUILD")], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            helper = package / f"usr/lib/{app}/package-remove"
            self.assertEqual(helper.read_bytes(), (directory / "package-remove").read_bytes())
            self.assertEqual(helper.stat().st_mode & 0o777, 0o755)
            self.assertTrue((package / f"usr/share/libalpm/hooks/30-{app}-remove-user-services.hook").exists())

    def test_hook_contract_and_package_release(self):
        scripts = []
        for app in ("omawake", "omaspeak"):
            directory = ROOT / f"pkgbuilds/{app}-bin"
            hook = (directory / "remove-user-services.hook").read_text()
            self.assertIn("Operation = Remove", hook)
            self.assertNotIn("Operation = Upgrade", hook)
            self.assertIn("When = PreTransaction", hook)
            self.assertIn("AbortOnFail", hook)
            self.assertIn(f"Exec = /usr/lib/{app}/package-remove {app}", hook)
            release = next(
                line for line in (directory / "PKGBUILD").read_text().splitlines()
                if line.startswith("pkgrel=")
            )
            self.assertGreaterEqual(int(release.removeprefix("pkgrel=")), 4)
            scripts.append((directory / "package-remove").read_bytes())
        self.assertEqual(*scripts)


if __name__ == "__main__":
    unittest.main()
