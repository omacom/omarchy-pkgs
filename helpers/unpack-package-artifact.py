#!/usr/bin/env python3
"""Unpack one GitHub package artifact into an empty private directory.

Accepts a downloaded GitHub zip, or its already unzipped directory. The
current form carries packages.tar; the legacy form carries bare archives.
Archive contents are data only and are never extracted with tar/unzip tools.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import stat
import tarfile
import tempfile
import zipfile

PACKAGE = re.compile(r"[A-Za-z0-9][-A-Za-z0-9@._+:~+-]*\.pkg\.tar\.zst\Z")


def package_name(value):
    if not PACKAGE.fullmatch(value) or Path(value).name != value:
        raise ValueError(f"invalid package basename: {value!r}")
    return value


def input_name(value):
    if value == "packages.tar":
        return value
    return package_name(value)


def copy_stream(stream, target):
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as out:
            shutil.copyfileobj(stream, out, 1024 * 1024)
    except BaseException:
        Path(target).unlink(missing_ok=True)
        raise


def copy_regular(path, target):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError(f"not a single regular input: {path.name}")
        with os.fdopen(fd, "rb") as source:
            copy_stream(source, target)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        raise


def unpack_tar(path, destination):
    count = 0
    with tarfile.open(path, "r:") as archive:
        for member in archive:
            package_name(member.name)
            if not member.isreg():
                raise ValueError(f"non-regular package entry: {member.name}")
            source = archive.extractfile(member)
            if source is None:
                raise ValueError(f"unreadable package entry: {member.name}")
            with source:
                copy_stream(source, destination / member.name)
            count += 1
    if not count:
        raise ValueError("empty packages.tar")


def read_directory(source, scratch):
    entries = list(source.iterdir())
    if not entries:
        raise ValueError("empty artifact")
    names = [input_name(entry.name) for entry in entries]
    if "packages.tar" in names and len(entries) != 1:
        raise ValueError("mixed packed and bare artifact")
    for entry in entries:
        copy_regular(entry, scratch / entry.name)
    return names


def read_zip(source, scratch):
    with zipfile.ZipFile(source) as archive:
        members = archive.infolist()
        if not members:
            raise ValueError("empty artifact zip")
        names = [input_name(member.filename) for member in members]
        if len(names) != len(set(names)):
            raise ValueError("duplicate artifact entry")
        if "packages.tar" in names and len(names) != 1:
            raise ValueError("mixed packed and bare artifact")
        for member in members:
            mode = member.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if member.is_dir() or kind not in (0, stat.S_IFREG):
                raise ValueError(f"non-regular artifact entry: {member.filename}")
            with archive.open(member) as stream:
                copy_stream(stream, scratch / member.filename)
        return names


def unpack(source, destination):
    if destination.is_symlink() or not destination.is_dir() or any(destination.iterdir()):
        raise ValueError("destination must be an empty regular directory")
    with tempfile.TemporaryDirectory() as scratch_name:
        scratch = Path(scratch_name)
        if source.is_dir() and not source.is_symlink():
            names = read_directory(source, scratch)
        elif source.is_file() and not source.is_symlink():
            names = read_zip(source, scratch)
        else:
            raise ValueError("artifact must be a directory or zip file")
        if names == ["packages.tar"]:
            unpack_tar(scratch / "packages.tar", destination)
        else:
            for name in names:
                copy_regular(scratch / name, destination / name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        unpack(args.artifact, args.destination)
    except (ValueError, OSError, tarfile.TarError, zipfile.BadZipFile) as error:
        parser.exit(1, f"unpack-package-artifact: {error}\n")


if __name__ == "__main__":
    main()
