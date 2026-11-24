#!/usr/bin/env python3
# Fetch the prebuilt toolchain a Chromium release pins in its DEPS file, the
# way gclient would, checking each archive against the hash recorded there.
#
# Usage: fetch-deps.py <chromium source dir> <path under the source dir>...

import hashlib
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

HOST = {"host_os": "linux", "host_cpu": "x64", "checkout_linux": True, "checkout_x64": True, "non_git_source": True}


class Checkout(dict):
    """What a DEPS condition can name: this host, then the file's own vars."""

    def __init__(self, declared):
        super().__init__(HOST)
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


def fetch(bucket, obj, dest):
    url = f"https://storage.googleapis.com/{bucket}/{obj['object_name']}"
    for attempt in range(3):
        with tempfile.NamedTemporaryFile(dir=dest) as archive:
            try:
                found = download(url, archive)
            except OSError as error:
                print(f"{url}: {error}", file=sys.stderr)
                time.sleep(10)
                continue
            if found != obj["sha256sum"]:
                sys.exit(f"{url}: sha256 {found}, DEPS says {obj['sha256sum']}")
            subprocess.run(["bsdtar", "--no-same-owner", "-xf", archive.name, "-C", dest], check=True)
            return
    sys.exit(f"{url}: could not be downloaded")


def main(src, paths):
    # DEPS is Python by design, with these two helpers supplied by its reader.
    scope = {"Var": lambda name: "", "Str": str}
    with open(os.path.join(src, "DEPS")) as deps:
        exec(deps.read(), scope)
    checkout = Checkout(scope.get("vars", {}))

    def applies(entry):
        return bool(eval(entry.get("condition", "True"), {"__builtins__": {}}, checkout))

    for path in paths:
        dep = scope["deps"].get("src/" + path)
        if not isinstance(dep, dict) or dep.get("dep_type") != "gcs" or not applies(dep):
            sys.exit(f"{path}: DEPS pins no archive to fetch for a Linux x86_64 host")

        dest = os.path.join(src, path)
        os.makedirs(dest, exist_ok=True)
        fetched = 0
        for obj in dep["objects"]:
            if applies(obj):
                print(f"{path}: {obj['object_name']}", flush=True)
                fetch(dep["bucket"], obj, dest)
                fetched += 1
            else:
                print(f"{path}: skipping {obj['object_name']} ({obj['condition']})", flush=True)
        if not fetched:
            sys.exit(f"{path}: DEPS pins no archive to fetch for a Linux x86_64 host")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: fetch-deps.py <chromium source dir> <path under the source dir>...")
    main(sys.argv[1], sys.argv[2:])
