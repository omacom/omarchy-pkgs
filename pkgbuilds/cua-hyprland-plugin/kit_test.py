#!/usr/bin/env python3
"""Exercise the kit derivation against Cua's published kit, with tampered inputs.

Usage: kit_test.py ARCHIVE ARCHIVE_SHA256 PROFILE
"""

import importlib._bootstrap_external
import io
import json
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

import kit

ARCHIVE = CHECKSUM = PROFILE = None
# Omarchy's own build of the release the kit supports: a version and bytes the kit has never seen.
HYPRLAND = {"package_version": "0.57.2-2", "sha256": "d" * 64, "headers_sha256": "1" * 64}
RELEASE = "3"


class KitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.srcdir = self.root / "src"
        self.srcdir.mkdir()
        self.profile = json.loads(PROFILE.read_bytes())
        self.installed = dict(HYPRLAND)
        measure = mock.patch.object(kit, "measure", side_effect=lambda verify: dict(self.installed))
        measure.start()
        self.addCleanup(measure.stop)

    def run_kit(self, mode, archive=None, checksum=None, profile=None, release=RELEASE):
        kit.run(mode, archive or ARCHIVE, checksum or CHECKSUM, profile or PROFILE, self.srcdir, release)

    def write_profile(self, value, indent=2):
        path = self.root / "PROFILE.json"
        path.write_text(json.dumps(value, sort_keys=True, indent=indent) + "\n")
        return path

    def test_derives_the_kit_for_the_installed_hyprland(self):
        self.run_kit("extract")
        self.run_kit("check")
        derived = self.srcdir / kit.KIT
        built = json.loads((derived / "PROFILE.json").read_bytes())
        self.assertEqual(built, dict(self.profile, package_release=3, hyprland=dict(self.profile["hyprland"], **HYPRLAND)))
        self.assertEqual(json.loads((derived / "KIT-PROVENANCE.json").read_bytes())["profile_sha256"],
                         kit.sha256((derived / "PROFILE.json").read_bytes()))
        recipe = (derived / "PKGBUILD").read_text()
        self.assertIn("depends=('hyprland=0.57.2-2' ", recipe)
        self.assertIn("\npkgrel=3\n", recipe)
        self.assertTrue((self.srcdir / "cua-hyprland-plugin-0.47.8-87558bfd064787c7839351c55d667dc8244044a4"
                         / "SOURCE-PROVENANCE.json").is_file())

    def test_another_hyprland_release_refuses(self):
        for version in ("0.57.3-1", "0.58.0-1", "1:0.57.2-2", "0.57.2"):
            with self.subTest(version):
                self.installed["package_version"] = version
                with self.assertRaisesRegex(ValueError, "not a build of the release"):
                    self.run_kit("extract")
                shutil.rmtree(self.srcdir)
                self.srcdir.mkdir()

    def test_hyprland_replaced_after_extraction_refuses(self):
        self.run_kit("extract")
        for field, value in (("package_version", "0.57.2-3"), ("sha256", "0" * 64), ("headers_sha256", "0" * 64)):
            with self.subTest(field):
                self.installed = dict(HYPRLAND, **{field: value})
                with self.assertRaisesRegex(ValueError, "differs from derivation"):
                    self.run_kit("check")

    def test_fractional_release_refuses(self):
        with self.assertRaisesRegex(ValueError, "whole number"):
            self.run_kit("extract", release="3.1")

    def test_moved_abi_version_is_admitted(self):
        payload = kit.read_kit(ARCHIVE, CHECKSUM)
        verify = kit.load_verifier(self.root / "profile_verify.py", payload["profile_verify.py"])
        self.profile["runtime"]["packages"]["wayland"] = "1.26.0-2"
        data = self.write_profile(self.profile).read_bytes()
        derived, _ = kit.derive(payload, data, verify, HYPRLAND, RELEASE)
        self.assertEqual(json.loads(derived["PROFILE.json"])["runtime"], self.profile["runtime"])
        self.assertIn(b"'wayland=1.26.0-2'", derived["PKGBUILD"])

    def test_profile_changes_beyond_scope_refuse(self):
        changes = {
            "an extra runtime pin": lambda p: p["runtime"]["packages"].update(mesa="1:26.2.4-1"),
            "a dropped runtime pin": lambda p: p["runtime"]["packages"].pop("libxkbcommon"),
            "a rebuilt compositor": lambda p: p["hyprland"].update(package_version="0.57.2-2"),
            "a changed compositor hash": lambda p: p["hyprland"].update(sha256="0" * 64),
            "a changed header hash": lambda p: p["hyprland"].update(headers_sha256="0" * 64),
            "a changed compiler hash": lambda p: p["compiler"].update(sha256="0" * 64),
            "a changed libstdc++ hash": lambda p: p["runtime"].update(sha256="0" * 64),
            "a changed source": lambda p: p["source"].update(archive_sha256="0" * 64),
        }
        for label, change in changes.items():
            with self.subTest(label):
                profile = json.loads(json.dumps(self.profile))
                change(profile)
                with self.assertRaisesRegex(ValueError, "profile changes more"):
                    self.run_kit("extract", profile=self.write_profile(profile))
                shutil.rmtree(self.srcdir)
                self.srcdir.mkdir()

    def test_noncanonical_profile_refuses(self):
        with self.assertRaisesRegex(ValueError, "canonical"):
            self.run_kit("extract", profile=self.write_profile(self.profile, indent=4))

    def test_tampered_archive_refuses(self):
        data = bytearray(ARCHIVE.read_bytes())
        data[len(data) // 2] ^= 1
        tampered = self.root / ARCHIVE.name
        tampered.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "kit archive checksum"):
            self.run_kit("extract", archive=tampered)

    def test_member_outside_the_checksum_list_refuses(self):
        raw = io.BytesIO()
        with tarfile.open(fileobj=io.BytesIO(ARCHIVE.read_bytes()), mode="r:gz") as source, \
                tarfile.open(fileobj=raw, mode="w:gz") as target:
            for member in source:
                target.addfile(member, source.extractfile(member))
            extra = tarfile.TarInfo("extra.py")
            extra.size = 1
            target.addfile(extra, io.BytesIO(b"\n"))
        repacked = self.root / ARCHIVE.name
        repacked.write_bytes(raw.getvalue())
        with self.assertRaisesRegex(ValueError, "kit inventory"):
            self.run_kit("extract", archive=repacked, checksum=kit.sha256(raw.getvalue()))

    def test_changed_extracted_kit_refuses(self):
        self.run_kit("extract")
        usage = self.srcdir / kit.KIT / "PROFILE-USAGE.md"
        usage.write_bytes(usage.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "differs from derivation"):
            self.run_kit("check")
        usage.write_bytes(usage.read_bytes()[:-1])
        (self.srcdir / kit.KIT / "extra.py").write_text("\n")
        with self.assertRaisesRegex(ValueError, "inventory"):
            self.run_kit("check")

    def test_planted_bytecode_never_runs(self):
        self.run_kit("extract")
        verifier = self.srcdir / kit.KIT / "profile_verify.py"
        marker = self.root / "planted-bytecode-ran"
        code = compile(f"open({str(marker)!r}, 'w').close()\n", str(verifier), "exec")
        stat = verifier.stat()
        cache = verifier.parent / "__pycache__"
        cache.mkdir()
        (cache / f"profile_verify.{sys.implementation.cache_tag}.pyc").write_bytes(
            importlib._bootstrap_external._code_to_timestamp_pyc(code, int(stat.st_mtime), stat.st_size))
        with self.assertRaisesRegex(ValueError, "inventory"):
            self.run_kit("check")
        self.assertFalse(marker.exists())

    def test_reused_destination_refuses(self):
        self.run_kit("extract")
        with self.assertRaisesRegex(ValueError, "fresh destination"):
            self.run_kit("extract")


if __name__ == "__main__":
    ARCHIVE, CHECKSUM, PROFILE = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    unittest.main(argv=sys.argv[:1])
