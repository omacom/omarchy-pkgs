#!/usr/bin/env python3
"""Offline tests for controller-rendered runner cloud-init bootstrap and SHA-256 verification."""

import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
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
            (
                "config.sh",
                b'#!/bin/bash\nprintf \'config:%s\\n\' "$*" >> "$LOG_FILE"\n[[ ${FAIL_STAGE:-} != config ]] || exit 1\n',
                0o755,
            ),
            (
                "run.sh",
                b'#!/bin/bash\necho run >> "$LOG_FILE"\n[[ ${FAIL_STAGE:-} != run ]] || exit 1\n',
                0o755,
            ),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(body)
            info.mode = mode
            tf.addfile(info, io.BytesIO(body))
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_cloud_init(yaml_text: str) -> tuple[str, list[str]]:
    doc = yaml.safe_load(yaml_text)
    write_files = doc.get("write_files", [])
    dropins = [
        w for w in write_files
        if w.get("path") == "/etc/systemd/system/docker.service.d/10-bootstrap-timeout.conf"
    ]
    require(
        len(dropins) == 1
        and not dropins[0].get("defer")
        and dropins[0].get("content") == "[Unit]\nJobTimeoutSec=60s\n",
        f"cloud-init missing non-deferred docker JobTimeoutSec drop-in: {dropins!r}",
    )
    entries = [w for w in write_files if w.get("path") == "/home/runner/start.sh"]
    require(len(entries) == 1, "cloud-init missing /home/runner/start.sh")
    runcmd = doc.get("runcmd")
    require(
        isinstance(runcmd, list) and len(runcmd) > 0 and all(isinstance(cmd, str) for cmd in runcmd),
        f"cloud-init runcmd must be a non-empty list of shell strings: {runcmd!r}",
    )
    bootcmd = doc.get("bootcmd")
    want_bootcmd = [
        "systemd-run --unit=runner-bootstrap-deadline --on-boot=9min "
        "--timer-property=DefaultDependencies=no --property=DefaultDependencies=no "
        "--timer-property=AccuracySec=1s /usr/bin/systemctl --no-block poweroff"
    ]
    require(
        bootcmd == want_bootcmd,
        f"cloud-init missing bootcmd bootstrap deadline timer: {bootcmd!r}",
    )
    power_state = doc.get("power_state")
    require(
        power_state == {"mode": "poweroff"},
        f"cloud-init missing power_state mode=poweroff: {power_state!r}",
    )
    return entries[0]["content"], runcmd


def test_real_curl_retries(curl_args: list[str], want_url: str, good_tar: Path, tmp: Path) -> None:
    real_curl = shutil.which("curl")
    require(real_curl is not None, "curl executable not found in PATH")

    payload = good_tar.read_bytes()
    state = {"mode": "truncated", "attempts": 0}

    class FlakyHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            state["attempts"] += 1
            if state["mode"] == "truncated":
                if state["attempts"] == 1:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(payload) + 100))
                    self.end_headers()
                    self.wfile.write(payload[:16])
                    self.close_connection = True
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            self.send_response(503)
            self.send_header("Retry-After", "86400")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, format, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), FlakyHandler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        local_url = f"http://127.0.0.1:{port}/runner.tgz"
        replay_args = [local_url if a == want_url else a for a in curl_args]
        delay_idx = replay_args.index("--retry-delay")
        replay_args[delay_idx + 1] = "1"

        # Truncated transfer (curl exit 18) requires --retry-all-errors and succeeds on retry.
        trunc_dir = Path(tempfile.mkdtemp(dir=tmp))
        proc = subprocess.run(
            [real_curl, "-q", "--noproxy", "*", *replay_args],
            cwd=trunc_dir,
            capture_output=True,
            text=True,
            timeout=15,
        )
        require(
            proc.returncode == 0
            and state["attempts"] == 2
            and (trunc_dir / "runner.tgz").read_bytes() == payload,
            f"real curl truncated-body retry failed: rc={proc.returncode} attempts={state['attempts']} err={proc.stderr!r}",
        )

        # Excessive Retry-After header is bounded by --retry-max-time instead of sleeping 24h.
        state["mode"] = "retry_after"
        state["attempts"] = 0
        ra_dir = Path(tempfile.mkdtemp(dir=tmp))
        proc = subprocess.run(
            [real_curl, "-q", "--noproxy", "*", *replay_args],
            cwd=ra_dir,
            capture_output=True,
            text=True,
            timeout=10,
        )
        # curl 8.5.0 exits 22 while curl 8.18.0 exits 0 when Retry-After exceeds
        # --retry-max-time; both emit curl: (22) and leave runner.tgz absent (which
        # sha256sum --check --strict then rejects).
        require(
            proc.returncode in (0, 22)
            and "curl: (22)" in proc.stderr
            and state["attempts"] == 1
            and not (ra_dir / "runner.tgz").exists(),
            f"real curl Retry-After was not bounded: rc={proc.returncode} attempts={state['attempts']} err={proc.stderr!r}",
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_runcmd_bootstrap(runcmd: list[str], tmp: Path) -> None:
    runcmd_bin = tmp / "runcmd-bin"
    runcmd_bin.mkdir()
    for name in ("date", "chage", "systemctl", "chown", "sudo"):
        extra = 'echo 2026-01-01\n' if name == "date" else ""
        stub = runcmd_bin / name
        stub.write_text(
            "#!/bin/bash\n"
            f'echo "{name}:$*" >> "$RUNCMD_LOG"\n'
            f'[[ ${{FAIL_CMD:-}} != "{name}" ]] || exit 1\n'
            f"{extra}",
            encoding="utf-8",
        )
        stub.chmod(0o755)

    def run_runcmd(fail_cmd: str = "", create_home: bool = True):
        case_dir = Path(tempfile.mkdtemp(dir=tmp))
        home_runner = case_dir / "home/runner"
        if create_home:
            home_runner.mkdir(parents=True)
        log_file = case_dir / "runcmd.log"
        script_path = case_dir / "runcmd.sh"
        quoted_home = shlex.quote(str(home_runner))
        rendered = [cmd.replace("/home/runner", quoted_home) for cmd in runcmd]
        script_path.write_text("#!/bin/sh\n" + "\n".join(rendered) + "\n", encoding="utf-8")
        env = {
            "PATH": f"{runcmd_bin}:{os.environ['PATH']}",
            "RUNCMD_LOG": str(log_file),
            "FAIL_CMD": fail_cmd,
        }
        proc = subprocess.run(["/bin/sh", str(script_path)], cwd=case_dir, env=env, capture_output=True, text=True)
        log = log_file.read_text(encoding="utf-8") if log_file.exists() else ""
        return proc, log, home_runner

    # Happy path runs all bootstrap steps before cloud-init power_state shuts the droplet down.
    proc, log, home_runner = run_runcmd()
    lines = log.splitlines()
    require(
        proc.returncode == 0
        and "chage:-d 2026-01-01 -M -1 root\n" in log
        and "systemctl:--no-block enable --now docker\n" in log
        and f"chown:-R runner:runner {home_runner}\n" in log
        and lines
        and lines[-1] == f"sudo:-u runner {home_runner}/start.sh",
        f"runcmd success path failed: rc={proc.returncode} log={log!r} err={proc.stderr!r}",
    )

    # Best-effort root password-expiry clearing logs a warning without blocking runner startup.
    for fail_cmd, skipped in (("date", ("chage:",)), ("chage", ())):
        proc, log, home_runner = run_runcmd(fail_cmd=fail_cmd)
        lines = log.splitlines()
        require(
            proc.returncode == 0
            and "Could not clear root password expiry" in proc.stderr
            and all(marker not in log for marker in skipped)
            and lines
            and lines[-1] == f"sudo:-u runner {home_runner}/start.sh",
            f"runcmd {fail_cmd} failure unexpectedly blocked runner startup: rc={proc.returncode} err={proc.stderr!r} log={log!r}",
        )

    # Fatal bootstrap failures stop before later commands and exit non-zero so cloud-init records them before power_state.
    for fail_cmd, skipped in (
        ("systemctl", ("chown:", "sudo:")),
        ("chown", ("sudo:",)),
        ("sudo", ()),
    ):
        proc, log, _ = run_runcmd(fail_cmd=fail_cmd)
        require(
            proc.returncode != 0 and all(marker not in log for marker in skipped),
            f"runcmd {fail_cmd} failure did not abort cleanly: rc={proc.returncode} log={log!r}",
        )

    # Missing /home/runner breaks runner.log redirection and exits non-zero before invoking sudo.
    proc, log, _ = run_runcmd(create_home=False)
    require(
        proc.returncode != 0 and "sudo:" not in log,
        f"runcmd redirection failure did not abort cleanly: rc={proc.returncode} log={log!r} err={proc.stderr!r}",
    )


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
    _, template_runcmd = load_cloud_init(CLOUD_INIT.read_text(encoding="utf-8"))
    rendered_start, rendered_runcmd = load_cloud_init(
        json.loads(body_file.read_text(encoding="utf-8"))["user_data"]
    )
    require(template_runcmd == rendered_runcmd, "rendered runcmd diverged from ci/runner-cloud-init.yaml")
    require("cd /home/runner\n" in rendered_start, "start.sh missing expected cd /home/runner")
    require("__" not in rendered_start, "unexpanded placeholder left in start.sh")

    ver_matches = re.findall(r"^RUNNER_VERSION=(.+)$", rendered_start, re.M)
    sha_matches = re.findall(r"^RUNNER_SHA256=(.+)$", rendered_start, re.M)
    require(len(ver_matches) == 1 and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", ver_matches[0]), f"invalid RUNNER_VERSION: {ver_matches!r}")
    require(len(sha_matches) == 1 and re.fullmatch(r"[0-9a-f]{64}", sha_matches[0]), f"invalid RUNNER_SHA256: {sha_matches!r}")
    version, pinned_sha = ver_matches[0], sha_matches[0]
    want_url = f"https://github.com/actions/runner/releases/download/v{version}/actions-runner-linux-x64-{version}.tar.gz"
    want_curl_args = [
        "-fsSL",
        "--connect-timeout", "15",
        "--max-time", "90",
        "--retry", "2",
        "--retry-delay", "5",
        "--retry-max-time", "190",
        "--retry-all-errors",
        "-o", "runner.tgz",
        want_url,
    ]
    real_tar = shutil.which("tar")
    require(real_tar is not None, "tar executable not found in PATH")

    with tempfile.TemporaryDirectory(prefix="runner-tarball-sha256-") as tmp_str:
        tmp = Path(tmp_str)
        test_pin_check_script(tmp, version, pinned_sha)
        test_runcmd_bootstrap(rendered_runcmd, tmp)

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
                'printf \'%s\\n\' "$@" > "$CURL_ARGS_FILE"\n'
                'cp "$FAKE_TARBALL" runner.tgz\n'
                '[[ ${FAIL_STAGE:-} != curl ]] || exit 22\n'
            ),
            "timeout": (
                "#!/bin/bash\n"
                'echo "timeout:$*" >> "$LOG_FILE"\n'
                "shift 3\n"
                'exec "$@"\n'
            ),
            "docker": (
                "#!/bin/bash\n"
                'echo "docker:$*" >> "$LOG_FILE"\n'
                'count=0\n'
                '[[ -f "$DOCKER_COUNT_FILE" ]] && count=$(<"$DOCKER_COUNT_FILE")\n'
                'count=$((count + 1))\n'
                'printf \'%d\' "$count" > "$DOCKER_COUNT_FILE"\n'
                'if (( count <= ${DOCKER_FAIL_COUNT:-0} )); then\n'
                '  echo "Cannot connect to the Docker daemon" >&2\n'
                "  exit 1\n"
                "fi\n"
            ),
            "sleep": '#!/bin/bash\necho "sleep:$*" >> "$LOG_FILE"\n',
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
            "hostname": (
                "#!/bin/bash\n"
                '[[ ${FAIL_STAGE:-} != hostname ]] || exit 1\n'
                "echo testbox\n"
            ),
        }
        for name, content in stubs.items():
            sp = stub_bin / name
            sp.write_text(content, encoding="utf-8")
            sp.chmod(0o755)

        def run_start(
            script_text: str,
            tarball: Path,
            arch: str = "x86_64",
            fail_stage: str = "",
            docker_fail_count: int = 0,
        ):
            case_dir = Path(tempfile.mkdtemp(dir=tmp))
            log_file = case_dir / "log"
            curl_args_file = case_dir / "curl-args"
            docker_count_file = case_dir / "docker-count"
            script_path = case_dir / "start.sh"
            script_path.write_text(script_text.replace("cd /home/runner\n", "", 1), encoding="utf-8")
            script_path.chmod(0o755)
            env = {
                "PATH": f"{stub_bin}:{os.environ['PATH']}",
                "FAKE_TARBALL": str(tarball),
                "FAKE_ARCH": arch,
                "FAIL_STAGE": fail_stage,
                "DOCKER_FAIL_COUNT": str(docker_fail_count),
                "DOCKER_COUNT_FILE": str(docker_count_file),
                "CURL_ARGS_FILE": str(curl_args_file),
                "REAL_TAR": real_tar,
                "LOG_FILE": str(log_file),
            }
            proc = subprocess.run(["bash", str(script_path)], cwd=case_dir, env=env, capture_output=True, text=True)
            log = log_file.read_text(encoding="utf-8") if log_file.exists() else ""
            curl_args = curl_args_file.read_text(encoding="utf-8").splitlines() if curl_args_file.exists() else []
            marker = (case_dir / "actions-runner/extracted-marker").exists()
            tarball_left = (case_dir / "actions-runner/runner.tgz").exists()
            return proc, log, curl_args, marker, tarball_left

        # 1. Tampered tarball against unmodified production-rendered start.sh fails on checksum before tar.
        proc, log, _, marker, _ = run_start(rendered_start, bad_tar)
        require(
            proc.returncode != 0 and not marker and "tar:" not in log and "docker:" not in log and "config:" not in log and "runner.tgz: FAILED" in proc.stdout,
            f"tampered tarball failed unexpectedly: rc={proc.returncode} marker={marker} out={proc.stdout!r} log={log!r}",
        )

        # 2. Unsupported architecture against unmodified start.sh fails before download, tar, or docker.
        proc, log, _, marker, _ = run_start(rendered_start, good_tar, arch="aarch64")
        require(
            proc.returncode != 0 and not marker and "curl:" not in log and "tar:" not in log and "docker:" not in log and "unsupported arch: aarch64" in proc.stderr,
            f"unsupported arch failed unexpectedly: rc={proc.returncode} marker={marker} err={proc.stderr!r} log={log!r}",
        )

        # 3. Valid tarball verifies exact curl flags, checksum, extraction, docker readiness, registration, and run (leaving shutdown to cloud-init power_state).
        fixture_start = rendered_start.replace(f"RUNNER_SHA256={pinned_sha}", f"RUNNER_SHA256={good_sha}", 1)
        proc, log, curl_args, marker, tarball_left = run_start(fixture_start, good_tar)
        require(
            proc.returncode == 0
            and marker
            and not tarball_left
            and curl_args == want_curl_args
            and log.count("timeout:-k 1 3 docker info\n") == 1
            and log.count("docker:info\n") == 1
            and "sleep:" not in log
            and "tar:" in log
            and "--name do-testbox" in log
            and "--ephemeral" in log
            and "sudo:systemctl stop runner-bootstrap-deadline.timer\n" in log
            and log.index("config:") < log.index("sudo:systemctl stop runner-bootstrap-deadline.timer\n") < log.index("\nrun\n")
            and "sudo:poweroff" not in log,
            f"valid tarball failed: rc={proc.returncode} marker={marker} left={tarball_left} curl={curl_args!r} log={log!r} err={proc.stderr!r}",
        )
        test_real_curl_retries(curl_args, want_url, good_tar, tmp)

        # 4. Failed download exits non-zero before checksum verification, tar, docker, or registration.
        proc, log, _, marker, _ = run_start(fixture_start, good_tar, fail_stage="curl")
        require(
            proc.returncode != 0 and not marker and "runner.tgz:" not in proc.stdout and "tar:" not in log and "docker:" not in log and "config:" not in log,
            f"failed download test failed: rc={proc.returncode} marker={marker} out={proc.stdout!r} log={log!r}",
        )

        # 5. Extraction failure after checksum success reaches tar and skips docker and registration.
        proc, log, _, marker, _ = run_start(fixture_start, good_tar, fail_stage="tar")
        require(
            proc.returncode != 0 and not marker and "tar:" in log and "docker:" not in log and "config:" not in log,
            f"tar failure test failed: rc={proc.returncode} marker={marker} log={log!r}",
        )

        # 6. Docker transiently unready retries and proceeds to register and run.
        proc, log, _, marker, _ = run_start(fixture_start, good_tar, docker_fail_count=2)
        require(
            proc.returncode == 0
            and marker
            and log.count("docker:info\n") == 3
            and log.count("sleep:1\n") == 2
            and "config:" in log
            and "\nrun\n" in log,
            f"transient docker retry test failed: rc={proc.returncode} log={log!r} err={proc.stderr!r}",
        )

        # 7. Permanently broken Docker fails loudly without invoking config.sh or run.sh.
        proc, log, _, _, _ = run_start(fixture_start, good_tar, docker_fail_count=999)
        require(
            proc.returncode != 0
            and log.count("docker:info\n") == 15
            and log.count("sleep:1\n") == 14
            and "Cannot connect to the Docker daemon" in proc.stderr
            and "docker daemon not ready" in proc.stderr
            and "config:" not in log
            and "\nrun\n" not in log,
            f"broken docker test failed: rc={proc.returncode} err={proc.stderr!r} log={log!r}",
        )

        # 8. Hostname, registration, and runner failures each stop downstream steps (leaving deadline timer armed until config.sh succeeds).
        for stage, absent in (
            ("hostname", ("config:", "sudo:systemctl stop", "\nrun\n")),
            ("config", ("sudo:systemctl stop", "\nrun\n")),
            ("run", ()),
        ):
            proc, log, _, _, _ = run_start(fixture_start, good_tar, fail_stage=stage)
            require(
                proc.returncode != 0 and all(marker not in log for marker in absent),
                f"{stage} failure test failed: rc={proc.returncode} log={log!r}",
            )

    print("PASS: rendered cloud-init verifies curl timeouts/retries, tarball SHA-256, docker readiness, and power_state shutdown")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
