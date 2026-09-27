#!/usr/bin/env python3
"""Run publish.yml collection and slot selection offline with fixed data packages."""
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/publish.yml"
MATRIX = {"include": [
    {"package": "tool", "arch": "x86_64", "channels": "edge rc", "publish_arches": "x86_64 aarch64"},
    {"package": "other", "arch": "x86_64", "channels": "edge", "publish_arches": "x86_64"},
]}


def workflow_block(name):
    lines = WORKFLOW.read_text().splitlines()
    marker = f"      - name: {name}"
    start = lines.index(marker)
    run = lines.index("        run: |", start) + 1
    end = next((i for i in range(run, len(lines)) if lines[i].startswith("      - name: ")), len(lines))
    script = "\n".join(line[10:] if line.startswith("          ") else line for line in lines[run:end]) + "\n"
    substitutions = {
        "${{ github.repository }}": "example/packages",
        "${{ github.sha }}": "fixed-test-sha",
        "${{ github.server_url }}": "https://example.invalid",
        "${{ github.run_id }}": "1",
        "${{ github.event_name }}": "push",
        "${{ needs.changes.outputs.matrix }}": json.dumps(MATRIX, separators=(",", ":")),
    }
    for old, new in substitutions.items():
        script = script.replace(old, new)
    return script


def archive(pkg, base, arch):
    info = f"pkgname = {pkg}\npkgbase = {base}\npkgver = 1-1\narch = {arch}\n".encode()
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as stream:
        entry = tarfile.TarInfo(".PKGINFO")
        entry.size = len(info)
        stream.addfile(entry, io.BytesIO(info))
    return subprocess.run(["zstd", "-q", "-c"], input=buffer.getvalue(), capture_output=True, check=True).stdout


def artifact_zip(path, pkg, arch, outputs):
    inner = io.BytesIO()
    with tarfile.open(fileobj=inner, mode="w") as stream:
        for output in outputs:
            data = archive(output, pkg, arch)
            entry = tarfile.TarInfo(f"{output}-1-1-{arch}.pkg.tar.zst")
            entry.size = len(data)
            stream.addfile(entry, io.BytesIO(data))
    with zipfile.ZipFile(path, "w") as outer:
        outer.writestr("packages.tar", inner.getvalue())


DOCKER_STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
args = sys.argv[1:]
if args[0] == "buildx":
    sys.exit(0)
if args.pop(0) != "run":
    sys.exit("unexpected docker command")
mounts = {}
user = None
has_key_env = False
while args and args[0] != "omarchy-pkg-builder:latest-x86_64-edge":
    flag = args.pop(0)
    if flag == "--rm":
        continue
    if flag == "--user":
        user = args.pop(0)
    elif flag == "-v":
        host, guest, mode = args.pop(0).split(":", 2)
        if mode != "ro":
            sys.exit("writable container mount")
        mounts[guest] = pathlib.Path(host)
    elif flag == "-e":
        name = args.pop(0)
        has_key_env |= name in ("GPG_PRIVATE_KEY", "GPG_PASSPHRASE")
    elif flag == "-w":
        args.pop(0)
    else:
        sys.exit("unexpected docker option: " + flag)
if user != f"{os.getuid()}:{os.getgid()}":
    sys.exit("container did not use host uid")
args.pop(0)

def mapped(value):
    for guest, host in sorted(mounts.items(), key=lambda item: len(item[0]), reverse=True):
        if value == guest or value.startswith(guest + "/"):
            return str(host) + value[len(guest):]
    return value

if args[0] == "python3":
    if has_key_env:
        sys.exit("validation container received signing environment")
    sys.exit(subprocess.run([sys.executable, *map(mapped, args[1:])]).returncode)
if args[0] != "bin/publish-artifact" or not has_key_env:
    sys.exit("unexpected publisher invocation")
args = list(map(mapped, args[1:]))
manifest = pathlib.Path(args[args.index("--manifest") + 1])
arch = args[args.index("--arch") + 1]
mirror = args[args.index("--mirror") + 1]
files = [pathlib.Path(value) for value in args if value.endswith(".pkg.tar.zst")]
if not files or any(path.parent != files[0].parent for path in files):
    sys.exit("publisher files are not one private slot")
helper = root / "helpers/package-scope.py"
result = subprocess.run([sys.executable, str(helper), "verify", "--policy-root", str(root / "pkgbuilds"),
                         "--arch", arch, "--directory", str(files[0].parent), "--manifest", str(manifest)],
                        capture_output=True, text=True)
if result.returncode or sorted(result.stdout.splitlines()) != sorted(path.name for path in files):
    sys.exit("publisher received unapproved slot files: " + result.stderr)
data = json.loads(manifest.read_text())
with (root / "published.jsonl").open("a") as output:
    output.write(json.dumps({"mirror": mirror, "arch": arch, "jobs": [job["package"] for job in data["jobs"]],
                             "files": sorted(path.name for path in files)}) + "\n")
'''

CURL_STUB = r'''#!/usr/bin/env python3
import json, pathlib, shutil, sys
root = pathlib.Path(__import__("os").environ["FIXTURE_ROOT"])
args = sys.argv[1:]
if "-o" in args:
    shutil.copyfile(root / (args[-1].removeprefix("fixture://") + ".zip"), args[args.index("-o") + 1])
else:
    package = args[-1].split("?name=", 1)[1].split("-x86_64-", 1)[0]
    print(json.dumps({"artifacts": [{"expired": False, "created_at": "2026-01-01", "archive_download_url": "fixture://" + package}]}))
'''

GIT_STUB = '''#!/bin/bash
[[ $1 == rev-parse ]] || exit 1
printf 'fixed-tree-hash\\n'
'''


class WorkflowTest(unittest.TestCase):
    def test_collect_mapping_and_retarget(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "helpers").mkdir()
            (root / "stub").mkdir()
            shutil.copy(ROOT / "helpers/artifact-helpers.sh", root / "helpers")
            shutil.copy(ROOT / "helpers/unpack-package-artifact.py", root / "helpers")
            shutil.copy(ROOT / "helpers/package-scope.py", root / "helpers")
            for package, arch, outputs in (("tool", "any", ["tool", "tool-libs"]),
                                           ("other", "x86_64", ["other"])):
                policy = root / f"pkgbuilds/{package}/.omarchy/package.json"
                policy.parent.mkdir(parents=True)
                data = {"source": "local"}
                if len(outputs) > 1:
                    data["artifacts"] = {"pkgbase": package, "packages": outputs}
                policy.write_text(json.dumps(data))
                artifact_zip(root / f"{package}.zip", package, arch, outputs)
            for name, content in (("docker", DOCKER_STUB), ("curl", CURL_STUB), ("git", GIT_STUB)):
                stub = root / "stub" / name
                stub.write_text(content)
                stub.chmod(0o755)
            plan = root / "plan.txt"
            plan.write_text("tool x86_64 edge,rc x86_64,aarch64\nother x86_64 edge x86_64\n")
            env = dict(os.environ, PATH=str(root / "stub") + os.pathsep + os.environ["PATH"],
                       FIXTURE_ROOT=str(root), GH_TOKEN="fixed-test-token", CONTAINER_ENGINE="docker")
            env.pop("GPG_PRIVATE_KEY", None)
            env.pop("GPG_PASSPHRASE", None)
            self.assertEqual(subprocess.run(["bash", "-e"], input=workflow_block("Collect artifacts"),
                                            cwd=root, env=env, text=True, capture_output=True).returncode, 0)
            collected = json.loads((root / ".publication/edge/x86_64/manifest.json").read_text())
            self.assertEqual({job["package"] for job in collected["jobs"]}, {"tool", "other"})
            self.assertEqual({p.name for p in (root / "build-output/edge/x86_64").glob("*.pkg.tar.zst")},
                             {"tool-1-1-any.pkg.tar.zst", "tool-libs-1-1-any.pkg.tar.zst",
                              "other-1-1-x86_64.pkg.tar.zst"})
            self.assertEqual((root / ".publication/edge/x86_64").stat().st_mode & 0o777, 0o700)

            # A non-any archive cannot be retargeted to aarch64.
            plan.write_text("tool x86_64 edge,rc x86_64,aarch64\nother x86_64 edge x86_64,aarch64\n")
            rejected = subprocess.run(["bash", "-e"], input=workflow_block("Publish"),
                                      cwd=root, env=env, text=True, capture_output=True)
            self.assertNotEqual(rejected.returncode, 0)
            prior = [json.loads(line) for line in (root / "published.jsonl").read_text().splitlines()]
            self.assertFalse(any(item["arch"] == "aarch64" for item in prior))

            (root / "published.jsonl").unlink()
            plan.write_text("tool x86_64 edge,rc x86_64,aarch64\nother x86_64 edge x86_64\n")
            published = subprocess.run(["bash", "-e"], input=workflow_block("Publish"),
                                       cwd=root, env=env, text=True, capture_output=True)
            self.assertEqual(published.returncode, 0, published.stderr)
            slots = [json.loads(line) for line in (root / "published.jsonl").read_text().splitlines()]
            self.assertEqual({(item["mirror"], item["arch"]) for item in slots},
                             {("edge", "x86_64"), ("edge", "aarch64"), ("rc", "x86_64"), ("rc", "aarch64")})
            self.assertEqual(next(item["jobs"] for item in slots if (item["mirror"], item["arch"]) == ("edge", "x86_64")),
                             ["tool", "other"])
            for item in slots:
                if item["arch"] == "aarch64":
                    self.assertEqual(item["jobs"], ["tool"])
                    self.assertEqual(item["files"], ["tool-1-1-any.pkg.tar.zst", "tool-libs-1-1-any.pkg.tar.zst"])


if __name__ == "__main__":
    unittest.main()
