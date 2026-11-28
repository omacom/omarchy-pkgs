#!/usr/bin/env python3
"""Guard workflow package quoting, Basecamp curl behavior, and jactionlint runner labels."""
import http.server
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
GITHUB_EXPR_VALUES = {
    "${{ github.server_url }}": "https://github.com",
    "${{ github.repository }}": "omacom/omarchy-pkgs",
    "${{ github.run_id }}": "12345",
}


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


def write_exec(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_step(script, cwd, env):
    # Match GitHub Actions default shell when `shell:` is omitted (`bash -e`).
    return subprocess.run(["bash", "--noprofile", "--norc", "-e", "-c", script], cwd=cwd, env=env, text=True, capture_output=True)


def find_step_run(wf_name, predicate, desc):
    wf = yaml.safe_load((ROOT / ".github/workflows" / wf_name).read_text())
    matches = [
        s["run"]
        for job in (wf.get("jobs") or {}).values()
        for s in (job.get("steps") or [])
        if isinstance(s, dict) and s.get("run") and predicate(s)
    ]
    check(len(matches) == 1, f"{wf_name}: expected 1 {desc} step, found {len(matches)}")
    return matches[0]


def check_runner_labels():
    cfg = yaml.safe_load((ROOT / ".github/jactionlint.yaml").read_text())
    declared = set((cfg.get("self-hosted-runner") or {}).get("labels") or [])
    pkgs = sorted(p.name for p in (ROOT / "pkgbuilds").iterdir() if p.is_dir())
    check(bool(pkgs), "expected at least one recipe under pkgbuilds/")
    script = (
        "set -euo pipefail; source helpers/package-metadata.sh; "
        "for d in pkgbuilds/*/; do p=${d#pkgbuilds/}; p=${p%/}; package_runner \"$p\" x86_64; package_runner \"$p\" aarch64; done"
    )
    proc = subprocess.run(["bash", "-c", script], cwd=ROOT, text=True, capture_output=True)
    check(proc.returncode == 0, f"package_runner probe failed: {proc.stderr}")
    lines = proc.stdout.splitlines()
    check(len(lines) == 2 * len(pkgs), f"expected {2 * len(pkgs)} runner probes, got {len(lines)}")
    for line in lines:
        labels = json.loads(line)
        check(isinstance(labels, list) and labels and all(isinstance(x, str) and x for x in labels), f"invalid output: {line!r}")
        for label in labels:
            if label != "self-hosted" and not label.startswith("ubuntu-"):
                check(label in declared, f".github/jactionlint.yaml: missing runner label {label!r}")
    print(f"PASS: jactionlint.yaml declares every custom package_runner() label ({len(lines)} probes)")


def check_libcurl_timeouts(libcurl_text, label):
    performs = len(re.findall(r"^\s*\w+\s*=\s*curl_easy_perform\(\w+\);$", libcurl_text, re.M))
    check(performs == 1, f"{label}: expected 1 curl transfer, got {performs}")
    for opt, name in (("CONNECTTIMEOUT", "--connect-timeout"), ("TIMEOUT", "--max-time")):
        matches = re.findall(rf"^\s*curl_easy_setopt\(\w+,\s*CURLOPT_{opt}(?:_MS)?,\s*(\d+)L\);$", libcurl_text, re.M)
        check(bool(matches) and int(matches[-1]) > 0, f"{label}: curl must set a positive {name}")


def check_basecamp_curls():
    real_curl = shutil.which("curl")
    check(real_curl is not None, "curl must be available on PATH")
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or "0"))
            requests.append((self.path, self.headers.get("Content-Type", ""), body))
            status = 200 if self.path == "/ok" else 500
            self.send_response(status)
            self.end_headers()
            self.wfile.write(b"ok" if status == 200 else b"error")

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port, found = server.server_address[1], 0
    try:
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            libcurl_file, curl_log = root / "libcurl.c", root / "curl.log"
            write_exec(
                root / "stubs/curl",
                f"#!{sys.executable}\nimport os, sys\n"
                "with open(os.environ['CURL_LOG'], 'a') as f: f.write('1\\n')\n"
                "args = [os.environ['REAL_CURL'], '--disable']\n"
                "if os.environ.get('LIBCURL_FILE'): args.extend(['--libcurl', os.environ['LIBCURL_FILE']])\n"
                "os.execv(os.environ['REAL_CURL'], [*args, *sys.argv[1:]])\n",
            )
            base_env = {
                "PATH": f"{root / 'stubs'}:{os.environ.get('PATH', '/usr/bin:/bin')}",
                "REAL_CURL": real_curl,
                "CURL_LOG": str(curl_log),
                "CONTENT": "sync summary",
            }
            for wf_path in sorted((ROOT / ".github/workflows").glob("*.yml")):
                wf = yaml.safe_load(wf_path.read_text()) or {}
                for job in (wf.get("jobs") or {}).values():
                    for step in (job.get("steps") or []):
                        if not isinstance(step, dict):
                            continue
                        env, run = step.get("env") or {}, step.get("run") or ""
                        if "BASECAMP_CHATBOT_URL" not in env and "BASECAMP_CHATBOT_URL" not in run:
                            continue
                        found += 1
                        label = f"{wf_path.name}: {step.get('name', '<unnamed>')}"
                        check(env.get("BASECAMP_CHATBOT_URL") == "${{ secrets.BASECAMP_CHATBOT_URL }}", f"{label}: missing secret binding")
                        check(step.get("continue-on-error") in (None, False), f"{label}: must not set continue-on-error")
                        script = run
                        for expr, val in GITHUB_EXPR_VALUES.items():
                            script = script.replace(expr, val)
                        check("${{" not in script, f"{label}: unexpected GitHub expression in run block")

                        requests.clear()
                        curl_log.write_text("")
                        libcurl_file.unlink(missing_ok=True)
                        res = run_step(script, root, {**base_env, "LIBCURL_FILE": str(libcurl_file), "BASECAMP_CHATBOT_URL": f"http://127.0.0.1:{port}/ok"})
                        check(res.returncode == 0, f"{label}: HTTP 200 failed: {res.stderr}")
                        check(len(curl_log.read_text().splitlines()) == 1 and len(requests) == 1, f"{label}: expected 1 curl POST")
                        path, ctype, body = requests[0]
                        payload = json.loads(body.decode("utf-8"))
                        check(path == "/ok" and "application/json" in ctype.lower() and isinstance(payload.get("content"), str) and bool(payload["content"]), f"{label}: bad payload")
                        check(libcurl_file.is_file(), f"{label}: missing --libcurl trace")
                        check_libcurl_timeouts(libcurl_file.read_text(), label)

                        requests.clear()
                        curl_log.write_text("")
                        res = run_step(script, root, {**base_env, "BASECAMP_CHATBOT_URL": f"http://127.0.0.1:{port}/fail"})
                        check(res.returncode == 22 and bool(res.stderr.strip()), f"{label}: expected exit 22 with stderr on HTTP 500, got rc={res.returncode} err={res.stderr!r}")
                        check(len(curl_log.read_text().splitlines()) == 1 and len(requests) == 1 and requests[0][0] == "/fail", f"{label}: expected 1 POST to /fail")
    finally:
        server.shutdown()
        server.server_close()
    check(found >= 3, f"expected at least 3 Basecamp webhook steps, found {found}")
    print(f"PASS: all {found} Basecamp curl steps bind secret, fail with exit 22 + stderr on HTTP 500, and set positive timeouts")


def check_workflow_argv_boundaries():
    promote_inputs = find_step_run("promote.yml", lambda s: s.get("id") == "inputs", "inputs")
    promote_run = find_step_run("promote.yml", lambda s: s.get("id") == "promote", "promote")
    unpublish_plan = find_step_run("unpublish.yml", lambda s: "bin/unpublish-plan" in s["run"], "unpublish-plan")
    unpublish_run = find_step_run("unpublish.yml", lambda s: "bin/unpublish-packages" in s["run"], "unpublish-packages")

    with tempfile.TemporaryDirectory() as td:
        root = pathlib.Path(td)
        repo, log, gh_env = root / "repo", root / "calls.jsonl", root / "gh-env"
        (root / "runner-tmp").mkdir()
        # Glob bait: unquoted `b*` expands to `bin build`, `??` expands to `ci`.
        (repo / "build").mkdir(parents=True)
        (repo / "ci").mkdir(parents=True)
        write_exec(repo / "bin/builder-image", "#!/bin/sh\necho stub\n")
        write_exec(
            repo / "bin/unpublish-plan",
            f"#!{sys.executable}\nimport json, os, sys\n"
            "with open(os.environ['LOG_FILE'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "print('RETIRE_STABLE_X86_64=b*  ??\\nRETIRE_STABLE_AARCH64=\\nRETIRE_EDGE_X86_64=foo\\nRETIRE_EDGE_AARCH64=' )\n",
        )
        write_exec(
            root / "stubs/docker",
            f"#!{sys.executable}\nimport json, os, sys\n"
            "if sys.argv[1:2] == ['run']:\n"
            "    with open(os.environ['LOG_FILE'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n",
        )
        base_env = {
            "PATH": f"{root / 'stubs'}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "LOG_FILE": str(log),
            "RUNNER_TEMP": str(root / "runner-tmp"),
            "GITHUB_OUTPUT": str(root / "gh-out"),
            "GITHUB_ENV": str(gh_env),
        }

        # promote.yml: newline/glob rejection, empty & multi-space live flow, and glob argv boundary.
        res = run_step(promote_inputs, repo, {**base_env, "DIRECTION": "edge -> rc", "PACKAGES": "foo\nbar"})
        check(res.returncode != 0 and res.stdout == "::error::Packages must be a single space-separated line\n" and res.stderr == "", f"promote newline: {res.stdout!r}")
        res = run_step(promote_inputs, repo, {**base_env, "DIRECTION": "edge -> rc", "PACKAGES": "b*  ??"})
        check(res.returncode != 0 and res.stdout == "::error::Not a package name: b*\n" and res.stderr == "", f"promote glob: {res.stdout!r}")
        for ok_pkgs in ("", "foo  bar"):
            res = run_step(promote_inputs, repo, {**base_env, "DIRECTION": "edge -> rc", "PACKAGES": ok_pkgs})
            check(res.returncode == 0, f"promote inputs rejected {ok_pkgs!r}: {res.stderr}")

        for dry_run, pkgs, count, tail in (
            ("true", "", 2, ["--dry-run"]),
            ("false", "foo  bar", 6, ["foo", "bar"]),
            ("true", "b*  ??", 2, ["--dry-run", "b*", "??"]),
        ):
            log.write_text("")
            res = run_step(promote_run, repo, {**base_env, "FROM": "edge", "TO": "rc", "DRY_RUN": dry_run, "PACKAGES": pkgs})
            check(res.returncode == 0, f"promote ({pkgs!r}) failed: {res.stderr}")
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            check(len(calls) == count and all(c[-len(tail):] == tail for c in calls), f"promote ({pkgs!r}) argv: {calls!r}")
        print("PASS: promote.yml rejects newlines, validates multi-space live inputs, and keeps `b*  ??` as two exact arguments")

        # unpublish.yml: newline guard, plan argv + GITHUB_ENV handoff, and channel-ordered unpublish argv.
        log.write_text("")
        res = run_step(unpublish_plan, repo, {**base_env, "CHANNELS": "stable", "PACKAGES": "foo\nbar"})
        check(res.returncode != 0 and res.stdout == "::error::Packages must be a single space-separated line\n" and res.stderr == "" and log.read_text() == "", f"unpublish newline: {res.stdout!r}")

        gh_env.write_text("")
        res = run_step(unpublish_plan, repo, {**base_env, "CHANNELS": "stable  edge", "PACKAGES": "b*  ??"})
        check(res.returncode == 0, f"unpublish plan failed: {res.stderr}")
        check([json.loads(line) for line in log.read_text().splitlines()] == [["--channels", "stable  edge", "b*", "??"]], "unpublish plan argv mismatch")
        emitted = dict(line.split("=", 1) for line in gh_env.read_text().splitlines() if line)

        log.write_text("")
        res = run_step(unpublish_run, repo, {**base_env, "CHANNELS": "stable  edge", **emitted})
        check(res.returncode == 0, f"unpublish failed: {res.stderr}")
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        check(
            len(calls) == 2
            and calls[0][-6:] == ["--mirror", "stable", "--arch", "x86_64", "b*", "??"]
            and calls[1][-5:] == ["--mirror", "edge", "--arch", "x86_64", "foo"],
            f"unpublish argv/order mismatch: {calls!r}",
        )
        print("PASS: unpublish.yml rejects newlines, hands off GITHUB_ENV in channel order, and keeps `b*  ??` as two exact arguments")


if __name__ == "__main__":
    check_runner_labels()
    check_basecamp_curls()
    check_workflow_argv_boundaries()
