#!/usr/bin/env python3
"""Derive the ABI-scoped profile kit from Cua's published kit, the way its profile_bundle.py builds one."""

import argparse
import hashlib
import io
from pathlib import Path, PurePosixPath
import tarfile
import types

# The packages whose updates Cua's daily compatibility CI requalifies the plugin against,
# less hyprland and gcc, which the profile pins in its own fields.
ABI_RUNTIME = ("aquamarine", "glibc", "hyprcursor", "hyprgraphics", "hyprlang", "hyprutils",
               "libgcc", "libstdc++", "libxkbcommon", "wayland")
KIT = "cua-profile-kit"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read_kit(archive, checksum):
    require(archive.is_file() and not archive.is_symlink(), "kit archive must be a regular file")
    data = archive.read_bytes()
    require(sha256(data) == checksum, "kit archive checksum mismatch")
    payload = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as contents:
        for member in contents:
            require(member.isfile() and not member.issparse() and not member.pax_headers and
                    "/" not in member.name and member.name not in payload, "nonregular or duplicate kit member")
            payload[member.name] = contents.extractfile(member).read()
    require("SHA256SUMS" in payload, "kit has no checksum list")
    sums = {}
    for line in payload["SHA256SUMS"].decode().splitlines():
        digest, _, name = line.partition("  ")
        require(name and name not in sums, "invalid kit checksum list")
        sums[name] = digest
    require(set(sums) == set(payload) - {"SHA256SUMS"}, "kit inventory mismatch")
    require(all(sha256(payload[name]) == digest for name, digest in sums.items()), "kit member checksum mismatch")
    return payload


def load_verifier(path, source):
    # Compile the authenticated bytes; an import could run stale bytecode from a reused __pycache__.
    module = types.ModuleType("profile_verify")
    module.__file__ = str(path)
    exec(compile(source, str(path), "exec"), module.__dict__)
    return module


def derive(payload, profile_data, verify):
    upstream = verify.read_json(payload["PROFILE.json"])
    provenance = verify.read_json(payload["KIT-PROVENANCE.json"])
    require(payload["KIT-PROVENANCE.json"] == verify.json_bytes(provenance) and
            provenance["profile_sha256"] == sha256(payload["PROFILE.json"]), "upstream kit provenance mismatch")
    profile = verify.validate_profile(verify.read_json(profile_data))
    require(profile_data == verify.json_bytes(profile), "profile is not in the kit's canonical form")
    packages = upstream["runtime"]["packages"]
    require(set(ABI_RUNTIME) <= set(packages), "upstream profile lacks an ABI runtime package")
    expected = dict(upstream, profile_id=profile["profile_id"], package_release=profile["package_release"],
                    runtime=dict(upstream["runtime"], packages={name: packages[name] for name in ABI_RUNTIME}))
    require(profile == expected, "profile changes more than its ID, release and ABI runtime scope")
    provenance["profile_sha256"] = sha256(profile_data)
    derived = {name: data for name, data in payload.items() if name != "SHA256SUMS"}
    derived["PROFILE.json"] = profile_data
    derived["KIT-PROVENANCE.json"] = verify.json_bytes(provenance)
    derived["PKGBUILD"] = verify.render_recipe(payload["PROFILE-PKGBUILD.in"].decode(), profile, provenance)
    derived["SHA256SUMS"] = "".join(f"{sha256(data)}  {name}\n" for name, data in sorted(derived.items())).encode()
    return derived, verify.source_stem(profile)


def extract_source(data, stem, destination):
    require(not destination.exists() and not destination.is_symlink(), "source requires a fresh destination")
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as contents:
        for member in contents:
            require(member.isfile() and not member.issparse() and not member.pax_headers and
                    member.name.startswith(stem + "/"), "invalid source member")
            name = member.name[len(stem) + 1:]
            path = PurePosixPath(name)
            require(name and path.as_posix() == name and not path.is_absolute() and ".." not in path.parts and
                    "\\" not in name and name not in files, "unsafe or duplicate source path")
            files[name] = contents.extractfile(member).read()
    for name, content in files.items():
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)


def run(mode, archive, archive_sha256, profile, srcdir, kit_sha256):
    payload = read_kit(archive, archive_sha256)
    kit = srcdir / KIT
    if mode == "extract":
        require(srcdir.is_dir() and not srcdir.is_symlink(), "srcdir must be a real directory")
        require(not kit.exists() and not kit.is_symlink(), "kit requires a fresh destination")
        kit.mkdir()
        (kit / "profile_verify.py").write_bytes(payload["profile_verify.py"])
    require(kit.is_dir() and not kit.is_symlink(), "kit must be a real directory")
    verifier = kit / "profile_verify.py"
    require(verifier.is_file() and not verifier.is_symlink() and verifier.read_bytes() == payload["profile_verify.py"],
            "extracted verifier differs from the kit")
    verify = load_verifier(verifier, payload["profile_verify.py"])
    derived, stem = derive(payload, profile.read_bytes(), verify)
    if mode == "extract":
        for name, content in derived.items():
            (kit / name).write_bytes(content)
        extract_source(derived[stem + ".tar.gz"], stem, srcdir / stem)
    require({path.name for path in kit.iterdir()} == set(derived), "extracted kit inventory mismatch")
    for name, content in derived.items():
        path = kit / name
        require(path.is_file() and not path.is_symlink() and path.read_bytes() == content,
                "extracted kit differs from derivation: " + name)
    # Cua's own completeness check: profile, provenance, tooling and the rendered recipe agree.
    verify.verify_kit(kit, kit_sha256, complete=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("extract", "check"))
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--archive-sha256", required=True)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--srcdir", required=True, type=Path)
    parser.add_argument("--kit-sha256", required=True)
    args = parser.parse_args()
    try:
        run(args.mode, args.archive, args.archive_sha256, args.profile, args.srcdir, args.kit_sha256)
    except (ValueError, KeyError, TypeError, OSError, tarfile.TarError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
