"""Offline boot verification against real PE bytes and a temporary package database."""

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("pi_check", Path(__file__).with_name("check.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class BootFilesTests(unittest.TestCase):
  def setUp(self):
    temporary = tempfile.TemporaryDirectory(prefix="pi-boot-test-")
    self.addCleanup(temporary.cleanup)
    self.root = Path(temporary.name)
    self.kernel = b"current kernel\0payload"
    self.write("boot/EFI/BOOT/BOOTAA64.EFI", b"loader")
    self.write("var/lib/pacman/local/linux-omarchy-1/desc", b"%NAME%\nlinux-omarchy\n\n")
    self.write("var/lib/pacman/local/linux-omarchy-1/files", b"%FILES%\nusr/lib/modules/current/vmlinuz\n")
    self.write("usr/lib/modules/current/vmlinuz", self.kernel)
    self.write("boot/limine.conf", b"/Omarchy\n  path: boot():/EFI/Linux/current.efi\n")

  def write(self, name, data):
    path = self.root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path

  def image(self, linux=None, omit=None, bounds=None):
    # Minimal PE/COFF image: DOS header, ARM64 COFF header, section table,
    # then raw data. Raw alignment padding must not enter the kernel digest.
    sections = [(b".linux", self.kernel if linux is None else linux),
                (b".initrd", b"initramfs"), (b".cmdline", b"root=UUID=test\0")]
    sections = [(name, data) for name, data in sections if name != omit]
    image = bytearray(512)
    image[:2] = b"MZ"
    struct.pack_into("<I", image, 60, 64)
    image[64:68] = b"PE\0\0"
    struct.pack_into("<HH", image, 68, 0xAA64, len(sections))
    for index, (name, data) in enumerate(sections):
      start = len(image)
      image.extend(data + b"\0" * 16)
      entry = 88 + index * 40
      image[entry:entry + 8] = name.ljust(8, b"\0")
      length, raw_size = len(data), len(data) + 16
      if name == b".linux" and bounds == "virtual":
        length = raw_size + 1
      if name == b".linux" and bounds == "file":
        start = 100000
      struct.pack_into("<IIII", image, entry + 8, length, 0, raw_size, start)
    return self.write("boot/EFI/Linux/current.efi", image)

  def assert_missing(self):
    errors = check.boot_files(self.root)
    self.assertEqual(len(errors), 1, errors)
    self.assertIn("No complete Limine menu UKI contains current.", errors[0])

  def test_matching_kernel_with_raw_padding(self):
    self.image()
    self.assertEqual(check.boot_files(self.root), [])

  def test_stale_kernel_even_when_retained_on_disk(self):
    self.write("usr/lib/modules/old/vmlinuz", b"old kernel")
    self.image(linux=b"old kernel")
    self.assert_missing()

  def test_required_sections(self):
    for section in (b".linux", b".initrd", b".cmdline"):
      with self.subTest(section=section):
        self.image(omit=section)
        self.assert_missing()
    for section in (b".initrd", b".cmdline"):
      with self.subTest(empty=section):
        path = self.image()
        data = bytearray(path.read_bytes())
        index = 1 if section == b".initrd" else 2
        struct.pack_into("<I", data, 88 + index * 40 + 8, 0)
        path.write_bytes(data)
        self.assert_missing()

  def test_malformed_section_bounds(self):
    for bounds in ("virtual", "file"):
      with self.subTest(bounds=bounds):
        path = self.image(bounds=bounds)
        with self.assertRaisesRegex(ValueError, "invalid PE section bounds"):
          check.pe_sections(path)
        self.assert_missing()

  def test_menu_hash_suffix(self):
    self.image()
    self.write("boot/limine.conf", b"/Omarchy\n  path: boot():/EFI/Linux/current.efi#" + b"a" * 128 + b"\n")
    self.assertEqual(check.boot_files(self.root), [])


if __name__ == "__main__":
  unittest.main()
