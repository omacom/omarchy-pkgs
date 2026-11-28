#!/usr/bin/env python3
"""Unit and integration tests for bin/sync-rebuilds."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "bin" / "sync-rebuilds"


def load_module():
    loader = importlib.machinery.SourceFileLoader("sync_rebuilds", str(SCRIPT))
    spec = importlib.util.spec_from_loader("sync_rebuilds", loader)
    assert spec is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["sync_rebuilds"] = mod
    loader.exec_module(mod)
    return mod


sr = load_module()


def make_db(out: Path, entries: list[tuple[str, str]], *, zstd: bool = True) -> None:
    with tempfile.TemporaryDirectory() as staging:
        stage_dir = Path(staging)
        for name, version in entries:
            pkg_dir = stage_dir / f"{name}-{version}"
            pkg_dir.mkdir(parents=True, exist_ok=True)
            (pkg_dir / "desc").write_text(
                f"%FILENAME%\n{name}-{version}-x86_64.pkg.tar.zst\n\n"
                f"%NAME%\n{name}\n\n"
                f"%BASE%\n{name}\n\n"
                f"%VERSION%\n{version}\n",
                encoding="utf-8",
            )
        cmd = (
            ["tar", "--zstd", "-cf", str(out), "-C", str(stage_dir), "."]
            if zstd
            else ["tar", "-czf", str(out), "-C", str(stage_dir), "."]
        )
        subprocess.run(cmd, check=True)


class FixtureRepo:
    """Throwaway repository root with stubbed pacman and curl for CLI tests."""

    def __init__(self, tmp: Path) -> None:
        self.root = tmp
        self.pkgbuilds = tmp / "pkgbuilds"
        self.stub = tmp / "stub"
        self.pkgbuilds.mkdir(parents=True)
        self.stub.mkdir(parents=True)

    def add_package(
        self,
        name: str,
        pkgrel: str,
        metadata: str | dict,
        *,
        pkgver: str = "1.0",
        arches: str = "x86_64",
        extra_pkgbuild: str = "",
    ) -> Path:
        pkgdir = self.pkgbuilds / name
        (pkgdir / ".omarchy").mkdir(parents=True, exist_ok=True)
        pkgbuild = f"pkgname={name}\npkgver={pkgver}\npkgrel={pkgrel}\narch=({arches})\n"
        if extra_pkgbuild:
            pkgbuild += extra_pkgbuild
        (pkgdir / "PKGBUILD").write_text(pkgbuild, encoding="utf-8")
        meta_text = metadata if isinstance(metadata, str) else json.dumps(metadata) + "\n"
        (pkgdir / ".omarchy" / "package.json").write_text(meta_text, encoding="utf-8")
        return pkgdir

    def set_pacman(self, versions: dict[str, str], repo: str = "extra") -> None:
        lines = [f"{k}={v}" for k, v in versions.items()]
        (self.stub / "versions").write_text("\n".join(lines) + "\n", encoding="utf-8")
        stub = self.stub / "pacman"
        stub.write_text(
            "#!/bin/bash\n"
            '[[ "$1" == "-Si" ]] || exit 1\n'
            'version=$(awk -F= -v p="$2" \'$1 == p { print $2; exit }\' "$(dirname "$0")/versions")\n'
            '[[ -n "$version" ]] || exit 1\n'
            f'printf "Repository      : {repo}\\nName            : %s\\nVersion         : %s\\n\\n" "$2" "$version"\n',
            encoding="utf-8",
        )
        stub.chmod(0o755)

    def set_published(self, entries: list[tuple[str, str]] | None = None) -> None:
        if entries:
            make_db(self.stub / "omarchy.db.tar.zst", entries, zstd=True)
        stub = self.stub / "curl"
        stub.write_text(
            "#!/bin/bash\n"
            'out=""; url=""\n'
            "while [[ $# -gt 0 ]]; do\n"
            '  case "$1" in -o) out="$2"; shift 2 ;; *) url="$1"; shift ;; esac\n'
            "done\n"
            'case "$url" in\n'
            "  */omarchy.db.tar.zst)\n"
            '    channel="${url%/omarchy.db.tar.zst}"\n'
            '    arch="${channel##*/}"\n'
            '    channel="${channel%/*}"\n'
            '    db="$(dirname "$0")/omarchy-${channel##*/}-$arch.db.tar.zst"\n'
            '    [[ -f "$db" ]] || db="$(dirname "$0")/omarchy.db.tar.zst"\n'
            "    ;;\n"
            "  */aarch64/*)\n"
            '    repo="${url%/*}"\n'
            '    db="$(dirname "$0")/alarm-${repo##*/}.db"\n'
            "    ;;\n"
            '  *) db="" ;;\n'
            "esac\n"
            '[[ -f "$db" && -n "$out" ]] || exit 22\n'
            'cp "$db" "$out"\n',
            encoding="utf-8",
        )
        stub.chmod(0o755)

    def set_channel(self, channel: str, arch: str, entries: list[tuple[str, str]]) -> None:
        make_db(self.stub / f"omarchy-{channel}-{arch}.db.tar.zst", entries, zstd=True)

    def set_alarm(self, entries: list[tuple[str, str]]) -> None:
        make_db(self.stub / "alarm-core.db", [("unrelated", "1-1")], zstd=False)
        make_db(self.stub / "alarm-extra.db", entries, zstd=False)

    def run(
        self,
        *args: str,
        ci_arches: str | None = "x86_64",
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PKGBUILDS_DIR"] = str(self.pkgbuilds)
        env["PATH"] = f"{self.stub}:{env['PATH']}"
        if ci_arches is None:
            env.pop("CI_ARCHES", None)
        else:
            env["CI_ARCHES"] = ci_arches
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )


def pkgrel_of(pkgdir: Path) -> str:
    for line in (pkgdir / "PKGBUILD").read_text(encoding="utf-8").splitlines():
        if line.startswith("pkgrel="):
            return line.split("=", 1)[1]
    raise AssertionError("pkgrel not found")


class VersionAndHelperTests(unittest.TestCase):
    def test_version_helpers(self) -> None:
        self.assertEqual(sr.version_pkgver("2.0-1"), "2.0")
        self.assertEqual(sr.version_pkgver("1:1.4.363.0-1"), "1.4.363.0")
        self.assertEqual(sr.version_normalized("0:2.0-1"), "2.0-1")
        self.assertEqual(sr.version_normalized("1:2.0-1"), "1:2.0-1")
        self.assertEqual(sr.version_without_pkgrel("1:1.4.363.0-1"), "1:1.4.363.0")
        self.assertEqual(sr.version_without_pkgrel("0:2.0-1"), "2.0")
        self.assertEqual(sr.version_without_pkgrel("2.44+r78-1.2"), "2.44+r78")

    def test_bump_pkgrel(self) -> None:
        self.assertEqual(sr.bump_pkgrel("1"), "2")
        self.assertEqual(sr.bump_pkgrel("08"), "9")
        self.assertEqual(sr.bump_pkgrel("1.1"), "1.2")
        self.assertEqual(sr.bump_pkgrel("1.09"), "1.10")
        self.assertIsNone(sr.bump_pkgrel("1.2.3"))
        self.assertIsNone(sr.bump_pkgrel("1a"))

    def test_ci_arches_empty_defaults_to_both(self) -> None:
        with mock.patch.dict(os.environ, {"CI_ARCHES": ""}):
            self.assertEqual(sr.get_ci_arches(), ["x86_64", "aarch64"])

    def test_extract_db_entries_rejects_partial_tar_failure(self) -> None:
        with mock.patch.object(
            sr.subprocess,
            "run",
            side_effect=[
                SimpleNamespace(returncode=0, stdout="dep-a-1-1/desc\n"),
                SimpleNamespace(returncode=2, stdout="%NAME%\ndep-a\n%VERSION%\n1-1\n"),
            ],
        ):
            self.assertIsNone(sr.extract_db_entries(Path("/fake.db")))

    def test_rewrite_pkgrel_requires_single_assignment(self) -> None:
        self.assertEqual(
            sr.rewrite_pkgrel_text("pkgname=a\npkgrel=1\n", "2"),
            "pkgname=a\npkgrel=2\n",
        )
        with self.assertRaises(sr.SyncError):
            sr.rewrite_pkgrel_text("pkgname=a\n", "2")
        with self.assertRaises(sr.SyncError):
            sr.rewrite_pkgrel_text("pkgrel=1\npkgrel=2\n", "3")


class RewritePinsUnitTests(unittest.TestCase):
    def test_plus_and_dot_trigger_names_exact_match(self) -> None:
        pkg = (
            "depends_x86_64=('libstdc++=14.2.1' 'g++=14.2.1' 'gtkmm-4.0=4.14.0' "
            "'gtkmm-4X0=4.14.0' 'my-libstdc++=14.2.1' 'libstdc++-static=14.2.1')\n"
        )
        current = {
            "x86_64": {"libstdc++": "15.1.1-1", "g++": "15.1.1-1", "gtkmm-4.0": "4.16.0-1"}
        }
        self.assertEqual(
            sr.rewrite_pins_text(pkg, current),
            "depends_x86_64=('libstdc++=15.1.1' 'g++=15.1.1' 'gtkmm-4.0=4.16.0' "
            "'gtkmm-4X0=4.14.0' 'my-libstdc++=14.2.1' 'libstdc++-static=14.2.1')\n",
        )

    def test_epochs_zero_epoch_pkgrel_and_tilde(self) -> None:
        pkg = (
            "depends_x86_64=('vulkan-headers=1:1.4.300.0' 'dep-zero=1.0' "
            "'dep-rel=1:1.0-1' 'dep-gain=1.0' 'dep-tilde=1.0~rc1')\n"
        )
        current = {
            "x86_64": {
                "vulkan-headers": "1:1.4.363.0-1",
                "dep-zero": "0:2.0-1",
                "dep-rel": "1:2.0-3",
                "dep-gain": "2:1.0-1",
                "dep-tilde": "1.0~rc2-1",
            }
        }
        self.assertEqual(
            sr.rewrite_pins_text(pkg, current),
            "depends_x86_64=('vulkan-headers=1:1.4.363.0' 'dep-zero=2.0' "
            "'dep-rel=1:2.0-3' 'dep-gain=2:1.0' 'dep-tilde=1.0~rc2')\n",
        )

    def test_depends_forms_multiline_comments_and_non_targets(self) -> None:
        pkg = (
            "depends=(\n"
            "  # ABI pin (see #123)\n"
            "  'dep-a=1.0'\n"
            '  "dep-b=1.0"\n'
            "  dep-c=1.0\n"
            "  'dep-a>=1.0'\n"
            "  'dep-a'\n"
            '  "other-dep=$pkgver"\n'
            ")\n"
            "depends+=('dep-a=1.0' \"dep-b=1.0\" dep-c=1.0)\n"
            "depends_x86_64+=('dep-a=1.0')\n"
            "depends_aarch64=('dep-a=1.0')\n"
            "makedepends=('dep-a=1.0')\n"
            "optdepends=('dep-a=1.0: optional')\n"
            "package() {\n"
            "  depends+=('dep-a=1.0')\n"
            "}\n"
        )
        current = {"x86_64": {"dep-a": "2.0-1", "dep-b": "2.1-1", "dep-c": "3.0-1"}}
        expected = (
            "depends=(\n"
            "  # ABI pin (see #123)\n"
            "  'dep-a=2.0'\n"
            '  "dep-b=2.1"\n'
            "  dep-c=3.0\n"
            "  'dep-a>=1.0'\n"
            "  'dep-a'\n"
            '  "other-dep=$pkgver"\n'
            ")\n"
            "depends+=('dep-a=2.0' \"dep-b=2.1\" dep-c=3.0)\n"
            "depends_x86_64+=('dep-a=2.0')\n"
            "depends_aarch64=('dep-a=1.0')\n"
            "makedepends=('dep-a=1.0')\n"
            "optdepends=('dep-a=1.0: optional')\n"
            "package() {\n"
            "  depends+=('dep-a=2.0')\n"
            "}\n"
        )
        self.assertEqual(sr.rewrite_pins_text(pkg, current), expected)

    def test_heredocs_multiple_heredocs_multiline_strings_and_comments(self) -> None:
        pkg = (
            "x=1 # <<EOF\n"
            "msg='\n"
            "depends=('dep-a=1.0')\n"
            "'\n"
            "prepare() {\n"
            '  grep -q foo <<<"foo"\n'
            "  cat <<ONE <<TWO\n"
            "depends=('dep-a=1.0')\n"
            "ONE\n"
            "depends=('dep-a=1.0')\n"
            "TWO\n"
            "  cat <<\\EOF # <<<\n"
            "depends=('dep-a=1.0')\n"
            "EOF\n"
            "  cat <<'QEOF'\n"
            "depends=('dep-a=1.0')\n"
            "QEOF\n"
            '  cat <<"DQEOF"\n'
            "depends=('dep-a=1.0')\n"
            "DQEOF\n"
            "}\n"
            "depends=(\n"
            "  \"$(printf 'other-%s' \\\n"
            "'dep-a=1.0')\"\n"
            ")\n"
            "depends+=('dep-a=1.0')\n"
        )
        expected = pkg.replace("depends+=('dep-a=1.0')\n", "depends+=('dep-a=2.0')\n")
        self.assertEqual(sr.rewrite_pins_text(pkg, {"x86_64": {"dep-a": "2.0-1"}}), expected)

    def test_shared_depends_agreement_conflict_and_partial_coverage(self) -> None:
        pkg = "depends=('dep-a=1.0')\n"
        self.assertEqual(
            sr.rewrite_pins_text(
                pkg, {"x86_64": {"dep-a": "2.0-1"}, "aarch64": {"dep-a": "2.0-2"}}
            ),
            "depends=('dep-a=2.0')\n",
        )
        with self.assertRaises(sr.SyncError):
            sr.rewrite_pins_text(
                "depends=('dep-a=1.0-1')\n",
                {"x86_64": {"dep-a": "2.0-1"}, "aarch64": {"dep-a": "2.0-2"}},
            )
        with self.assertRaises(sr.SyncError):
            sr.rewrite_pins_text(
                pkg, {"x86_64": {"dep-a": "2.0-1"}, "aarch64": {"dep-a": "1.0-1"}}
            )
        with self.assertRaises(sr.SyncError):
            sr.rewrite_pins_text(
                pkg, {"x86_64": {"dep-a": "2.0-1"}}, missing_arch="aarch64"
            )
        self.assertEqual(
            sr.rewrite_pins_text(
                pkg, {"x86_64": {"dep-a": "1.0-2"}}, missing_arch="aarch64"
            ),
            "depends=('dep-a=1.0')\n",
        )


class TransactionalRollbackTests(unittest.TestCase):
    def _make_pkg(self, root: Path, pkg_text: str, meta: dict) -> tuple[Path, Path, Path]:
        pkgdir = root / "pkg"
        (pkgdir / ".omarchy").mkdir(parents=True)
        pkgbuild = pkgdir / "PKGBUILD"
        meta_path = pkgdir / ".omarchy" / "package.json"
        pkgbuild.write_text(pkg_text, encoding="utf-8")
        meta_path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
        return pkgdir, pkgbuild, meta_path

    def test_rollback_when_metadata_replace_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            orig_pkg = "pkgname=pkg\npkgver=1.0\npkgrel=1\narch=(x86_64)\ndepends_x86_64=('dep-a=1.0')\n"
            meta = {"source": "local", "rebuild_on": ["dep-a"], "rebuilt_against": {"x86_64": {"dep-a": "1.0-1"}}}
            pkgdir, pkgbuild, meta_path = self._make_pkg(root, orig_pkg, meta)
            pkgbuild.chmod(0o640)
            orig_meta = meta_path.read_text(encoding="utf-8")

            real_replace = os.replace

            def fail_on_meta(src, dst):
                if Path(dst) == meta_path:
                    raise OSError("simulated metadata rename failure")
                return real_replace(src, dst)

            with mock.patch.object(sr.os, "replace", side_effect=fail_on_meta):
                with self.assertRaises(OSError):
                    sr.apply_package_update(
                        pkgdir, meta, sr.normalize_recorded(meta["rebuilt_against"]),
                        "2", {"x86_64": {"dep-a": "2.0-1"}}, "", temp_dir=root,
                    )

            self.assertEqual(pkgbuild.read_text(encoding="utf-8"), orig_pkg)
            self.assertEqual(stat.S_IMODE(pkgbuild.stat().st_mode), 0o640)
            self.assertEqual(meta_path.read_text(encoding="utf-8"), orig_meta)
            self.assertEqual(list(pkgdir.rglob("*sync-rebuilds*")), [])

    def test_rollback_on_sigterm_immediately_after_pkgbuild_rename(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            orig_pkg = "pkgname=pkg\npkgver=1.0\npkgrel=1\narch=(x86_64)\ndepends_x86_64=('dep-a=1.0')\n"
            meta = {"source": "local", "rebuild_on": ["dep-a"]}
            pkgdir, pkgbuild, meta_path = self._make_pkg(root, orig_pkg, meta)
            orig_meta = meta_path.read_text(encoding="utf-8")

            real_replace = os.replace
            calls = 0

            def interrupt_right_after_first_rename(src, dst):
                nonlocal calls
                calls += 1
                real_replace(src, dst)
                if calls == 1 and Path(dst) == pkgbuild:
                    raise SystemExit(143)

            with mock.patch.object(sr.os, "replace", side_effect=interrupt_right_after_first_rename):
                with self.assertRaises(SystemExit) as ctx:
                    sr.apply_package_update(
                        pkgdir, meta, {}, "2", {"x86_64": {"dep-a": "2.0-1"}}, "", temp_dir=root
                    )
            self.assertEqual(ctx.exception.code, 143)
            self.assertEqual(pkgbuild.read_text(encoding="utf-8"), orig_pkg)
            self.assertEqual(meta_path.read_text(encoding="utf-8"), orig_meta)
            self.assertEqual(list(pkgdir.rglob("*sync-rebuilds*")), [])

    def test_after_metadata_commit_error_keeps_committed_pkgbuild(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            meta = {"source": "local", "rebuild_on": ["dep-a"]}
            pkgdir, pkgbuild, meta_path = self._make_pkg(
                root, "pkgname=pkg\npkgver=1.0\npkgrel=1\narch=(x86_64)\n", meta
            )
            real_replace = os.replace

            def fail_after_meta_lands(src, dst):
                real_replace(src, dst)
                if Path(dst) == meta_path:
                    raise SystemExit(143)

            with mock.patch.object(sr.os, "replace", side_effect=fail_after_meta_lands):
                with self.assertRaises(SystemExit):
                    sr.apply_package_update(
                        pkgdir, meta, {}, "2", {"x86_64": {"dep-a": "2.0-1"}}, "", temp_dir=root
                    )
            self.assertEqual(pkgrel_of(pkgdir), "2")
            self.assertEqual(
                json.loads(meta_path.read_text())["rebuilt_against"]["x86_64"]["dep-a"], "2.0-1"
            )
            self.assertEqual(list(pkgdir.rglob("*sync-rebuilds*")), [])

    def test_function_local_minimum_version_constraint_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            pkg_text = (
                "pkgname=linux-omarchy-dtbs\n"
                "_kernel=linux-omarchy\n"
                "pkgver=7.3\npkgrel=80\narch=(aarch64)\n"
                "package() {\n"
                "  local needs=7.3.6-12\n"
                '  depends=("$_kernel>=$needs" \'systemd-stub-omarchy\')\n'
                "}\n"
            )
            meta = {"source": "local", "rebuild_on": ["linux-omarchy"]}
            pkgdir, pkgbuild, _ = self._make_pkg(root, pkg_text, meta)
            sr.apply_package_update(
                pkgdir, meta, {}, "81", {"aarch64": {"linux-omarchy": "7.3.6-13"}}, "", temp_dir=root
            )
            self.assertEqual(pkgrel_of(pkgdir), "81")
            self.assertIn('depends=("$_kernel>=$needs" \'systemd-stub-omarchy\')', pkgbuild.read_text())

            # Indented heredoc inside package() with old pin must not block valid rebuild
            hd_pkg = (
                "pkgname=t-hd-fn\npkgver=1.0\npkgrel=1\narch=(x86_64)\n"
                "package() {\n"
                "  cat <<'EOF'\n"
                "  depends=('dep-a=1.0')\n"
                "EOF\n"
                "  depends=('dep-a=1.0')\n"
                "}\n"
            )
            hd_meta = {"source": "local", "rebuild_on": ["dep-a"]}
            hd_dir = root / "hd"
            (hd_dir / ".omarchy").mkdir(parents=True)
            (hd_dir / "PKGBUILD").write_text(hd_pkg, encoding="utf-8")
            (hd_dir / ".omarchy/package.json").write_text(json.dumps(hd_meta) + "\n", encoding="utf-8")
            sr.apply_package_update(
                hd_dir, hd_meta, {}, "2", {"x86_64": {"dep-a": "2.0-1"}}, "", temp_dir=root
            )
            self.assertEqual(pkgrel_of(hd_dir), "2")

    def test_shadowed_local_var_and_indexed_depends_fail_closed(self) -> None:
        for snippet in (
            "_pins=('dep-a=2.0')\npackage_pkg-a() {\n  local _pins=('dep-a=1.0')\n  depends=('glibc' \"${_pins[@]}\")\n}\n",
            "package_pkg-a() {\n  depends[0]='dep-a=1.0'\n}\n",
            "package_pkg-a() {\n  depends='dep-a=1.0'\n}\n",
            "package_pkg-a() {\n  depends=\n}\n",
            "_prefix='label>'\npackage_pkg-a() {\n  local _pin='dep-a=1.0'\n  depends=(\"${_prefix#*>}$_pin\")\n}\n",
        ):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                orig_pkg = (
                    "pkgbase=pkg\npkgname=(pkg-a pkg-b)\npkgver=1.0\npkgrel=1\narch=(x86_64)\n"
                    + snippet
                    + "package_pkg-b() { depends=('glibc'); }\n"
                )
                meta = {"source": "local", "rebuild_on": ["dep-a"]}
                pkgdir, pkgbuild, _ = self._make_pkg(root, orig_pkg, meta)
                with self.assertRaises(sr.SyncError):
                    sr.apply_package_update(
                        pkgdir, meta, {}, "2", {"x86_64": {"dep-a": "2.0-1"}}, "", temp_dir=root
                    )
                self.assertEqual(pkgbuild.read_text(encoding="utf-8"), orig_pkg)


class EndToEndCLITests(unittest.TestCase):
    def test_missing_trigger_fresh_optin_unchanged_and_arch_pin_isolation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = FixtureRepo(Path(tmp))
            p_partial = repo.add_package(
                "t-partial",
                "1",
                {
                    "source": "local",
                    "rebuild_on": ["dep-a", "dep-b"],
                    "rebuilt_against": {"dep-a": "1-1"},
                },
            )
            p_fresh = repo.add_package(
                "t-fresh", "1", {"source": "local", "rebuild_on": ["dep-a"]}
            )
            p_curr = repo.add_package(
                "t-current",
                "1",
                {"source": "local", "rebuild_on": ["dep-a"], "rebuilt_against": {"dep-a": "1-1"}},
            )
            p_pins = repo.add_package(
                "t-pins",
                "1",
                {"source": "local", "rebuild_on": ["dep-pin"], "rebuilt_against": {"dep-pin": "1.0-1"}},
                extra_pkgbuild="depends_x86_64=('dep-pin=1.0' 'dep-b')\ndepends_aarch64=('dep-pin=1.0')\n",
            )
            repo.set_pacman({"dep-a": "1-1", "dep-b": "2-2", "dep-pin": "2.0-1"})
            repo.set_published()

            res = repo.run()
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertEqual(pkgrel_of(p_partial), "2")
            self.assertEqual(
                json.loads((p_partial / ".omarchy/package.json").read_text())["rebuilt_against"]["x86_64"]["dep-b"],
                "2-2",
            )
            self.assertEqual(pkgrel_of(p_fresh), "2")
            self.assertEqual(pkgrel_of(p_curr), "1")
            self.assertEqual(pkgrel_of(p_pins), "2")
            pins_text = (p_pins / "PKGBUILD").read_text(encoding="utf-8")
            self.assertIn("depends_x86_64=('dep-pin=2.0' 'dep-b')\n", pins_text)
            self.assertIn("depends_aarch64=('dep-pin=1.0')\n", pins_text)

            # Second run leaves everything untouched
            res2 = repo.run()
            self.assertEqual(res2.returncode, 0)
            self.assertEqual(pkgrel_of(p_pins), "2")

    def test_dry_run_leaves_files_untouched(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = FixtureRepo(Path(tmp))
            pkg = repo.add_package(
                "t-dry",
                "1",
                {"source": "local", "rebuild_on": ["dep-a"], "rebuilt_against": {"dep-a": "1.0-1"}},
                extra_pkgbuild="depends_x86_64=('dep-a=1.0')\n",
            )
            orig_pkg = (pkg / "PKGBUILD").read_text()
            orig_meta = (pkg / ".omarchy/package.json").read_text()
            repo.set_pacman({"dep-a": "2.0-1"})
            repo.set_published()

            res = repo.run("--dry-run")
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertIn("Would bump 1 -> 2", res.stdout)
            self.assertEqual((pkg / "PKGBUILD").read_text(), orig_pkg)
            self.assertEqual((pkg / ".omarchy/package.json").read_text(), orig_meta)

    def test_unreadable_metadata_fails_run_but_processes_healthy_sibling(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = FixtureRepo(Path(tmp))
            repo.add_package("t-broken", "1", '{"source":"local","rebuild_on":["dep-a"')
            repo.add_package("t-bad-trigger", "1", {"source": "local", "rebuild_on": ["dep-a", None]})
            repo.add_package("t-false-trigger", "1", {"source": "local", "rebuild_on": False})
            p_good = repo.add_package("t-good", "1", {"source": "local", "rebuild_on": ["dep-a"]})
            repo.set_pacman({"dep-a": "1-1"})
            repo.set_published()

            res = repo.run()
            self.assertEqual(res.returncode, 1)
            self.assertEqual(pkgrel_of(p_good), "2")

    def test_published_floor_refuses_non_upgrade(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = FixtureRepo(Path(tmp))
            pkg = repo.add_package(
                "t-floor",
                "1",
                {"source": "local", "rebuild_on": ["dep-a"], "rebuilt_against": {"dep-a": "0-0"}},
            )
            repo.set_pacman({"dep-a": "1-1"})
            repo.set_published([("t-floor", "1.0-5")])

            res = repo.run()
            self.assertEqual(res.returncode, 1)
            self.assertEqual(pkgrel_of(pkg), "1")

    def test_aur_synced_package_bumps_dotted_suffix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = FixtureRepo(Path(tmp))
            pkg = repo.add_package(
                "t-aur",
                "3",
                {"source": "aur", "rebuild_on": ["dep-a"], "rebuilt_against": {"dep-a": "0-0"}},
            )
            repo.set_pacman({"dep-a": "1-1"})
            repo.set_published()

            res = repo.run()
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertEqual(pkgrel_of(pkg), "3.1")
            self.assertEqual(
                json.loads((pkg / ".omarchy/package.json").read_text())["pkgrel"]["suffix"], 1
            )

    def test_multiarch_arm_only_and_default_ci_arches(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = FixtureRepo(Path(tmp))
            p_multi = repo.add_package(
                "t-multi",
                "1",
                {"source": "local", "rebuild_on": ["dep-a"], "rebuilt_against": {"dep-a": "1-1"}},
                arches="x86_64 aarch64",
            )
            p_arm_only = repo.add_package(
                "t-arm-only", "1", {"source": "local", "rebuild_on": ["dep-a"]}, arches="aarch64"
            )
            p_x86 = repo.add_package(
                "t-x86",
                "1",
                {"source": "local", "rebuild_on": ["dep-a"], "rebuilt_against": {"dep-a": "1-1"}},
                arches="x86_64",
            )
            repo.set_pacman({"dep-a": "1-1"})
            repo.set_published()
            repo.set_alarm([("dep-a", "2-1")])

            # CI_ARCHES unset defaults to both x86_64 and aarch64
            res = repo.run(ci_arches=None)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertEqual(pkgrel_of(p_multi), "2")
            self.assertEqual(pkgrel_of(p_arm_only), "2")
            self.assertEqual(pkgrel_of(p_x86), "1")
            arm_meta = json.loads((p_arm_only / ".omarchy/package.json").read_text())
            self.assertEqual(arm_meta["rebuilt_against"]["aarch64"]["dep-a"], "2-1")
            self.assertNotIn("x86_64", arm_meta["rebuilt_against"])

    def test_carried_dependency_published_in_flight_and_unreadable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = FixtureRepo(Path(tmp))
            repo.add_package(
                "t-carried", "1.1", {"source": "local"}, pkgver="0.15.1", arches="aarch64"
            )
            p_linked = repo.add_package(
                "t-linked",
                "3",
                {
                    "source": "local",
                    "rebuild_on": ["t-carried"],
                    "rebuilt_against": {
                        "x86_64": {"t-carried": "0.15.1-1"},
                        "aarch64": {"t-carried": "0.15.0-2"},
                    },
                },
                arches="x86_64 aarch64",
            )
            repo.set_pacman({"t-carried": "0.15.1-1"})
            repo.set_published()
            repo.set_alarm([("t-carried", "0.15.1-1")])

            self.assertEqual(repo.run(ci_arches="aarch64").returncode, 1)
            (repo.stub / "omarchy-edge-aarch64.db.tar.zst").write_text("not a db\n")
            self.assertEqual(repo.run(ci_arches="aarch64").returncode, 1)

            repo.set_channel("edge", "aarch64", [("t-carried", "0.15.0-2")])
            self.assertEqual(repo.run(ci_arches="aarch64").returncode, 0)
            self.assertEqual(pkgrel_of(p_linked), "3")

            repo.set_channel("edge", "aarch64", [("t-carried", "0.15.1-1.1")])
            res_ok = repo.run(ci_arches="x86_64 aarch64")
            self.assertEqual(res_ok.returncode, 0, res_ok.stdout + res_ok.stderr)
            self.assertEqual(pkgrel_of(p_linked), "4")
            meta = json.loads((p_linked / ".omarchy/package.json").read_text())
            self.assertEqual(meta["rebuilt_against"]["aarch64"]["t-carried"], "0.15.1-1.1")
            self.assertEqual(repo.run(ci_arches="x86_64 aarch64").returncode, 0)
            self.assertEqual(pkgrel_of(p_linked), "4")

    def test_carch_branch_and_carried_epoch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            pkgdir = Path(tmp) / "t-carch"
            (pkgdir / ".omarchy").mkdir(parents=True)
            (pkgdir / "PKGBUILD").write_text(
                "pkgname=t-carch\n"
                'case "$CARCH" in\n'
                "  x86_64) pkgver=1.0 ;;\n"
                "  aarch64) pkgver=2.0 ;;\n"
                "  *) return 1 ;;\n"
                "esac\n"
                "pkgrel=3\narch=(x86_64 aarch64)\n",
                encoding="utf-8",
            )
            self.assertEqual(sr.read_pkgbuild_fields(pkgdir, "x86_64").pkgver, "1.0")
            self.assertEqual(sr.read_pkgbuild_fields(pkgdir, "aarch64").pkgver, "2.0")
            self.assertIsNone(sr.read_pkgbuild_fields(pkgdir, "armv7h"))

            ep_dir = Path(tmp) / "t-epoch"
            (ep_dir / ".omarchy").mkdir(parents=True)
            (ep_dir / "PKGBUILD").write_text(
                "pkgname=t-epoch\npkgver=0.15.1\npkgrel=1.1\narch=(aarch64)\n",
                encoding="utf-8",
            )
            self.assertEqual(sr.carried_version("aarch64", ep_dir), "0.15.1-1.1")
            with (ep_dir / "PKGBUILD").open("a", encoding="utf-8") as fh:
                fh.write("epoch=0\n")
            self.assertEqual(sr.carried_version("aarch64", ep_dir), "0.15.1-1.1")
            with (ep_dir / "PKGBUILD").open("a", encoding="utf-8") as fh:
                fh.write("epoch=2\n")
            self.assertEqual(sr.carried_version("aarch64", ep_dir), "2:0.15.1-1.1")

    def test_cli_unknown_option_and_no_abbreviations(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = FixtureRepo(Path(tmp))
            repo.set_pacman({})
            repo.set_published()
            self.assertEqual(repo.run("--bogus").returncode, 1)
            self.assertEqual(repo.run("--self").returncode, 1)
            self.assertEqual(repo.run("does-not-exist").returncode, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
