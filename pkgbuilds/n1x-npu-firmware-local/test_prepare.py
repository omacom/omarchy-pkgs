#!/usr/bin/python
"""Exercise firmware preparation with a synthetic ARM64 PE, never vendor data."""
import hashlib
import importlib.util
import io
from pathlib import Path
import stat
import struct
import tempfile
from contextlib import redirect_stdout
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("prepare-firmware.py")
PAYLOADS = (b"synthetic-v0", b"synthetic-v1")
NAMES = ("sroot-v0.bin", "sroot-v1.bin")
RVAS = (0x1000, 0x1020)


def synthetic_pe():
    data = bytearray(512)
    pe_offset = 64
    section_offset = pe_offset + 24
    struct.pack_into("<I", data, 0x3C, pe_offset)
    data[pe_offset:pe_offset + 4] = b"PE\0\0"
    struct.pack_into("<HH", data, pe_offset + 4, 0xAA64, 1)
    struct.pack_into("<H", data, pe_offset + 20, 0)
    struct.pack_into("<IIII", data, section_offset + 8, 0x40, RVAS[0], 0x40, 256)
    data[256:256 + len(PAYLOADS[0])] = PAYLOADS[0]
    second_offset = RVAS[1] - RVAS[0]
    data[256 + second_offset:256 + second_offset + len(PAYLOADS[1])] = PAYLOADS[1]
    return bytes(data)


def load_module(source=SCRIPT, name="firmware_test"):
    spec = importlib.util.spec_from_file_location(name, source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def configure(module, pe, second_hash=None):
    module.KMD_SHA256 = hashlib.sha256(pe).hexdigest()
    image_rows = []
    for name, rva, payload in zip(NAMES, RVAS, PAYLOADS):
        image_rows.append((name, rva, len(payload), hashlib.sha256(payload).hexdigest()))
    if second_hash is not None:
        row = image_rows[1]
        image_rows[1] = (row[0], row[1], row[2], second_hash)
    module.IMAGES = tuple(image_rows)


def invoke(module, kmd, output):
    with redirect_stdout(io.StringIO()):
        module.prepare(kmd, output)


def expect_hash_rejection(module, pe):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        kmd = root / "synthetic.sys"
        output = root / "output"
        kmd.write_bytes(pe)
        configure(module, pe, second_hash="0" * 64)
        try:
            invoke(module, kmd, output)
        except ValueError as error:
            assert "Extracted firmware SHA256 mismatch" in str(error)
        else:
            raise AssertionError("accepted an extracted image with a wrong hash")
        assert not output.exists(), "hash rejection created the output directory"


def expect_success(module, pe):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        kmd = root / "synthetic.sys"
        output = root / "output"
        kmd.write_bytes(pe)
        configure(module, pe)
        invoke(module, kmd, output)
        for name, payload in zip(NAMES, PAYLOADS):
            image = output / name
            assert image.read_bytes() == payload, f"incorrect bytes in {name}"
            assert stat.S_IMODE(image.stat().st_mode) == 0o600, f"incorrect permissions on {name}"


def expect_input_rejection(module, pe):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        kmd = root / "synthetic.sys"
        output = root / "output"
        kmd.write_bytes(pe)
        module.KMD_SHA256 = "0" * 64
        try:
            invoke(module, kmd, output)
        except ValueError as error:
            assert "KMD SHA256 mismatch" in str(error)
        else:
            raise AssertionError("accepted an unpinned KMD")
        assert not output.exists(), "KMD rejection created the output directory"


def expect_invalid_pe_bounds(module):
    data = bytearray(512)
    struct.pack_into("<I", data, 0x3C, 64)
    data[64:68] = b"PE\0\0"
    struct.pack_into("<HH", data, 68, 0xAA64, 1)
    struct.pack_into("<IIII", data, 96, 16, 0x1000, 16, 256)
    for rva, size in ((0x100F, 2), (0x2000, 4)):
        try:
            module.pe_slice(data, rva, size)
        except ValueError:
            pass
        else:
            raise AssertionError("accepted invalid PE section bounds")


def expect_conflict_preserved(module, pe, symlink=False):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        kmd = root / "synthetic.sys"
        output = root / "output"
        output.mkdir()
        kmd.write_bytes(pe)
        configure(module, pe)
        conflict = output / NAMES[1]
        target = root / "sentinel"
        target.write_bytes(b"must remain untouched")
        if symlink:
            conflict.symlink_to(target)
        else:
            conflict.write_bytes(b"existing output")
        try:
            invoke(module, kmd, output)
        except (ValueError, FileExistsError):
            pass
        else:
            raise AssertionError("replaced a pre-existing output")
        assert not (output / NAMES[0]).exists(), "wrote an earlier image before finding conflict"
        if symlink:
            assert conflict.is_symlink(), "replaced the pre-existing symlink"
            assert target.read_bytes() == b"must remain untouched", "modified the symlink target"
        else:
            assert conflict.read_bytes() == b"existing output", "modified the pre-existing file"


def expect_race_safe_create(module, pe):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        kmd = root / "synthetic.sys"
        output = root / "output"
        kmd.write_bytes(pe)
        configure(module, pe)
        original_open = Path.open
        raced_path = output / NAMES[0]
        sentinel = b"created after the output preflight"

        def create_race(path, mode="r", *args, **kwargs):
            if Path(path) == raced_path and mode in ("xb", "wb") and not path.exists():
                with original_open(path, "wb") as stream:
                    stream.write(sentinel)
            return original_open(path, mode, *args, **kwargs)

        try:
            with patch.object(Path, "open", create_race):
                invoke(module, kmd, output)
        except FileExistsError:
            pass
        else:
            raise AssertionError("exclusive create accepted a raced-in output")
        assert raced_path.read_bytes() == sentinel, "overwrote the raced-in file"
        assert not (output / NAMES[1]).exists(), "continued writing after a create race"


def load_mutant(tmp, label, old, new):
    source = SCRIPT.read_text()
    assert source.count(old) == 1, f"could not apply {label} mutant exactly once"
    path = Path(tmp) / f"{label}.py"
    path.write_text(source.replace(old, new))
    return load_module(path, f"firmware_mutant_{label}")


def assert_mutant_caught(label, contract):
    try:
        contract()
    except AssertionError:
        return
    raise AssertionError(f"negative control failed to detect {label} mutant")


def main():
    pe = synthetic_pe()
    module = load_module()
    configure(module, pe)
    expect_invalid_pe_bounds(module)
    expect_success(module, pe)
    expect_input_rejection(module, pe)
    expect_hash_rejection(module, pe)
    expect_conflict_preserved(module, pe)
    expect_conflict_preserved(module, pe, symlink=True)
    expect_race_safe_create(module, pe)

    with tempfile.TemporaryDirectory() as tmp:
        no_hash = load_mutant(
            tmp,
            "no_extracted_hash_check",
            "if hashlib.sha256(payload).hexdigest()!=sha:",
            "if False:",
        )
        assert_mutant_caught("extracted hash validation", lambda: expect_hash_rejection(no_hash, pe))

        no_preflight = load_mutant(
            tmp,
            "no_output_preflight",
            "    # Never replace an existing output, including a symlink.\n"
            "    for name,_,_ in images:\n"
            "        if (output/name).exists() or (output/name).is_symlink():\n"
            "            raise ValueError('Output already exists: '+name)\n",
            "    pass\n",
        )
        assert_mutant_caught("all-output preflight", lambda: expect_conflict_preserved(no_preflight, pe))
        assert_mutant_caught(
            "symlink output preflight",
            lambda: expect_conflict_preserved(no_preflight, pe, symlink=True),
        )

        nonexclusive = load_mutant(tmp, "nonexclusive_open", ".open('xb')", ".open('wb')")
        assert_mutant_caught("exclusive file creation", lambda: expect_race_safe_create(nonexclusive, pe))

        no_chmod = load_mutant(tmp, "no_private_mode", ".chmod(0o600)", ".chmod(0o644)")
        assert_mutant_caught("private output permissions", lambda: expect_success(no_chmod, pe))

    print("Synthetic PE extraction, hashes, permissions, no-overwrite, symlink, and mutant controls passed")


if __name__ == "__main__":
    main()
