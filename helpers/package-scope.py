#!/usr/bin/env python3
"""Bind builder-reported archives to reviewed package identities before signing.

create trusts its caller to supply the host-owned policy root and builder's exact
output list. It never runs a recipe. verify is the final directory-wide gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import sys
import time

NAME = re.compile(r"[A-Za-z0-9][-A-Za-z0-9@._+]*\Z")
VERSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+:~+-]*\Z")
SHA = re.compile(r"[0-9a-f]{64}\Z")
ARCHES = {"x86_64", "aarch64"}
EXT = ".pkg.tar.zst"
MAX_META = 1024 * 1024
MAX_FILES = 128


def fail(message):
    raise ValueError(message)


def keys(obj, expected, label):
    if not isinstance(obj, dict) or set(obj) != set(expected):
        fail(f"invalid {label} fields")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    return json.loads(Path(path).read_text(), object_pairs_hook=unique_object)


def name(value):
    if not isinstance(value, str) or not NAME.fullmatch(value):
        fail(f"invalid package name: {value!r}")
    return value


def policy(root, package):
    name(package)
    data = read_json(Path(root) / package / ".omarchy/package.json")
    if not isinstance(data, dict):
        fail("policy must be an object")
    if "artifacts" not in data:
        base, packages, default = package, [package], True
    else:
        declared = data["artifacts"]
        keys(declared, {"pkgbase", "packages"}, "artifacts policy")
        base, packages, default = name(declared["pkgbase"]), declared["packages"], False
        if not isinstance(packages, list) or not packages:
            fail("artifacts.packages must be a nonempty list")
        packages = [name(item) for item in packages]
        if len(packages) != len(set(packages)):
            fail("duplicate declared package")
    scope = {"pkgbase": base, "packages": packages}
    digest = hashlib.sha256(json.dumps(scope, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return scope, digest, default


def archive_name(value):
    if not isinstance(value, str) or Path(value).name != value or not value.endswith(EXT) or value.startswith("-") or "\n" in value:
        fail(f"invalid archive basename: {value!r}")
    return value


def metadata(fd):
    # A held descriptor and /proc path keep bsdtar on the same inode we hash.
    process = subprocess.Popen(["bsdtar", "-xOf", f"/proc/self/fd/{fd}", ".PKGINFO"],
                               pass_fds=(fd,), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    chunks, count, deadline = [], 0, time.monotonic() + 10
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                if time.monotonic() >= deadline:
                    fail("bsdtar metadata timeout")
                ready = selector.select(max(0, deadline - time.monotonic()))
                if not ready:
                    fail("bsdtar metadata timeout")
                block = os.read(process.stdout.fileno(), 65536)
                if not block:
                    break
                count += len(block)
                if count > MAX_META:
                    fail("package metadata exceeds 1 MiB")
                chunks.append(block)
        if process.wait(timeout=max(0.01, deadline - time.monotonic())):
            fail("bsdtar could not read .PKGINFO")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()
    try:
        lines = b"".join(chunks).decode("utf-8").splitlines()
    except UnicodeDecodeError:
        fail("invalid .PKGINFO encoding")
    result = {}
    for line in lines:
        if " = " not in line:
            continue
        field, value = line.split(" = ", 1)
        if field in {"pkgname", "pkgbase", "pkgver", "arch"}:
            if field in result:
                fail(f"duplicate .PKGINFO {field}")
            result[field] = value
    if not {"pkgname", "pkgver", "arch"} <= result.keys():
        fail("missing .PKGINFO identity")
    name(result["pkgname"])
    if "pkgbase" in result:
        name(result["pkgbase"])
    if not VERSION.fullmatch(result["pkgver"]):
        fail("invalid .PKGINFO version")
    if result["arch"] not in ARCHES | {"any"}:
        fail("invalid .PKGINFO arch")
    return result


def inspect(directory, filename, scope, default, target):
    archive_name(filename)
    path = Path(directory) / filename
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            fail(f"not a regular archive: {filename}")
        info = metadata(fd)
        pkg = info["pkgname"]
        allowed = set(scope["packages"]) | {scope["pkgbase"] + "-debug"}
        if pkg not in allowed:
            fail(f"undeclared package: {pkg}")
        base = info.get("pkgbase")
        if base is None and default and pkg == scope["packages"][0]:
            base = pkg
        if base != scope["pkgbase"]:
            fail(f"pkgbase mismatch: {filename}")
        if info["arch"] not in {target, "any"}:
            fail(f"foreign archive arch: {filename}")
        if filename != f"{pkg}-{info['pkgver']}-{info['arch']}{EXT}":
            fail(f"filename does not match .PKGINFO: {filename}")
        digest = hashlib.sha256()
        os.lseek(fd, 0, os.SEEK_SET)
        while block := os.read(fd, 1024 * 1024):
            digest.update(block)
        after = os.fstat(fd)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            fail(f"archive changed during inspection: {filename}")
        return {"filename": filename, "pkgname": pkg, "pkgbase": base,
                "pkgver": info["pkgver"], "arch": info["arch"],
                "size": after.st_size, "sha256": digest.hexdigest()}
    finally:
        os.close(fd)


def validate_manifest(manifest):
    keys(manifest, {"version", "target_arch", "jobs"}, "manifest")
    if type(manifest["version"]) is not int or manifest["version"] != 1 or not isinstance(manifest["target_arch"], str) or manifest["target_arch"] not in ARCHES:
        fail("invalid manifest version or target arch")
    jobs = manifest["jobs"]
    if not isinstance(jobs, list) or not jobs:
        fail("manifest needs jobs")
    seen_jobs, seen_names, seen_files = set(), set(), set()
    for job in jobs:
        keys(job, {"package", "pkgbase", "packages", "policy_sha256", "artifacts"}, "job")
        package, base = name(job["package"]), name(job["pkgbase"])
        if package in seen_jobs:
            fail("duplicate job")
        seen_jobs.add(package)
        declared = job["packages"]
        if not isinstance(declared, list) or not declared or any(not isinstance(x, str) for x in declared):
            fail("invalid declared packages")
        declared = [name(x) for x in declared]
        if len(set(declared)) != len(declared) or not isinstance(job["policy_sha256"], str) or not SHA.fullmatch(job["policy_sha256"]):
            fail("invalid job policy")
        artifacts = job["artifacts"]
        if not isinstance(artifacts, list) or not artifacts or len(artifacts) > MAX_FILES:
            fail("job needs artifacts")
        found, versions = set(), set()
        for artifact in artifacts:
            keys(artifact, {"filename", "pkgname", "pkgbase", "pkgver", "arch", "size", "sha256"}, "artifact")
            filename, pkg = archive_name(artifact["filename"]), name(artifact["pkgname"])
            if pkg not in set(declared) | {base + "-debug"} or artifact["pkgbase"] != base:
                fail("artifact outside job scope")
            version, arch = artifact["pkgver"], artifact["arch"]
            if not isinstance(version, str) or not VERSION.fullmatch(version) or not isinstance(arch, str) or arch not in {manifest["target_arch"], "any"}:
                fail("invalid artifact version or arch")
            if filename != f"{pkg}-{version}-{arch}{EXT}":
                fail("artifact filename mismatch")
            if type(artifact["size"]) is not int or artifact["size"] < 0 or not isinstance(artifact["sha256"], str) or not SHA.fullmatch(artifact["sha256"]):
                fail("invalid artifact size or digest")
            if pkg in seen_names or filename in seen_files:
                fail("duplicate artifact name or file")
            seen_names.add(pkg); seen_files.add(filename); found.add(pkg); versions.add(version)
        if not set(declared) <= found or len(versions) != 1:
            fail("missing primary package or inconsistent version")
    return seen_files


def create(args):
    if args.arch not in ARCHES:
        fail("invalid target arch")
    scope, digest, default = policy(args.policy_root, args.package)
    listing = Path(args.files).read_bytes()
    if len(listing) > 65536:
        fail("builder output list too large")
    filenames = listing.decode("utf-8").splitlines()
    if not filenames or len(filenames) > MAX_FILES or len(filenames) != len(set(filenames)) or any(not x for x in filenames):
        fail("empty or duplicate builder output list")
    listed = {archive_name(filename) for filename in filenames}
    present = {p.name for p in Path(args.directory).iterdir() if p.name.endswith(EXT)}
    if present != listed:
        fail(f"unexpected or missing archives: {sorted(present ^ listed)}")
    artifacts = [inspect(args.directory, filename, scope, default, args.arch) for filename in filenames]
    result = {"version": 1, "target_arch": args.arch, "jobs": [{"package": args.package,
              **scope, "policy_sha256": digest, "artifacts": artifacts}]}
    validate_manifest(result)
    return result


def merge(args):
    manifests = [read_json(path) for path in args.manifest]
    for manifest in manifests:
        validate_manifest(manifest)
    arches = {manifest["target_arch"] for manifest in manifests}
    if len(arches) != 1:
        fail("mixed target arches")
    result = {"version": 1, "target_arch": arches.pop(), "jobs": [job for manifest in manifests for job in manifest["jobs"]]}
    validate_manifest(result)
    return result


def verify(args):
    manifest = read_json(args.manifest)
    files = validate_manifest(manifest)
    if manifest["target_arch"] != args.arch:
        fail("foreign target arch")
    for job in manifest["jobs"]:
        scope, digest, default = policy(args.policy_root, job["package"])
        if scope != {"pkgbase": job["pkgbase"], "packages": job["packages"]} or digest != job["policy_sha256"]:
            fail(f"changed policy: {job['package']}")
        for artifact in job["artifacts"]:
            actual = inspect(args.directory, artifact["filename"], scope, default, args.arch)
            if actual != artifact:
                fail(f"archive changed: {artifact['filename']}")
    present = {p.name for p in Path(args.directory).iterdir() if p.name.endswith(EXT)}
    if not args.allow_extra and present != files:
        fail(f"unexpected or missing archives: {sorted(present ^ files)}")
    return [artifact["filename"] for job in manifest["jobs"] for artifact in job["artifacts"]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("create", "verify", "merge"):
        sub = commands.add_parser(command)
        if command != "merge":
            sub.add_argument("--policy-root", required=True)
            sub.add_argument("--arch", required=True, choices=sorted(ARCHES))
            sub.add_argument("--directory", required=True)
        if command == "create":
            sub.add_argument("--package", required=True)
            sub.add_argument("--files", required=True)
        else:
            sub.add_argument("--manifest", required=True, action="append" if command == "merge" else "store")
        if command == "verify":
            sub.add_argument("--allow-extra", action="store_true")
    args = parser.parse_args()
    try:
        result = {"create": create, "merge": merge, "verify": verify}[args.command](args)
        if args.command == "verify":
            for filename in result:
                print(filename)
        else:
            print(json.dumps(result, separators=(",", ":")))
    except (ValueError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"package-scope: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
