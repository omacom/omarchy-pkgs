#!/usr/bin/env python3
"""Run every repository self-test in parallel across available CPUs.

Preserves every check that .github/workflows/test.yml runs sequentially:
  - prepares the fast libmakepkg overlay (helpers/fast-makepkg.sh) and a
    single-thread zstd makepkg.conf for tiny fixture packages
  - pre-creates the unprivileged `fixture` user once so concurrent makepkg
    tests never race on /etc/passwd
  - overlaps sleep/timeout-bound tests (low CPU) with CPU-bound tests and
    schedules the longest CPU-bound tests first to minimise tail latency
  - buffers each test's output and prints it atomically on completion,
    failing non-zero if any test fails
"""
import concurrent.futures
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def cpu_limit():
    n = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else (os.cpu_count() or 1)
    try:
        parts = Path("/sys/fs/cgroup/cpu.max").read_text().split()
        if len(parts) == 2 and parts[0] != "max":
            quota, period = int(parts[0]), int(parts[1])
            if period > 0:
                n = min(n, max(1, (quota + period - 1) // period))
    except OSError:
        pass
    return n


def build_test_list():
    base = os.environ.get("BASE", "")
    owners_check_cmd = ["bin/release-owners", "--check"]
    if base:
        owners_check_cmd.extend(["--base", base])

    # Off-CPU / timer-bound tests (<15% CPU): run alongside CPU-bound tests
    # without consuming a CPU worker slot, overlapping their waits for free.
    off_cpu = [
        ("published-build-plan", ["./tests/published-build-plan.sh"], {}),
        ("aurora-edge/review", ["python", "tests/aurora-edge/review.py"], {}),
        ("neovim-clipboard-tmux", ["python", "tests/neovim-clipboard-tmux.py"], {}),
    ]

    # CPU-bound tests ordered longest-first (LPT) to avoid a late straggler.
    cpu_bound = [
        ("promote-channel", ["./tests/promote-channel.sh"], {}),
        ("release-owners --check", owners_check_cmd, {}),
        ("publish-artifact", ["./tests/publish-artifact.sh"], {}),
        ("fast-makepkg", ["runuser", "-u", "nobody", "--", "python", "tests/fast-makepkg.py"], {}),
        ("sync-upstream self-test", ["./bin/sync-upstream", "self-test"], {}),
        ("pinned-sources", ["./tests/pinned-sources.sh"], {}),
        ("recipe-hygiene", ["python", "tests/recipe-hygiene.py"], {}),
        ("upstream-watch", ["python", "tests/upstream-watch.py"], {}),
        ("sync-pr-body", ["python", "tests/sync-pr-body.py"], {}),
        ("package-metadata", ["./tests/package-metadata.sh"], {}),
        ("settings-boot-config", ["./tests/settings-boot-config.sh"], {}),
        ("controller", ["./tests/controller.sh"], {}),
        ("pkgname-unique", ["./tests/pkgname-unique.sh"], {}),
        ("limine-mkinitcpio-hook", ["./tests/limine-mkinitcpio-hook.sh"], {}),
        ("sync-rebuilds --self-test", ["./bin/sync-rebuilds", "--self-test"], {}),
        ("pgp-keys-vendored", ["./tests/pgp-keys-vendored.sh"], {}),
        ("passwordless-package-files", ["./tests/passwordless-package-files.sh"], {}),
        ("settings-runtime-profile", ["./tests/settings-runtime-profile.sh"], {}),
        ("refresh-pgp-keys", ["./tests/refresh-pgp-keys.sh"], {}),
        ("oma-service-removal", ["python", "tests/oma-service-removal.py"], {}),
        ("superwhisper-bin-install", ["./tests/superwhisper-bin-install.sh"], {}),
        ("aurora-edge/metadata", ["runuser", "-u", "nobody", "--", "python", "tests/aurora-edge/metadata.py"], {}),
        ("package-owners", ["./tests/package-owners.sh"], {}),
        ("mac-installer-dispatch", ["./tests/mac-installer-dispatch.sh"], {}),
        ("ipu7-install", ["bash", "tests/ipu7-install.sh"], {}),
        ("settings-etc-overrides", ["./tests/settings-etc-overrides.sh"], {}),
        ("unpublish-plan", ["./tests/unpublish-plan.sh"], {}),
        ("build-matrix", ["./tests/build-matrix.sh"], {}),
        ("neovim-remote-clipboard", ["./tests/neovim-remote-clipboard.sh"], {}),
        ("passwordless-package-lifecycle", ["python", "tests/passwordless-package-lifecycle.py"], {}),
        ("upstream-github-netrc", ["./tests/upstream-github-netrc.sh"], {}),
        ("omarchy-release self-test", ["./bin/omarchy-release", "self-test"], {}),
        ("fast-ring-check", ["./tests/fast-ring-check.sh"], {}),
        ("check-shadowed", ["./tests/check-shadowed.sh"], {}),
        ("workflow-helpers-sourced", ["python", "tests/workflow-helpers-sourced.py"], {}),
        ("owe-package-restart", ["python", "tests/owe-package-restart.py"], {}),
        ("nvidia-open-lockstep", ["./tests/nvidia-open-lockstep.sh"], {}),
        ("ipu7-headers", ["bash", "tests/ipu7-headers.sh"], {}),
        ("artifact-helpers", ["./tests/artifact-helpers.sh"], {}),
        ("upstream-github-fetch", ["./tests/upstream-github-fetch.sh"], {}),
        ("voxtype-bin-install", ["./tests/voxtype-bin-install.sh"], {}),
        ("aurora-edge/firmware", ["python", "tests/aurora-edge/firmware.py"], {}),
        ("ipu7-lockstep", ["./tests/ipu7-lockstep.sh"], {}),
        ("release-owners --self-test", ["bin/release-owners", "--self-test"], {}),
        ("1password-polkit-owners", ["./tests/1password-polkit-owners.sh"], {}),
        ("omarchy-pkgs self-test", ["./bin/omarchy-pkgs", "self-test"], {}),
        ("dell-xps-touchpad-haptics-install", ["bash", "tests/dell-xps-touchpad-haptics-install.sh"], {}),
    ]

    # Package-local tests (pkgbuilds/*/test.sh); schedule known slower ones early.
    pkg_tests = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "pkgbuilds").glob("*/test.sh"))
    slow_pkg = {"pkgbuilds/microsoft-surface-pro-11-support/test.sh", "pkgbuilds/qcom-firmware-extract/test.sh"}
    early_pkg = [(p, ["bash", p], {}) for p in pkg_tests if p in slow_pkg]
    other_pkg = [(p, ["bash", p], {}) for p in pkg_tests if p not in slow_pkg]
    # Insert slower package tests right after publish-artifact
    cpu_bound[5:5] = early_pkg
    cpu_bound.extend(other_pkg)
    return off_cpu, cpu_bound


def main():
    t_start = time.monotonic()
    workers = cpu_limit()

    # Pre-create `fixture` user once when running as root so concurrent makepkg
    # tests never race on useradd / /etc/passwd.
    if os.geteuid() == 0:
        if subprocess.run(["id", "-u", "fixture"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            subprocess.run(["useradd", "-m", "fixture"], check=True)

    with tempfile.TemporaryDirectory(prefix="omarchy-selftests-") as work:
        os.chmod(work, 0o755)
        base_env = dict(os.environ)

        # Prepare fast libmakepkg overlay and single-threaded zstd config for test fixtures.
        fast_helper = ROOT / "helpers/fast-makepkg.sh"
        if fast_helper.is_file() and "MAKEPKG_LIBRARY" not in base_env:
            fast_lib = subprocess.check_output(
                ["bash", str(fast_helper), os.path.join(work, "libmakepkg")], text=True
            ).strip()
            base_env["MAKEPKG_LIBRARY"] = fast_lib

        makepkg_conf = Path("/etc/makepkg.conf")
        if makepkg_conf.is_file() and "MAKEPKG_CONF" not in base_env:
            conf_text = makepkg_conf.read_text().replace("zstd -c -T0", "zstd -c -T1 -1")
            conf_path = Path(work) / "makepkg.conf"
            conf_path.write_text(conf_text)
            conf_path.chmod(0o644)
            base_env["MAKEPKG_CONF"] = str(conf_path)

        off_cpu, cpu_bound = build_test_list()
        print_lock = threading.Lock()
        results = []

        def run_one(item):
            name, cmd, extra_env = item
            env = {**base_env, **extra_env}
            t0 = time.monotonic()
            proc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            dt = time.monotonic() - t0
            with print_lock:
                status = "PASS" if proc.returncode == 0 else f"FAIL (rc={proc.returncode})"
                print(f"=== {name} [{status}, {dt:.2f}s] ===", flush=True)
                if proc.stdout:
                    sys.stdout.write(proc.stdout)
                    if not proc.stdout.endswith("\n"):
                        sys.stdout.write("\n")
                    sys.stdout.flush()
            return (name, proc.returncode, dt)

        # Launch off-CPU tests in their own pool alongside the CPU-bound worker pool.
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(off_cpu) or 1) as io_pool, \
             concurrent.futures.ThreadPoolExecutor(max_workers=workers) as cpu_pool:
            futs = [io_pool.submit(run_one, item) for item in off_cpu]
            futs.extend(cpu_pool.submit(run_one, item) for item in cpu_bound)
            for fut in concurrent.futures.as_completed(futs):
                results.append(fut.result())

    total_wall = time.monotonic() - t_start
    failures = [r for r in results if r[1] != 0]
    results.sort(key=lambda r: -r[2])
    print(f"\n=== Self-test summary: {len(results) - len(failures)}/{len(results)} passed in {total_wall:.2f}s (workers={workers}) ===", flush=True)
    for name, rc, dt in results[:10]:
        mark = "OK" if rc == 0 else f"FAIL({rc})"
        print(f"  {dt:6.2f}s  {mark:8s}  {name}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
