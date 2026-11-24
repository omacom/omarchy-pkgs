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
import urllib.request


class Checkout(dict):
    """The variables a DEPS condition can name; anything unset is false."""

    def __missing__(self, name):
        return False


HOST = Checkout(host_os="linux", host_cpu="x64", checkout_linux=True, checkout_x64=True, non_git_source=True)


def applies(entry):
    return eval(entry.get("condition", "True"), {"__builtins__": {}}, HOST)


def fetch(bucket, obj, dest):
    url = f"https://storage.googleapis.com/{bucket}/{obj['object_name']}"
    digest = hashlib.sha256()
    with tempfile.NamedTemporaryFile(dir=dest) as archive:
        with urllib.request.urlopen(url) as response:
            while chunk := response.read(1 << 20):
                digest.update(chunk)
                archive.write(chunk)
        archive.flush()
        if digest.hexdigest() != obj["sha256sum"]:
            sys.exit(f"{url}: sha256 {digest.hexdigest()}, DEPS says {obj['sha256sum']}")
        subprocess.run(["bsdtar", "--no-same-owner", "-xf", archive.name, "-C", dest], check=True)


def main(src, paths):
    # DEPS is Python by design, with these two helpers supplied by its reader.
    scope = {"Var": lambda name: "", "Str": str}
    with open(os.path.join(src, "DEPS")) as deps:
        exec(deps.read(), scope)

    for path in paths:
        dep = scope["deps"]["src/" + path]
        objects = [obj for obj in dep["objects"] if applies(obj)] if applies(dep) else []
        if dep.get("dep_type") != "gcs" or not objects:
            sys.exit(f"{path}: DEPS pins nothing to fetch for a Linux x86_64 host")

        dest = os.path.join(src, path)
        os.makedirs(dest, exist_ok=True)
        for obj in objects:
            print(f"{path}: {obj['object_name']}", flush=True)
            fetch(dep["bucket"], obj, dest)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__ or "usage: fetch-deps.py <chromium source dir> <path>...")
    main(sys.argv[1], sys.argv[2:])
