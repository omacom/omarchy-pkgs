#!/usr/bin/env python3
"""Benign, offline package identity fixtures for package-scope.py."""
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "helpers/package-scope.py"


@unittest.skipUnless(shutil.which("bsdtar") and shutil.which("zstd"), "requires bsdtar and zstd")
class ScopeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.policies = self.root / "policies"
        self.output = self.root / "output"
        self.output.mkdir()
        self.list = self.root / "files"
        self.manifest = self.root / "manifest.json"
        self.set_policy("tool")

    def set_policy(self, package, artifacts=None):
        path = self.policies / package / ".omarchy/package.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        content = {"source": "local", "description": "unrelated"}
        if artifacts is not None:
            content["artifacts"] = artifacts
        path.write_text(json.dumps(content))
        return path

    def archive(self, pkg="tool", base="tool", version="1:2.3.4-1", arch="x86_64", lines=None, filename=None, marker=None):
        filename = filename or f"{pkg}-{version}-{arch}.pkg.tar.zst"
        info = lines if lines is not None else [f"pkgname = {pkg}", f"pkgbase = {base}", f"pkgver = {version}", f"arch = {arch}"]
        raw = ("\n".join(info) + "\n").encode()
        tar = io.BytesIO()
        with tarfile.open(fileobj=tar, mode="w") as stream:
            entry = tarfile.TarInfo(".PKGINFO")
            entry.size = len(raw)
            stream.addfile(entry, io.BytesIO(raw))
            if marker is not None:
                note = marker.encode()
                entry = tarfile.TarInfo(".BUILDINFO")
                entry.size = len(note)
                stream.addfile(entry, io.BytesIO(note))
        archive = self.output / filename
        with archive.open("wb") as dest:
            subprocess.run(["zstd", "-q", "-c"], input=tar.getvalue(), stdout=dest, check=True)
        return filename

    def run_helper(self, *args, ok=True):
        result = subprocess.run([sys.executable, str(HELPER), *map(str, args)], text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual(result.stdout, "")
        return result

    def create(self, package="tool", names=None, ok=True):
        self.list.write_text("".join(name + "\n" for name in (names or [])))
        result = self.run_helper("create", "--policy-root", self.policies, "--package", package,
                                 "--arch", "x86_64", "--directory", self.output, "--files", self.list, ok=ok)
        if ok:
            self.manifest.write_text(result.stdout)
            return json.loads(result.stdout)
        return result.stderr

    def verify(self, ok=True, extra=False):
        args = ["verify", "--policy-root", self.policies, "--arch", "x86_64", "--directory", self.output,
                "--manifest", self.manifest]
        if extra:
            args.append("--allow-extra")
        return self.run_helper(*args, ok=ok)

    def test_default_epoch_and_any(self):
        filename = self.archive(arch="any")
        manifest = self.create(names=[filename])
        artifact = manifest["jobs"][0]["artifacts"][0]
        self.assertEqual((manifest["version"], manifest["target_arch"]), (1, "x86_64"))
        self.assertEqual(artifact["pkgver"], "1:2.3.4-1")
        self.assertEqual(self.verify().stdout, filename + "\n")
        path = self.policies / "tool/.omarchy/package.json"
        data = json.loads(path.read_text()); data["description"] = "changed unrelated metadata"
        path.write_text(json.dumps(data))
        self.assertEqual(self.verify().stdout, filename + "\n")

    def test_split_and_optional_debug(self):
        self.set_policy("recipe", {"pkgbase": "base", "packages": ["alpha", "beta"]})
        names = [self.archive(pkg=pkg, base="base") for pkg in ("alpha", "beta", "base-debug")]
        manifest = self.create("recipe", names)
        self.assertEqual(manifest["jobs"][0]["packages"], ["alpha", "beta"])
        self.assertEqual(self.verify().stdout.splitlines(), names)

    def test_missing_primary_and_version_mismatch(self):
        self.set_policy("recipe", {"pkgbase": "base", "packages": ["alpha", "beta"]})
        alpha = self.archive("alpha", "base")
        self.assertIn("missing primary", self.create("recipe", [alpha], ok=False))
        beta = self.archive("beta", "base", version="2-1")
        self.assertIn("inconsistent version", self.create("recipe", [alpha, beta], ok=False))

    def test_undeclared_and_unlisted_archives(self):
        good = self.archive()
        bad = self.archive("surprise")
        self.assertIn("unexpected", self.create(names=[good], ok=False))
        self.assertIn("undeclared", self.create(names=[good, bad], ok=False))
        bad_path = self.output / bad
        bad_path.unlink()
        self.create(names=[good])
        self.archive("surprise")
        self.assertIn("unexpected", self.verify(ok=False).stderr)
        self.assertEqual(self.verify(extra=True).stdout, good + "\n")

    def test_symlink_hash_and_policy_changes(self):
        good = self.archive()
        self.create(names=[good])
        path = self.output / good
        original = path.read_bytes()
        path.unlink()
        path.symlink_to(self.root / "elsewhere")
        self.assertNotEqual(self.verify(ok=False).stderr, "")
        path.unlink(); self.archive(marker="benign changed build metadata")
        self.assertIn("archive changed", self.verify(ok=False).stderr)
        path.write_bytes(original)
        self.set_policy("tool", {"pkgbase": "tool", "packages": ["tool", "other"]})
        self.assertIn("changed policy", self.verify(ok=False).stderr)

    def test_malformed_metadata_and_filenames(self):
        for lines in (["pkgname = tool", "pkgname = tool", "pkgbase = tool", "pkgver = 1-1", "arch = x86_64"],
                      ["pkgname = tool", "pkgbase = tool", "pkgver = 1-1"],
                      ["pkgname = tool", "pkgbase = tool", "pkgver = 1/2-1", "arch = x86_64"]):
            filename = self.archive(version="1-1", lines=lines)
            self.create(names=[filename], ok=False)
            (self.output / filename).unlink()
        filename = self.archive(version="1-1", filename="renamed-1-1-x86_64.pkg.tar.zst")
        self.assertIn("filename", self.create(names=[filename], ok=False))

    def test_duplicate_json_keys_and_merge(self):
        filename = self.archive()
        self.create(names=[filename])
        second = self.root / "second.json"
        second.write_text(self.manifest.read_text())
        self.run_helper("merge", "--manifest", self.manifest, "--manifest", second, ok=False)
        result = self.run_helper("merge", "--manifest", self.manifest)
        self.assertEqual(json.loads(result.stdout)["jobs"][0]["package"], "tool")
        self.manifest.write_text(self.manifest.read_text().replace('"version":1', '"version":1,"version":1'))
        self.assertIn("duplicate JSON key", self.verify(ok=False).stderr)
        policy = self.policies / "tool/.omarchy/package.json"
        policy.write_text('{"source":"local","source":"local"}')
        self.assertIn("duplicate JSON key", self.create(names=[filename], ok=False))

    def test_merge_distinct_jobs_and_verify_whole_directory(self):
        first = self.archive()
        self.create(names=[first])
        first_manifest = self.root / "first.json"
        first_manifest.write_bytes(self.manifest.read_bytes())
        first_bytes = (self.output / first).read_bytes()
        (self.output / first).unlink()
        self.set_policy("second")
        second = self.archive(pkg="second", base="second")
        self.create("second", [second])
        (self.output / first).write_bytes(first_bytes)
        merged = self.run_helper("merge", "--manifest", first_manifest, "--manifest", self.manifest)
        self.manifest.write_text(merged.stdout)
        self.assertEqual(self.verify().stdout.splitlines(), [first, second])

    def test_list_validation(self):
        filename = self.archive()
        self.assertIn("duplicate", self.create(names=[filename, filename], ok=False))
        self.assertIn("invalid archive basename", self.create(names=["../" + filename], ok=False))

    def test_explicit_null_policy_and_missing_pkgbase(self):
        filename = self.archive(lines=["pkgname = tool", "pkgver = 1-1", "arch = x86_64"], version="1-1")
        self.create(names=[filename])
        policy = self.policies / "tool/.omarchy/package.json"
        policy.write_text('{"artifacts":null}')
        self.assertIn("invalid artifacts policy", self.create(names=[filename], ok=False))
        self.set_policy("tool", {"pkgbase": "tool", "packages": ["tool"]})
        self.assertIn("pkgbase mismatch", self.create(names=[filename], ok=False))


if __name__ == "__main__":
    unittest.main()
