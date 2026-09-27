#!/usr/bin/python3
"""Check runtime/settings pairing with makepkg metadata and pacman's resolver."""

import os
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


RECIPES = Path(__file__).resolve().parents[1] / "pkgbuilds"
PAIRS = (("omarchy", "omarchy-settings"), ("omarchy-dev", "omarchy-settings-dev"))


def srcinfo(recipe):
    result = subprocess.run(
        ["makepkg", "--printsrcinfo", "-D", str(recipe.parent)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, f"makepkg failed for {recipe}: {result.stderr}"
    fields = {}
    for line in result.stdout.splitlines():
        if " = " in line:
            key, value = line.strip().split(" = ", 1)
            fields.setdefault(key, []).append(value)
    assert len(fields.get("pkgname", [])) == 1, recipe
    return fields


def changed_recipe(recipe, destination, field, value):
    destination.mkdir()
    for scriptlet in recipe.parent.glob("*.install"):
        shutil.copy2(scriptlet, destination / scriptlet.name)
    text = recipe.read_text()
    text, count = re.subn(rf"(?m)^{field}=.+$", f"{field}={value}", text)
    assert count == 1, (recipe, field, count)
    copy = destination / "PKGBUILD"
    copy.write_text(text)
    return srcinfo(copy)


def resolved(dependency, package, directory):
    """Install only package metadata in a private DB; pacman -T does no install."""
    db = directory / "db"
    local = db / "local"
    local.mkdir(parents=True)
    config = directory / "pacman.conf"
    config.write_text("[options]\nArchitecture = auto\n")
    subprocess.run(
        ["pacman-db-upgrade", "--config", str(config), "--dbpath", str(db)],
        capture_output=True,
        text=True,
        check=True,
    )
    name = package["pkgname"][0]
    version = f'{package["pkgver"][0]}-{package["pkgrel"][0]}'
    entry = local / f"{name}-{version}"
    entry.mkdir()
    description = f"%NAME%\n{name}\n\n%VERSION%\n{version}\n\n%DESC%\nfixture\n\n%ARCH%\nany\n\n"
    if package.get("provides"):
        description += "%PROVIDES%\n" + "\n".join(package["provides"]) + "\n\n"
    (entry / "desc").write_text(description)
    result = subprocess.run(
        ["pacman", "-T", "--config", str(config), "--dbpath", str(db), dependency],
        capture_output=True,
        text=True,
        check=False,
    )
    assert not result.stderr, result.stderr
    if result.returncode == 0 and not result.stdout:
        return True
    if result.returncode != 0 and result.stdout == dependency + "\n":
        return False
    raise AssertionError(f"pacman -T failed unexpectedly: {result!r}")


def check(label, dependency, package, directory, expected, failures):
    actual = resolved(dependency, package, directory)
    if actual == expected:
        print(f"PASS {label}")
    else:
        failures.append(f"{label}: expected {expected}, got {actual} ({dependency})")


def main():
    recipes = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else RECIPES
    if len(sys.argv) > 2:
        raise SystemExit("usage: passwordless-package-metadata.py [pkgbuilds-directory]")
    if os.geteuid() == 0:
        # makepkg refuses root, including in CI. Expose only these public
        # inputs to nobody; the original checkout may be in a private home.
        account = pwd.getpwnam("nobody")
        with tempfile.TemporaryDirectory(prefix="omarchy-metadata-inputs-") as temporary:
            inputs = Path(temporary)
            inputs.chmod(0o755)
            script = inputs / "test.py"
            script.write_text(Path(__file__).read_text())
            script.chmod(0o644)
            for pair in PAIRS:
                for name in pair:
                    directory = inputs / name
                    directory.mkdir(mode=0o755)
                    for source in [recipes / name / "PKGBUILD", *(recipes / name).glob("*.install")]:
                        target = directory / source.name
                        target.write_bytes(source.read_bytes())
                        target.chmod(0o644)
                    os.chown(directory, account.pw_uid, account.pw_gid)
            result = subprocess.run(
                ["runuser", "-u", "nobody", "--", sys.executable, str(script), str(inputs)],
                cwd=inputs,
                check=False,
            )
        raise SystemExit(result.returncode)
    failures = []
    with tempfile.TemporaryDirectory(prefix="omarchy-package-metadata-") as temporary:
        scratch = Path(temporary)
        metadata = {name: srcinfo(recipes / name / "PKGBUILD") for pair in PAIRS for name in pair}
        for channel, (runtime, settings) in enumerate(PAIRS):
            runtime_info = metadata[runtime]
            settings_info = metadata[settings]
            assert runtime_info["pkgname"] == [runtime] and settings_info["pkgname"] == [settings]
            dependency = [item for item in runtime_info.get("depends", []) if item.split("=", 1)[0] == settings]
            assert len(dependency) == 1, f"{runtime}: expected one dependency on {settings}"
            dependency = dependency[0]
            case = scratch / f"{channel}-current"
            case.mkdir()
            check(f"{runtime}: current pair", dependency, settings_info, case, True, failures)

            next_rel = int(settings_info["pkgrel"][0]) + 1
            raised = changed_recipe(recipes / settings / "PKGBUILD", scratch / f"{channel}-raised-recipe", "pkgrel", next_rel)
            assert raised["pkgver"] == settings_info["pkgver"] and raised["pkgrel"] != settings_info["pkgrel"]
            case = scratch / f"{channel}-raised"
            case.mkdir()
            check(f"{runtime}: independent settings pkgrel increase", dependency, raised, case, True, failures)

            newer = changed_recipe(recipes / settings / "PKGBUILD", scratch / f"{channel}-new-version-recipe", "pkgver", "9999.0")
            assert newer["pkgver"] != settings_info["pkgver"]
            case = scratch / f"{channel}-new-version"
            case.mkdir()
            check(f"{runtime}: different settings pkgver", dependency, newer, case, False, failures)

        stable_dep = [item for item in metadata["omarchy"].get("depends", []) if item.split("=", 1)[0] == "omarchy-settings"]
        assert len(stable_dep) == 1
        assert "omarchy-settings" in metadata["omarchy-settings-dev"].get("provides", [])
        case = scratch / "other-channel-control"
        case.mkdir()
        check("unversioned dev provide resolves unversioned name", "omarchy-settings", metadata["omarchy-settings-dev"], case, True, failures)
        case = scratch / "other-channel"
        case.mkdir()
        check("stable runtime: unversioned dev provide", stable_dep[0], metadata["omarchy-settings-dev"], case, False, failures)

    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
