#!/usr/bin/env python3
"""Check native CVS selection with the kernel's real conf and I2C Kconfig.

Usage: native-cvs-config.py PREPARED_KERNEL_TREE [--conf CONF_BINARY]
The tree must include patch 0031. An unpatched tree fails the first case.
Only temporary configuration files are written; no kernel build is started.
"""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def config_block(text, name):
    start = text.index(f"config {name}\n")
    following = text.find("\nconfig ", start + 1)
    menu = text.find("\nmenu ", start + 1)
    ends = [position for position in (following, menu) if position != -1]
    return text[start:min(ends) if ends else len(text)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel_tree", type=Path)
    parser.add_argument("--conf", type=Path)
    args = parser.parse_args()
    tree = args.kernel_tree.resolve()
    conf = (args.conf or tree / "scripts/kconfig/conf").resolve()
    media = (tree / "drivers/media/Kconfig").read_text()
    intel = (tree / "drivers/media/pci/intel/Kconfig").read_text()

    # Core stubs make the dependency combinations controllable. CVS, its
    # containing I2C menus, IPU_BRIDGE and ancillary visibility come from source.
    kconfig = 'mainmenu "Native CVS configuration regression"\n'
    kconfig += 'config MODULES\n bool "Modules"\n modules\n default y\n'
    for symbol, kind in (
        ("ACPI", "bool"), ("I2C", "tristate"), ("VIDEO_DEV", "tristate"),
        ("EXPERT", "bool"), ("COMPILE_TEST", "bool"), ("HAS_IOMEM", "bool"),
        ("MEDIA_CONTROLLER", "bool"), ("VIDEO_V4L2_SUBDEV_API", "bool"),
        ("V4L2_FWNODE", "tristate"),
    ):
        kconfig += f'config {symbol}\n {kind} "{symbol}"\n'
    kconfig += config_block(media, "MEDIA_SUBDRV_AUTOSELECT")
    kconfig += config_block(media, "MEDIA_HIDE_ANCILLARY_SUBDRV")
    kconfig += config_block(intel, "IPU_BRIDGE")
    kconfig += '\nsource "drivers/media/i2c/Kconfig"\n'

    cases = (
        ("explicit modular CVS survives", {"VIDEO_INTEL_CVS": "m"}, "m"),
        ("built-in IPU, modular video", {"IPU_BRIDGE": "y"}, "m"),
        ("modular IPU, built-in video", {"VIDEO_DEV": "y"}, "m"),
        ("built-in IPU and video", {"IPU_BRIDGE": "y", "VIDEO_DEV": "y"}, "y"),
        ("no IPU", {"IPU_BRIDGE": "n"}, "n"),
        ("no video", {"VIDEO_DEV": "n"}, "n"),
        ("no ACPI", {"ACPI": "n"}, "n"),
        ("no I2C", {"I2C": "n", "MEDIA_SUBDRV_AUTOSELECT": "n"}, "n"),
        ("no autoselection", {"MEDIA_SUBDRV_AUTOSELECT": "n"}, "n"),
        ("manual selection", {"MEDIA_SUBDRV_AUTOSELECT": "n", "VIDEO_INTEL_CVS": "m"}, "m"),
        ("expert opt-out", {"EXPERT": "y", "VIDEO_INTEL_CVS": "n"}, "n"),
    )
    with tempfile.TemporaryDirectory(prefix="native-cvs-config-") as directory:
        output = Path(directory)
        (output / "Kconfig").write_text(kconfig)
        env = dict(os.environ, srctree=str(tree), KCONFIG_CONFIG=str(output / ".config"))
        for name, changes, expected in cases:
            symbols = dict(MODULES="y", HAS_IOMEM="y", ACPI="y", I2C="y", VIDEO_DEV="m",
                           IPU_BRIDGE="m", MEDIA_SUBDRV_AUTOSELECT="y", EXPERT="n",
                           COMPILE_TEST="n")
            symbols.update(changes)
            (output / ".config").write_text("".join(
                f"CONFIG_{key}={value}\n" if value != "n" else f"# CONFIG_{key} is not set\n"
                for key, value in symbols.items()
            ))
            subprocess.run([str(conf), "--olddefconfig", "Kconfig"], cwd=output,
                           env=env, check=True, capture_output=True, text=True)
            values = dict(line.removeprefix("CONFIG_").split("=", 1)
                          for line in (output / ".config").read_text().splitlines()
                          if line.startswith("CONFIG_"))
            actual = values.get("VIDEO_INTEL_CVS", "n")
            if actual != expected:
                raise SystemExit(f"FAIL: {name}: CVS={actual}, expected {expected}")
            if symbols["MEDIA_SUBDRV_AUTOSELECT"] == "y":
                if values.get("MEDIA_SUBDRV_AUTOSELECT") != "y":
                    raise SystemExit(f"FAIL: {name}: ancillary autoselection changed")
                if symbols["EXPERT"] == "n" and values.get("MEDIA_HIDE_ANCILLARY_SUBDRV") != "y":
                    raise SystemExit(f"FAIL: {name}: ancillary menu visibility changed")
            print(f"PASS: {name}: CVS={actual}")


if __name__ == "__main__":
    main()
