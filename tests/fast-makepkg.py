#!/usr/bin/env python3
"""Compare helpers/fast-makepkg.sh and bin/release-owners srcinfo_batch
against stock /usr/share/makepkg on real and synthetic recipes."""

import concurrent.futures
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
STOCK_LIB = "/usr/share/makepkg"


def load_release_owners():
    loader = importlib.machinery.SourceFileLoader("release_owners", str(ROOT / "bin" / "release-owners"))
    spec = importlib.util.spec_from_loader("release_owners", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def strip_srcinfo_header(text):
    """Drop the generated timestamp header comments, keeping the SRCINFO body."""
    lines = [line for line in text.splitlines() if not line.startswith("# ")]
    return "\n".join(lines).strip()


def run_printsrcinfo(pkgdir, arch, work, makepkg_lib):
    conf = work / f"makepkg-{arch}.conf"
    env = {
        **os.environ,
        "MAKEPKG_CONF": str(conf),
        "MAKEPKG_LIBRARY": makepkg_lib,
        "CARCH": arch,
    }
    proc = subprocess.run(
        ["makepkg", "--printsrcinfo"],
        cwd=pkgdir,
        env=env,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"makepkg --printsrcinfo failed for {pkgdir} ({arch}, lib={makepkg_lib}): {proc.stderr}"
        )
    return proc.stdout


class FastMakepkgComparisonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ro = load_release_owners()
        cls.tmp = tempfile.TemporaryDirectory(prefix="fast-makepkg-test-")
        cls.work = Path(cls.tmp.name)
        cls.work.chmod(0o755)
        for arch in ("x86_64", "aarch64"):
            cls.ro.srcinfo_conf(arch, cls.work)
        cls.fast_lib = subprocess.check_output(
            ["bash", str(ROOT / "helpers" / "fast-makepkg.sh"), str(cls.work / "libmakepkg")],
            text=True,
        ).strip()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def _assert_matches_stock(self, root_dir, jobs):
        """Compare stock makepkg --printsrcinfo against both the fast overlay
        and release-owners srcinfo_batch for every (name, arch) in jobs."""
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(2, len(jobs))) as pool:
            stock_futs = {
                job: pool.submit(run_printsrcinfo, root_dir / "pkgbuilds" / job[0], job[1], self.work, STOCK_LIB)
                for job in jobs
            }
            fast_futs = {
                job: pool.submit(run_printsrcinfo, root_dir / "pkgbuilds" / job[0], job[1], self.work, self.fast_lib)
                for job in jobs
            }
            stock_out = {job: fut.result() for job, fut in stock_futs.items()}
            fast_out = {job: fut.result() for job, fut in fast_futs.items()}

        orig_root = self.ro.ROOT
        try:
            self.ro.ROOT = root_dir
            batch_out = self.ro.srcinfo_batch(jobs, self.work, self.fast_lib)
        finally:
            self.ro.ROOT = orig_root

        for job in jobs:
            name, arch = job
            stock_body = strip_srcinfo_header(stock_out[job])
            fast_body = strip_srcinfo_header(fast_out[job])
            batch_body = strip_srcinfo_header(batch_out[job])

            self.assertEqual(
                fast_body,
                stock_body,
                f"fast-makepkg overlay diverged from stock makepkg for {name} ({arch})",
            )
            self.assertEqual(
                batch_body,
                stock_body,
                f"release-owners srcinfo_batch diverged from stock makepkg for {name} ({arch})",
            )
            self.assertEqual(
                self.ro.parse_srcinfo(batch_out[job], arch),
                self.ro.parse_srcinfo(stock_out[job], arch),
                f"parse_srcinfo diverged for {name} ({arch})",
            )
        return batch_out

    def test_representative_repo_recipes(self):
        # Representative real split package (hyprland) and CARCH-dependent recipe (1password).
        jobs = [
            ("hyprland", "x86_64"),
            ("1password", "x86_64"),
            ("1password", "aarch64"),
        ]
        self._assert_matches_stock(ROOT, jobs)

    def test_synthetic_edge_cases(self):
        synth_root = self.work / "synth"
        pkgbuilds = synth_root / "pkgbuilds"

        # 1. Split package with top-level helper vars whose names could collide
        #    with libmakepkg locals (key, attr), function-local overrides,
        #    array clearing, and CARCH-dependent attributes.
        split_dir = pkgbuilds / "synth-split"
        split_dir.mkdir(parents=True)
        (split_dir / "PKGBUILD").write_text(
            """pkgbase=synth-split
pkgname=(synth-split-a synth-split-b)
pkgver=1.2.3
pkgrel=1
pkgdesc="Base description"
arch=(x86_64 aarch64)
license=(MIT)
depends=(base-dep)
depends_x86_64=(x86-base-dep)
provides=(base-prov)
provides_aarch64=(arm-base-prov)
key=real-provider
attr=custom-dep
if [[ $CARCH == aarch64 ]]; then
  _arch_tag=arm64-prov
else
  _arch_tag=amd64-prov
fi

package_synth-split-a() {
  pkgdesc="Split A description"
  provides=("$key" "$_arch_tag" "alt-prov=1.0")
  depends=("$attr")
  replaces=(old-split-a)
}

package_synth-split-b() {
  depends=()
  provides=()
  optdepends=("helper: optional helper")
  provides_aarch64=(arm-only-split)
  depends_x86_64=(x86-only-split)
  conflicts=(split-b-conflict)
}
"""
        )

        # 2. Architecture-independent single package.
        any_dir = pkgbuilds / "synth-any"
        any_dir.mkdir(parents=True)
        (any_dir / "PKGBUILD").write_text(
            """pkgname=synth-any
pkgver=2.0
pkgrel=1
pkgdesc="Any-arch package"
arch=(any)
license=(MIT)
provides=(synth-virtual)
replaces=(synth-legacy)
conflicts=(synth-conflict)
"""
        )

        jobs = [
            ("synth-split", "x86_64"),
            ("synth-split", "aarch64"),
            ("synth-any", "x86_64"),
        ]
        batch_out = self._assert_matches_stock(synth_root, jobs)
        self.assertIn("provides = real-provider", batch_out[("synth-split", "x86_64")])
        self.assertIn("provides = amd64-prov", batch_out[("synth-split", "x86_64")])
        self.assertIn("provides = arm64-prov", batch_out[("synth-split", "aarch64")])


if __name__ == "__main__":
    unittest.main()
