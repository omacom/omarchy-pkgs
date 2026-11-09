"""Read Pi 4 boot prerequisites and health; never change the machine."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys


def read(path):
  try:
    return path.read_text().rstrip("\0\n")
  except (OSError, UnicodeError):
    return ""


def tokens(path):
  return read(path).split("\0")


def boot_requirements(root=Path("/"), live=False):
  errors = []
  if not (root / "sys/firmware/efi").is_dir():
    errors.append("This integration needs UEFI and Limine. The community U-Boot image needs its own updater.")
  tree = root / "sys/firmware/devicetree/base"
  if "raspberrypi,4-model-b" not in tokens(tree / "compatible"):
    errors.append("Pi 4 Model B Device Tree missing. Select Device Tree mode in the Pi UEFI settings.")
  if live and not any(
    (device / "device/driver").resolve().name == "v3d"
    for device in (root / "sys/class/drm").glob("renderD*")
  ):
    errors.append("No V3D render device. Check the Pi 4 device tree and the kernel before installing.")
  return errors


def installed_kernels(root):
  # kernel-modules-hook restores the running kernel's directory after an
  # upgrade. Only pacman's current package owns the kernel we must boot next.
  kernels = set()
  for record in (root / "var/lib/pacman/local").glob("linux-omarchy-*"):
    if "%NAME%\nlinux-omarchy" not in read(record / "desc").split("\n\n"):
      continue
    for entry in read(record / "files").splitlines():
      match = re.fullmatch(r"usr/lib/modules/([^/]+)/vmlinuz", entry)
      if match:
        kernels.add(root / "usr/lib/modules" / match[1])
  return sorted(kernels)


def kernel_requirements(root=Path("/")):
  errors = []
  kernels = installed_kernels(root)
  if not kernels:
    return ["No installed linux-omarchy kernel. Install the aarch64 kernel with Pi 4 support."]
  for kernel in kernels:
    modules = read(kernel / "modules.dep") + "\n" + read(kernel / "modules.builtin")
    for module in ("vc4", "v3d", "pcie-brcmstb", "sdhci-brcmstb", "raspberrypi"):
      if not re.search(r"/" + re.escape(module) + r"\.ko(?:[.:\s]|$)", modules):
        errors.append(f"{kernel.name}: required module {module} is missing.")
    if not (kernel / "vmlinuz").is_file():
      errors.append(f"{kernel.name}: kernel image is missing.")
  if not (root / "boot/dtbs/linux-omarchy/broadcom/bcm2711-rpi-4-b.dtb").is_file():
    errors.append("The linux-omarchy package has no Pi 4 Model B device tree.")
  return errors


def pe_sections(path):
  """Locate bounded PE sections without loading a whole kernel into memory."""
  with path.open("rb") as stream:
    size = path.stat().st_size
    header = stream.read(64)
    if len(header) != 64 or header[:2] != b"MZ":
      raise ValueError("not a PE image")
    offset = struct.unpack_from("<I", header, 60)[0]
    if offset > size - 24:
      raise ValueError("truncated PE header")
    stream.seek(offset)
    header = stream.read(24)
    if header[:4] != b"PE\0\0" or struct.unpack_from("<H", header, 4)[0] != 0xAA64:
      raise ValueError("not an aarch64 PE image")
    count = struct.unpack_from("<H", header, 6)[0]
    table = offset + 24 + struct.unpack_from("<H", header, 20)[0]
    if count > 96 or table + count * 40 > size:
      raise ValueError("invalid PE section table")
    stream.seek(table)
    sections = {}
    for _ in range(count):
      section = stream.read(40)
      name = section[:8].rstrip(b"\0")
      length, _, raw_size, start = struct.unpack_from("<IIII", section, 8)
      if (name in (b".linux", b".initrd", b".cmdline") and length > raw_size) or start + raw_size > size or name in sections:
        raise ValueError("invalid PE section bounds")
      sections[name] = (start, length)
    return sections


def section_digest(path, section):
  digest = hashlib.sha256()
  with path.open("rb") as stream:
    start, remaining = section
    stream.seek(start)
    while remaining:
      chunk = stream.read(min(remaining, 1024 * 1024))
      if not chunk:
        raise ValueError("truncated PE section")
      digest.update(chunk)
      remaining -= len(chunk)
  return digest.digest()


def boot_files(root=Path("/")):
  """The menu must reference a UKI containing each installed Omarchy kernel."""
  errors = []
  boot = root / "boot"
  loaders = (boot / "EFI/BOOT/BOOTAA64.EFI", boot / "EFI/limine/limine_aa64.efi")
  if not any(path.is_file() and path.stat().st_size for path in loaders):
    errors.append("No aarch64 Limine EFI loader on /boot.")
  images = []
  for value in re.findall(r"^\s*path:\s*boot\(\):(/EFI/Linux/[^\s#]+\.efi)(?:#[^\s]+)?\s*$", read(boot / "limine.conf"), re.MULTILINE | re.IGNORECASE):
    path = (boot / value.lstrip("/")).resolve()
    if not path.is_relative_to(boot.resolve()) or not path.is_file():
      continue
    try:
      sections = pe_sections(path)
      if all(name in sections and sections[name][1] > 0 for name in (b".linux", b".initrd", b".cmdline")):
        images.append(section_digest(path, sections[b".linux"]))
    except (OSError, ValueError):
      continue
  for kernel in installed_kernels(root):
    try:
      with (kernel / "vmlinuz").open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").digest()
      if digest not in images:
        errors.append(f"No complete Limine menu UKI contains {kernel.name}. Rebuild with sudo limine-update before rebooting.")
    except OSError:
      errors.append(f"Cannot read {kernel.name}'s kernel image.")
  return errors


def health(root=Path("/")):
  temperatures = []
  alarms = []
  for zone in (root / "sys/class/thermal").glob("thermal_zone*"):
    if read(zone / "type") == "cpu-thermal":
      value = read(zone / "temp")
      if value.isdigit():
        temperatures.append(int(value))
  for sensor in (root / "sys/class/hwmon").glob("hwmon*"):
    if read(sensor / "name") == "rpi_volt":
      value = read(sensor / "in0_lcrit_alarm")
      if value in ("0", "1"):
        alarms.append(value == "1")
  return {
    "model": read(root / "sys/firmware/devicetree/base/model"),
    "cpu_temperature_millicelsius": max(temperatures, default=None),
    "undervoltage": any(alarms) if alarms else None,
  }


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  mode = parser.add_mutually_exclusive_group()
  mode.add_argument("--json", action="store_true", help="print the health report as JSON")
  mode.add_argument("--live", action="store_true", help=argparse.SUPPRESS)
  mode.add_argument("--setup", action="store_true", help=argparse.SUPPRESS)
  mode.add_argument("--verify", action="store_true", help=argparse.SUPPRESS)
  args = parser.parse_args()
  errors = boot_requirements(live=args.live)
  if args.setup or args.verify:
    errors += kernel_requirements()
  if args.verify:
    mounted = subprocess.run(["/usr/bin/findmnt", "-rn", "-M", "/boot", "-o", "FSTYPE"], capture_output=True, text=True, check=False)
    if mounted.returncode or mounted.stdout.strip() != "vfat":
      errors.append("/boot is not the mounted FAT EFI partition. Mount it and rebuild before rebooting.")
    else:
      errors += boot_files()
  report = health()
  warnings = []
  if report["undervoltage"] is True:
    warnings.append("Kernel under-voltage alarm is active; check the supply and cable.")
  if report["cpu_temperature_millicelsius"] is not None and report["cpu_temperature_millicelsius"] >= 80000:
    warnings.append("CPU temperature is at least 80 C; check cooling.")
  if report["undervoltage"] is None:
    warnings.append("Kernel voltage sensor is unavailable; power health is unknown.")
  report.update(errors=errors, warnings=warnings)
  if args.json:
    print(json.dumps(report, indent=2))
  else:
    for error in errors:
      print(f"Error: {error}", file=sys.stderr)
    for warning in warnings:
      print(f"Warning: {warning}", file=sys.stderr)
    if not errors:
      print("Pi 4 requirements passed." if args.live or args.setup or args.verify else json.dumps(report, indent=2))
  return 1 if errors else 0


if __name__ == "__main__":
  raise SystemExit(main())
