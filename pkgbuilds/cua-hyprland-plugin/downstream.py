#!/usr/bin/env python3
"""Verify the Omarchy patch separately from the unchanged upstream source kit."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    require(root.is_dir() and not root.is_symlink(), "source must be a real directory")
    result = {}
    for path in root.rglob("*"):
        require(not path.is_symlink() and (path.is_dir() or path.is_file()), "nonregular source entry")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = digest(path)
    return result


def verify_inputs(pristine, patch, manifest):
    require(manifest["schema"] == 1, "unsupported downstream schema")
    require(patch.is_file() and not patch.is_symlink() and digest(patch) == manifest["patch_sha256"],
            "downstream patch checksum mismatch")
    require(digest(pristine / "SOURCE-PROVENANCE.json") == manifest["upstream_manifest_sha256"],
            "downstream base manifest mismatch")
    require(manifest["files"], "empty downstream inventory")
    for name in manifest["files"]:
        path = PurePosixPath(name)
        require(name and not path.is_absolute() and path.as_posix() == name and
                ".." not in path.parts and "\\" not in name, "invalid downstream path")


def verify_tree(source, manifest):
    require(inventory(source) == manifest["files"], "patched source inventory/checksum mismatch")


def prepare(pristine, source, patch, manifest):
    require(not source.exists() and not source.is_symlink(), "patched source requires a fresh destination")
    shutil.copytree(pristine, source)
    subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(patch.resolve())], cwd=source, check=True)
    verify_tree(source, manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "check", "build"))
    parser.add_argument("--pristine", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--patch", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--kit", required=True, type=Path)
    parser.add_argument("--kit-sha256", required=True)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--cxx", required=True, type=Path)
    parser.add_argument("--build", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        # PKGBUILD authenticates the verifier and this helper before execution.
        spec = importlib.util.spec_from_file_location("upstream_profile", args.kit / "profile_verify.py")
        upstream = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(upstream)
        profile, kit = upstream.verify_kit(args.kit, args.kit_sha256)
        base = upstream.verify_archive(args.archive, profile)
        require(upstream.verify_source(args.pristine, profile) == base, "upstream source identity mismatch")
        manifest = upstream.read_json(args.manifest.read_bytes())
        verify_inputs(args.pristine, args.patch, manifest)
        if args.mode == "prepare":
            prepare(args.pristine, args.source, args.patch, manifest)
        else:
            verify_tree(args.source, manifest)
        if args.mode == "build":
            require(args.build is not None and args.output is not None, "build evidence requires output")
            native = upstream.verify_native(args.cxx, profile)
            native["module_sha256"] = upstream.verify_build(args.build, args.source, args.cxx, profile)
            native["module_runtime_sha256"] = profile["runtime"]["sha256"]
            args.output.write_bytes(upstream.json_bytes(dict(native, source=base, profile=profile,
                                                            kit=kit, downstream=manifest)))
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
