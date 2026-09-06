"""Exercise workflow shell steps. Requires Bash, GNU tar, zstd and PyYAML."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


WORKFLOW = yaml.safe_load(
    (Path(__file__).resolve().parents[1] / ".github/workflows/build-aarch64.yml").read_text()
)
STEPS = {step["id"]: step for step in WORKFLOW["jobs"]["build"]["steps"] if "id" in step}


class BuildAarch64Test(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        package = self.root / "pkgbuilds/example/PKGBUILD"
        package.parent.mkdir(parents=True)
        package.write_text("pkgname=example\n")
        helpers = self.root / "helpers"
        helpers.mkdir()
        shutil.copy(Path(__file__).resolve().parents[1] / "helpers/package-metadata.sh", helpers)

    def run_step(self, name, **env):
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", STEPS[name]["run"]],
            cwd=self.root,
            env={
                **os.environ,
                "ARCH": "aarch64",
                "INPUT_MIRROR": "edge",
                "INPUT_PACKAGES": "",
                "GITHUB_ENV": str(self.root / "env"),
                "GITHUB_OUTPUT": str(self.root / "output"),
                **env,
            },
            capture_output=True,
            text=True,
        )

    def test_empty_package_set_is_valid(self):
        result = self.run_step("meta")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_known_package_and_rc_mirror(self):
        result = self.run_step("meta", INPUT_PACKAGES=" example ", INPUT_MIRROR="rc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PACKAGES=example\n", (self.root / "env").read_text())

    def test_options_paths_unknown_packages_and_newlines_are_rejected(self):
        for value in ("--dry-run", "..", "../example", "missing", "example\ninjected=value"):
            with self.subTest(value=value):
                result = self.run_step("meta", INPUT_PACKAGES=value)
                self.assertNotEqual(result.returncode, 0)

    def test_split_package_is_verified_by_pkgbase(self):
        (self.root / "pkgbuilds/example/PKGBUILD").write_text("pkgbase=example-source\npkgname=(example-libs)\n")
        repo = self.root / "repo"
        desc = repo / "example-libs-1-1/desc"
        desc.parent.mkdir(parents=True)
        desc.write_text("%NAME%\nexample-libs\n\n%BASE%\nexample-source\n")
        subprocess.run(
            ["tar", "--zstd", "-cf", "omarchy.db.tar.zst", desc.parent.name],
            cwd=repo, check=True,
        )
        result = self.run_step("verify", REPO_DIR=str(repo), PACKAGES="example")
        self.assertEqual(result.returncode, 0, result.stderr)
        # A recipe without pkgbase uses pkgname, read for the target architecture.
        (self.root / "pkgbuilds/example/PKGBUILD").write_text(
            '[[ $CARCH == aarch64 ]] || return 1\npkgname=example-source\n'
        )
        result = self.run_step("verify", REPO_DIR=str(repo), PACKAGES="example")
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.root / "pkgbuilds/example/PKGBUILD").write_text("pkgbase=exampl.-source\npkgname=(example-libs)\n")
        result = self.run_step("verify", REPO_DIR=str(repo), PACKAGES="example")
        self.assertNotEqual(result.returncode, 0)

    def test_cache_includes_sources_and_package_selection(self):
        cache = STEPS["cache"]["with"]
        self.assertNotIn("restore-keys", cache)
        self.assertIn("packages_key", cache["key"])
        for path in ("pkgbuilds/**", "build/**", "helpers/**", "bin/**"):
            self.assertIn(path, cache["key"])

    @unittest.skipUnless(shutil.which("makepkg") and shutil.which("repo-add"), "requires Arch packaging tools")
    def test_real_repository_records_pkgbase(self):
        recipe = self.root / "pkgbuilds/example"
        (recipe / "PKGBUILD").write_text('''pkgbase=example-source
pkgname=(example-libs)
pkgver=1
pkgrel=1
arch=(any)
license=(MIT)
package() {
  install -Dm644 "$startdir/PKGBUILD" "$pkgdir/usr/share/example/PKGBUILD"
}
''')
        subprocess.run(["makepkg", "--nodeps", "--noconfirm"], cwd=recipe, check=True,
                       stdout=subprocess.DEVNULL)
        packages = list(recipe.glob("*.pkg.tar.zst"))
        self.assertEqual(len(packages), 1)
        subprocess.run(["repo-add", "omarchy.db.tar.zst", packages[0].name], cwd=recipe,
                       check=True, stdout=subprocess.DEVNULL)
        result = self.run_step("verify", REPO_DIR=str(recipe), PACKAGES="example")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
