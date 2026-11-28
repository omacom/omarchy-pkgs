#!/usr/bin/env python3
"""Offline tests for controller-rendered runner cloud-init SHA-256 verification."""

import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[1]
CLOUD_INIT = ROOT / "ci/runner-cloud-init.yaml"
PIN_CHECK = ROOT / "ci/check-runner-pin.sh"


def require(cond: bool, msg: str) -> None:
    if not cond:
        sys.exit(f"FAIL: {msg}")


def make_tarball(path: Path, marker_body: bytes) -> str:
    with tarfile.open(path, "w:gz") as tf:
        for name, body, mode in (
            ("extracted-marker", marker_body, 0o644),
            ("config.sh", b'#!/bin/bash\nprintf \'config:%s\\n\' "$*" >> "$LOG_FILE"\n', 0o755),
            ("run.sh", b'#!/bin/bash\necho run >> "$LOG_FILE"\n', 0o755),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(body)
            info.mode = mode
            tf.addfile(info, io.BytesIO(body))
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_start_sh(yaml_text: str) -> str:
    doc = yaml.safe_load(yaml_text)
    entries = [w for w in doc.get("write_files", []) if w.get("path") == "/home/runner/start.sh"]
    require(len(entries) == 1, "cloud-init missing /home/runner/start.sh")
    return entries[0]["content"]


def test_pin_check_script(tmp: Path, version: str, pinned_sha: str) -> None:
    repo = tmp / "gate-repo"
    (repo / "ci").mkdir(parents=True)
    git_env = {
        "PATH": os.environ["PATH"],
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
    }

    def git(*args) -> str:
        res = subprocess.run(["git", *args], cwd=repo, env=git_env, check=True, capture_output=True, text=True)
        return res.stdout.strip()

    git("init", "-q")
    template = CLOUD_INIT.read_text(encoding="utf-8")
    (repo / "ci/runner-cloud-init.yaml").write_text(template, encoding="utf-8")
    git("add", "ci/runner-cloud-init.yaml")
    git("commit", "-q", "-m", "base")
    base_sha = git("rev-parse", "HEAD")

    (repo / "README.md").write_text("unrelated\n", encoding="utf-8")
    git("add", "README.md")
    git("commit", "-q", "-m", "unrelated")

    gate_bin = tmp / "gate-bin"
    gate_bin.mkdir()
    gh_stub = gate_bin / "gh"
    gh_stub.write_text(
        "#!/bin/bash\n"
        'echo "gh:$*" >> "$GH_LOG"\n'
        '[[ ${GH_FAIL:-0} == 0 ]] || exit 22\n'
        'printf \'%s\\n\' "$GH_RESPONSE"\n',
        encoding="utf-8",
    )
    gh_stub.chmod(0o755)

    def run_gate(event: str, gh_response: str = "", push_before: str = "", gh_fail: bool = False, cwd: Path = repo):
        gh_log = tmp / "gh.log"
        gh_log.unlink(missing_ok=True)
        env = {
            "PATH": f"{gate_bin}:{os.environ['PATH']}",
            "GITHUB_EVENT_NAME": event,
            "PUSH_BEFORE": push_before,
            "GH_LOG": str(gh_log),
            "GH_RESPONSE": gh_response,
            "GH_FAIL": "1" if gh_fail else "0",
        }
        proc = subprocess.run([str(PIN_CHECK)], cwd=cwd, env=env, capture_output=True, text=True)
        calls = gh_log.read_text(encoding="utf-8") if gh_log.exists() else ""
        return proc, calls

    # Unchanged pin skips the release API on pull_request and push with a known base.
    for event, before in (("pull_request", ""), ("push", base_sha)):
        proc, calls = run_gate(event, push_before=before, gh_fail=True)
        require(proc.returncode == 0 and calls == "", f"{event} unchanged pin unexpectedly called API or failed: rc={proc.returncode} calls={calls!r} out={proc.stdout!r}")

    # Shallow multi-commit push fetches PUSH_BEFORE from origin and skips the release API when unchanged.
    (repo / "README.md").write_text("unrelated 2\n", encoding="utf-8")
    git("add", "README.md")
    git("commit", "-q", "-m", "unrelated 2")
    shallow_repo = tmp / "shallow-gate-repo"
    subprocess.run(["git", "clone", "-q", "--depth=1", f"file://{repo}", str(shallow_repo)], env=git_env, check=True, capture_output=True, text=True)
    proc, calls = run_gate("push", push_before=base_sha, gh_fail=True, cwd=shallow_repo)
    require(proc.returncode == 0 and calls == "" and "runner tarball pin unchanged" in proc.stdout, f"shallow push fetch failed: rc={proc.returncode} calls={calls!r} out={proc.stdout!r} err={proc.stderr!r}")

    # Missing/empty or duplicate trailing-empty pin fails local validation before skipping.
    for case_name, mutator in (
        ("empty", lambda t: "\n".join(line for line in t.splitlines() if "RUNNER_VERSION=" not in line and "RUNNER_SHA256=" not in line) + "\n"),
        ("duplicate-empty", lambda t: t.replace(f"RUNNER_SHA256={pinned_sha}", f"RUNNER_SHA256={pinned_sha}\n      RUNNER_SHA256=", 1)),
    ):
        bad_repo = tmp / f"bad-pin-{case_name}"
        (bad_repo / "ci").mkdir(parents=True)
        (bad_repo / "ci/runner-cloud-init.yaml").write_text(mutator(template), encoding="utf-8")
        for cmd in (("init", "-q"), ("add", "ci/runner-cloud-init.yaml"), ("commit", "-q", "-m", "bad"), ("commit", "-q", "--allow-empty", "-m", "bad 2")):
            subprocess.run(["git", *cmd], cwd=bad_repo, env=git_env, check=True, capture_output=True, text=True)
        proc, calls = run_gate("pull_request", gh_fail=True, cwd=bad_repo)
        require(proc.returncode != 0 and calls == "" and "invalid RUNNER_VERSION" in proc.stdout, f"{case_name} pin was not rejected: rc={proc.returncode} calls={calls!r} out={proc.stdout!r}")

    # Events without a resolved comparison base (workflow_dispatch, unresolvable push) validate fail-closed.
    orig_resp = json.dumps({"assets": [{"name": f"actions-runner-linux-x64-{version}.tar.gz", "digest": f"sha256:{pinned_sha}"}]})
    for event, before in (("workflow_dispatch", ""), ("push", "1" * 40)):
        proc, calls = run_gate(event, gh_response=orig_resp, push_before=before)
        require(proc.returncode == 0 and f"releases/tags/v{version}" in calls, f"{event} validation failed: rc={proc.returncode} calls={calls!r}")
        proc, calls = run_gate(event, push_before=before, gh_fail=True)
        require(proc.returncode != 0 and f"releases/tags/v{version}" in calls, f"{event} did not fail closed on API error: rc={proc.returncode}")

    # Bump BOTH version and sha256, and include an arm64 decoy asset with a different digest.
    new_ver = "2.999.0"
    new_sha = "b" * 64
    bumped = template.replace(f"RUNNER_VERSION={version}", f"RUNNER_VERSION={new_ver}", 1).replace(f"RUNNER_SHA256={pinned_sha}", f"RUNNER_SHA256={new_sha}", 1)
    (repo / "ci/runner-cloud-init.yaml").write_text(bumped, encoding="utf-8")
    git("add", "ci/runner-cloud-init.yaml")
    git("commit", "-q", "-m", "bump runner")
    decoy = {"name": f"actions-runner-linux-arm64-{new_ver}.tar.gz", "digest": f"sha256:{'d' * 64}"}
    x64_name = f"actions-runner-linux-x64-{new_ver}.tar.gz"

    ok_resp = json.dumps({"assets": [decoy, {"name": x64_name, "digest": f"sha256:{new_sha}"}]})
    proc, calls = run_gate("pull_request", gh_response=ok_resp)
    require(proc.returncode == 0 and f"releases/tags/v{new_ver}" in calls, f"bumped pin gate failed: rc={proc.returncode} calls={calls!r} out={proc.stdout!r}")

    bad_resp = json.dumps({"assets": [decoy, {"name": x64_name, "digest": f"sha256:{'c' * 64}"}]})
    proc, calls = run_gate("pull_request", gh_response=bad_resp)
    require(proc.returncode != 0 and f"releases/tags/v{new_ver}" in calls and "does not match" in proc.stdout, f"mismatched pin gate failed: rc={proc.returncode} out={proc.stdout!r}")

    missing_resp = json.dumps({"assets": [decoy, {"name": x64_name, "digest": None}]})
    proc, calls = run_gate("pull_request", gh_response=missing_resp)
    require(proc.returncode != 0 and f"releases/tags/v{new_ver}" in calls and "missing digest" in proc.stdout, f"missing digest gate failed: rc={proc.returncode} out={proc.stdout!r}")


def main(argv) -> int:
    if len(argv) != 2:
        sys.exit(f"usage: {argv[0]} <create-body-json>")
    body_file = Path(argv[1])

    # Raw template and controller-rendered user-data must both be valid YAML.
    load_start_sh(CLOUD_INIT.read_text(encoding="utf-8"))
    rendered_start = load_start_sh(json.loads(body_file.read_text(encoding="utf-8"))["user_data"])
    require("cd /home/runner\n" in rendered_start, "start.sh missing expected cd /home/runner")
    require("__" not in rendered_start, "unexpanded placeholder left in start.sh")

    ver_matches = re.findall(r"^RUNNER_VERSION=(.+)$", rendered_start, re.M)
    sha_matches = re.findall(r"^RUNNER_SHA256=(.+)$", rendered_start, re.M)
    require(len(ver_matches) == 1 and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", ver_matches[0]), f"invalid RUNNER_VERSION: {ver_matches!r}")
    require(len(sha_matches) == 1 and re.fullmatch(r"[0-9a-f]{64}", sha_matches[0]), f"invalid RUNNER_SHA256: {sha_matches!r}")
    version, pinned_sha = ver_matches[0], sha_matches[0]
    want_url = f"https://github.com/actions/runner/releases/download/v{version}/actions-runner-linux-x64-{version}.tar.gz"
    real_tar = shutil.which("tar")
    require(real_tar is not None, "tar executable not found in PATH")

    with tempfile.TemporaryDirectory(prefix="runner-tarball-sha256-") as tmp_str:
        tmp = Path(tmp_str)
        test_pin_check_script(tmp, version, pinned_sha)

        good_tar = tmp / "good-runner.tgz"
        bad_tar = tmp / "tampered-runner.tgz"
        good_sha = make_tarball(good_tar, b"good\n")
        make_tarball(bad_tar, b"tampered\n")

        stub_bin = tmp / "bin"
        stub_bin.mkdir()
        stubs = {
            "curl": (
                "#!/bin/bash\n"
                'echo "curl:$*" >> "$LOG_FILE"\n'
                'out="" url=""\n'
                "while (( $# )); do\n"
                "  if [[ $1 == -o ]]; then out=$2; shift 2; continue; fi\n"
                "  if [[ $1 != -* ]]; then url=$1; fi\n"
                "  shift\n"
                "done\n"
                '[[ $url == "$WANT_URL" ]] || { echo "unexpected url: $url" >&2; exit 23; }\n'
                'cp "$FAKE_TARBALL" "$out"\n'
                '[[ ${FAIL_STAGE:-} != curl ]] || exit 22\n'
            ),
            "tar": (
                "#!/bin/bash\n"
                'echo "tar:$*" >> "$LOG_FILE"\n'
                'if [[ ${FAIL_STAGE:-} == tar ]]; then\n'
                "  cat > config.sh <<'SH'\n"
                "#!/bin/bash\n"
                'printf \'config:%s\\n\' "$*" >> "$LOG_FILE"\n'
                "SH\n"
                "  chmod +x config.sh\n"
                "  exit 1\n"
                "fi\n"
                'exec "$REAL_TAR" "$@"\n'
            ),
            "uname": '#!/bin/bash\necho "$FAKE_ARCH"\n',
            "sudo": '#!/bin/bash\necho "sudo:$*" >> "$LOG_FILE"\n',
            "hostname": "#!/bin/bash\necho testbox\n",
        }
        for name, content in stubs.items():
            sp = stub_bin / name
            sp.write_text(content, encoding="utf-8")
            sp.chmod(0o755)

        def run_start(script_text: str, tarball: Path, arch: str = "x86_64", fail_stage: str = ""):
            case_dir = Path(tempfile.mkdtemp(dir=tmp))
            log_file = case_dir / "log"
            script_path = case_dir / "start.sh"
            script_path.write_text(script_text.replace("cd /home/runner\n", "", 1), encoding="utf-8")
            script_path.chmod(0o755)
            env = {
                "PATH": f"{stub_bin}:{os.environ['PATH']}",
                "FAKE_TARBALL": str(tarball),
                "FAKE_ARCH": arch,
                "FAIL_STAGE": fail_stage,
                "WANT_URL": want_url,
                "REAL_TAR": real_tar,
                "LOG_FILE": str(log_file),
            }
            proc = subprocess.run(["bash", str(script_path)], cwd=case_dir, env=env, capture_output=True, text=True)
            log = log_file.read_text(encoding="utf-8") if log_file.exists() else ""
            marker = (case_dir / "actions-runner/extracted-marker").exists()
            tarball_left = (case_dir / "actions-runner/runner.tgz").exists()
            return proc, log, marker, tarball_left

        # 1. Tampered tarball against unmodified production-rendered start.sh fails on checksum before tar.
        proc, log, marker, _ = run_start(rendered_start, bad_tar)
        require(
            proc.returncode != 0 and not marker and "tar:" not in log and "config:" not in log and "runner.tgz: FAILED" in proc.stdout and "sudo:poweroff" in log,
            f"tampered tarball failed unexpectedly: rc={proc.returncode} marker={marker} out={proc.stdout!r} log={log!r}",
        )

        # 2. Unsupported architecture against unmodified start.sh fails before download or tar.
        proc, log, marker, _ = run_start(rendered_start, good_tar, arch="aarch64")
        require(
            proc.returncode != 0 and not marker and "curl:" not in log and "tar:" not in log and "unsupported arch: aarch64" in proc.stderr and "sudo:poweroff" in log,
            f"unsupported arch failed unexpectedly: rc={proc.returncode} marker={marker} err={proc.stderr!r} log={log!r}",
        )

        # 3. Valid tarball with matching checksum verifies, extracts, configures, runs, removes archive, powers off.
        fixture_start = rendered_start.replace(f"RUNNER_SHA256={pinned_sha}", f"RUNNER_SHA256={good_sha}", 1)
        proc, log, marker, tarball_left = run_start(fixture_start, good_tar)
        require(
            proc.returncode == 0 and marker and not tarball_left and "tar:" in log and "--ephemeral" in log and "\nrun\n" in log and "sudo:poweroff" in log,
            f"valid tarball failed: rc={proc.returncode} marker={marker} left={tarball_left} log={log!r} err={proc.stderr!r}",
        )

        # 4. Failed download powers off before checksum verification, tar, or registration.
        proc, log, marker, _ = run_start(fixture_start, good_tar, fail_stage="curl")
        require(
            proc.returncode != 0 and not marker and "runner.tgz:" not in proc.stdout and "tar:" not in log and "config:" not in log and "sudo:poweroff" in log,
            f"failed download test failed: rc={proc.returncode} marker={marker} out={proc.stdout!r} log={log!r}",
        )

        # 5. Extraction failure after checksum success reaches tar, skips registration, and powers off.
        proc, log, marker, _ = run_start(fixture_start, good_tar, fail_stage="tar")
        require(
            proc.returncode != 0 and not marker and "tar:" in log and "config:" not in log and "sudo:poweroff" in log,
            f"tar failure test failed: rc={proc.returncode} marker={marker} log={log!r}",
        )

    print("PASS: rendered start.sh verifies runner tarball SHA-256 before extraction and handles download, mismatch, tar, and arch failures")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
