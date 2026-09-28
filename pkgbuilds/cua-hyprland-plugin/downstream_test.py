#!/usr/bin/env python3
"""Exercise downstream integrity with real patch application and tampering."""

import hashlib
from pathlib import Path
import tempfile
import unittest

import downstream


class DownstreamTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.pristine = self.root / "pristine"
        self.pristine.mkdir()
        (self.pristine / "SOURCE-PROVENANCE.json").write_text("upstream\n")
        (self.pristine / "input.cpp").write_text("old\n")
        self.patch = self.root / "change.patch"
        self.patch.write_text("--- a/input.cpp\n+++ b/input.cpp\n@@ -1 +1 @@\n-old\n+new\n")
        self.source = self.root / "patched"
        self.manifest = {
            "schema": 1,
            "patch_sha256": downstream.digest(self.patch),
            "upstream_manifest_sha256": downstream.digest(self.pristine / "SOURCE-PROVENANCE.json"),
            "files": {"SOURCE-PROVENANCE.json": downstream.digest(self.pristine / "SOURCE-PROVENANCE.json"),
                      "input.cpp": hashlib.sha256(b"new\n").hexdigest()},
        }

    def test_applies_patch_without_changing_upstream(self):
        downstream.verify_inputs(self.pristine, self.patch, self.manifest)
        downstream.prepare(self.pristine, self.source, self.patch, self.manifest)
        self.assertEqual((self.pristine / "input.cpp").read_text(), "old\n")
        self.assertEqual((self.source / "input.cpp").read_text(), "new\n")

    def test_changed_patch_refuses(self):
        self.patch.write_text(self.patch.read_text().replace("+new", "+bad"))
        with self.assertRaisesRegex(ValueError, "patch checksum"):
            downstream.verify_inputs(self.pristine, self.patch, self.manifest)

    def test_changed_base_manifest_refuses(self):
        (self.pristine / "SOURCE-PROVENANCE.json").write_text("different\n")
        with self.assertRaisesRegex(ValueError, "base manifest"):
            downstream.verify_inputs(self.pristine, self.patch, self.manifest)

    def test_tampered_missing_and_extra_files_refuse(self):
        downstream.prepare(self.pristine, self.source, self.patch, self.manifest)
        file = self.source / "input.cpp"
        for content in ("tampered\n", None):
            if content is None:
                file.unlink()
            else:
                file.write_text(content)
            with self.assertRaisesRegex(ValueError, "inventory/checksum"):
                downstream.verify_tree(self.source, self.manifest)
        file.write_text("new\n")
        (self.source / "unexpected.cpp").write_text("extra\n")
        with self.assertRaisesRegex(ValueError, "inventory/checksum"):
            downstream.verify_tree(self.source, self.manifest)

    def test_symlink_and_reused_destination_refuse(self):
        downstream.prepare(self.pristine, self.source, self.patch, self.manifest)
        with self.assertRaisesRegex(ValueError, "fresh destination"):
            downstream.prepare(self.pristine, self.source, self.patch, self.manifest)
        file = self.source / "input.cpp"
        file.unlink()
        file.symlink_to(self.pristine / "input.cpp")
        with self.assertRaisesRegex(ValueError, "nonregular"):
            downstream.verify_tree(self.source, self.manifest)


if __name__ == "__main__":
    unittest.main()
