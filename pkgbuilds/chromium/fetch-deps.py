#!/usr/bin/env python3
# Fetch the prebuilt toolchain a Chromium release pins in its DEPS file, the
# way gclient would. A Cloud Storage archive is checked against the hash DEPS
# records; a CIPD package against the SHA-256 that CIPD resolves its version to.
#
# Usage: fetch-deps.py [--target-cpu <cpu>] <chromium source dir> <path>...
#
# The host is always Linux x64. --target-cpu adds a CPU the build targets, as
# target_cpu in .gclient does, so DEPS entries for it (an arm64 sysroot) apply.

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

HOST = {"host_os": "linux", "host_cpu": "x64", "checkout_linux": True, "checkout_x64": True, "non_git_source": True}


class Checkout(dict):
    """What a DEPS condition can name: this host, then the file's own vars."""

    def __init__(self, declared, target_cpus):
        super().__init__(HOST)
        for cpu in target_cpus:
            self[f"checkout_{cpu}"] = True
        self.declared = declared

    def __missing__(self, name):
        value = self.declared.get(name, False)
        # A var may itself be a condition; anything gclient would have to be
        # told, such as checkout_android, is off.
        self[name] = False
        if isinstance(value, str):
            try:
                value = eval(value, {"__builtins__": {}}, self)
            except Exception:
                pass
        self[name] = value
        return value


def download(url, archive):
    digest = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=60) as response:
        while chunk := response.read(1 << 20):
            digest.update(chunk)
            archive.write(chunk)
    archive.flush()
    return digest.hexdigest()


def fetch(url, sha256, dest, name=None):
    for attempt in range(3):
        with tempfile.NamedTemporaryFile(dir=dest) as archive:
            try:
                found = download(url, archive)
            except OSError as error:
                print(f"{name or url}: {error}", file=sys.stderr)
                time.sleep(10)
                continue
            if found != sha256:
                sys.exit(f"{name or url}: sha256 {found}, expected {sha256}")
            subprocess.run(["bsdtar", "--no-same-owner", "-xf", archive.name, "-C", dest], check=True)
            return
    sys.exit(f"{name or url}: could not be downloaded")


CIPD = "https://chrome-infra-packages.appspot.com/prpc/cipd.Repository/"


def cipd(method, body):
    request = urllib.request.Request(
        CIPD + method,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        # pRPC prefixes its JSON with a line that stops it being run as script
        return json.loads(response.read().decode().split("\n", 1)[1])


def fetch_cipd(package, version, dest):
    if "${" in package:
        sys.exit(f"{package}: CIPD platform templates are not supported")
    instance = cipd("ResolveVersion", {"package": package, "version": version})["instance"]
    if instance["hashAlgo"] != "SHA256":
        sys.exit(f"{package}@{version}: CIPD instance is hashed with {instance['hashAlgo']}, not SHA256")
    url = cipd("GetInstanceURL", {"package": package, "instance": instance})["signedUrl"]
    fetch(url, instance["hexDigest"], dest, f"{package}@{version}")
    # CIPD's own bookkeeping, not part of the package
    subprocess.run(["rm", "-rf", os.path.join(dest, ".cipdpkg")], check=True)


def main(src, paths, target_cpus):
    # DEPS is Python by design, with these two helpers supplied by its reader.
    scope = {"Var": lambda name: "", "Str": str}
    with open(os.path.join(src, "DEPS")) as deps:
        exec(deps.read(), scope)
    checkout = Checkout(scope.get("vars", {}), target_cpus)

    def applies(entry):
        return bool(eval(entry.get("condition", "True"), {"__builtins__": {}}, checkout))

    for path in paths:
        dep = scope["deps"].get("src/" + path)
        if not isinstance(dep, dict) or dep.get("dep_type") not in ("gcs", "cipd") or not applies(dep):
            sys.exit(f"{path}: DEPS pins no archive to fetch for this checkout")

        dest = os.path.join(src, path)
        os.makedirs(dest, exist_ok=True)
        fetched = 0
        if dep["dep_type"] == "cipd":
            for pkg in dep["packages"]:
                if applies(pkg):
                    print(f"{path}: {pkg['package']}@{pkg['version']}", flush=True)
                    fetch_cipd(pkg["package"], pkg["version"], dest)
                    fetched += 1
        else:
            for obj in dep["objects"]:
                if applies(obj):
                    print(f"{path}: {obj['object_name']}", flush=True)
                    url = f"https://storage.googleapis.com/{dep['bucket']}/{obj['object_name']}"
                    fetch(url, obj["sha256sum"], dest)
                    fetched += 1
                else:
                    print(f"{path}: skipping {obj['object_name']} ({obj['condition']})", flush=True)
        if not fetched:
            sys.exit(f"{path}: DEPS pins no archive to fetch for this checkout")


if __name__ == "__main__":
    args = sys.argv[1:]
    target_cpus = []
    while args[:1] == ["--target-cpu"] and len(args) > 1:
        target_cpus.append(args[1])
        args = args[2:]
    if len(args) < 2:
        sys.exit("usage: fetch-deps.py [--target-cpu <cpu>] <chromium source dir> <path>...")
    main(args[0], args[1:], target_cpus)
