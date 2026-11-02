#!/usr/bin/env python3
# Self-test over every workflow: a publishing job (one in the publish
# environment, or using its credentials) works from plans and indexes made
# by other jobs instead of reading recipes, takes values from other jobs and
# dispatch inputs through env:, read as "$VAR", not as ${{ ... }} inside a
# script, and runs its tools in the publisher image. The rule is per job,
# since a job's steps share a workspace.
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
PUBLISHING = re.compile(r"secrets\.(GPG_PRIVATE_KEY|GPG_PASSPHRASE|R2_[A-Z_]+)")
# Commands that read a PKGBUILD, directly or through the helpers.
RECIPE = re.compile(
    r"package_pkgbase|package_pkgbuild_var|package_arches|package_supports_arch"
    r"|bin/build(\s|$|\")|bin/build-matrix|bin/recipe-index|bin/unpublish-plan"
    r"|source\s+PKGBUILD|\.\s+PKGBUILD|makepkg"
)
# Values another job, the matrix or a dispatch made.
SPLICED = re.compile(r"\$\{\{\s*(needs\.|matrix\.|inputs\.|github\.event\.inputs\.)")
# Publishing jobs run their tools in ci/publisher.Dockerfile.
BUILDER = re.compile(r"omarchy-pkg-builder|bin/builder-image|buildx build")

problems = []
for wf in sorted((ROOT / ".github/workflows").glob("*.yml")):
    jobs = (yaml.safe_load(wf.read_text()) or {}).get("jobs", {})
    for name, job in jobs.items():
        text = yaml.safe_dump(job)
        env = job.get("environment")
        env = env.get("name") if isinstance(env, dict) else env
        if not (PUBLISHING.search(text) or env == "publish"):
            continue
        for i, step in enumerate(job.get("steps", [])):
            run = step.get("run", "")
            where = f"{wf.name} {name} step {i + 1} ({step.get('name', step.get('uses', 'run'))})"
            if m := RECIPE.search(run):
                problems.append(f"{where} reads a recipe: {m.group(0).strip()}")
            if m := SPLICED.search(run):
                problems.append(f"{where} splices {m.group(0)}...}} into shell")
            if m := BUILDER.search(run):
                problems.append(f"{where} uses the builder image: {m.group(0)}")

for p in problems:
    print(f"FAIL: {p}")
if problems:
    sys.exit(1)
print("PASS: no publishing job reads a recipe, splices a value into shell or uses the builder image")
