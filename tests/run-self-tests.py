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
  - verifies every test script under tests/ is registered in build_test_list()
    or EXTERNAL_TESTS with an active caller
"""
import concurrent.futures
import os
import posixpath
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

# Exclude tests/ from sys.path before third-party imports so a test file
# (e.g. tests/yaml.py) cannot shadow system packages.
_TESTS_DIR = str(Path(__file__).resolve().parent)
sys.path = [p for p in sys.path if p and str(Path(p).resolve()) != _TESTS_DIR]

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
        ("append-publish-log", ["./tests/append-publish-log.sh"], {}),
        ("fast-makepkg", ["runuser", "-u", "nobody", "--", "python", "tests/fast-makepkg.py"], {}),
        ("sync-upstream self-test", ["./bin/sync-upstream", "self-test"], {}),
        ("pinned-sources", ["./tests/pinned-sources.sh"], {}),
        ("recipe-hygiene", ["python", "tests/recipe-hygiene.py"], {}),
        ("upstream-watch", ["python", "tests/upstream-watch.py"], {}),
        ("sync-pr-body", ["python", "tests/sync-pr-body.py"], {}),
        ("package-metadata", ["./tests/package-metadata.sh"], {}),
        ("settings-boot-config", ["./tests/settings-boot-config.sh"], {}),
        ("controller", ["./tests/controller.sh"], {}),
        ("dispatch-on-mirror-sync", ["./tests/dispatch-on-mirror-sync.sh"], {}),
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
        ("unpublish-packages", ["./tests/unpublish-packages.sh"], {}),
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


TEST_SCRIPT_SUFFIXES = frozenset({".sh", ".bash", ".py", ".cjs", ".mjs", ".js", ".lua"})
SAFE_SHELL_SHORT_FLAGS = frozenset({"e", "u", "x", "l"})
SAFE_SHELL_OPTIONS = frozenset({"pipefail", "errexit", "nounset", "xtrace"})
PYTHON_FLAGS_WITH_ARG = frozenset({"-W", "-X"})
PYTHON_FLAGS_NO_ARG = frozenset({"-B", "-E", "-I", "-P", "-S", "-s", "-u", "-v"})
NODE_FLAGS_NO_ARG = frozenset({"--test"})
NODE_FLAGS_WITH_ARG = frozenset({"-r", "--require", "--import", "--loader"})
NVIM_FLAGS_NO_ARG = frozenset({"--clean", "-n", "--headless"})
NVIM_FLAGS_WITH_ARG = frozenset({"-i"})
ROOT_PREFIX_RE = re.compile(r"^(?:\$(?:root|PWD)|\$\{(?:root|PWD)\})/(.+)$")
GITHUB_WORKSPACE_RE = re.compile(r"\$\{\{\s*github\.workspace\s*\}\}")
DOCKER_RUN_VALUE_FLAGS = frozenset({
    "-e", "--env", "-v", "--volume", "-w", "--workdir", "--name", "-u", "--user",
    "--entrypoint", "--network", "--platform", "--mount", "--env-file",
})

# Test scripts under tests/ not directly launched by build_test_list(), mapped
# to the workflow file or registered shell wrapper (from build_test_list()) that
# invokes them. Workflow callers must run in an unconditional job/step (`if:`
# absent) at repo root.
EXTERNAL_TESTS = {
    "tests/aurora-edge/configure.py": ".github/workflows/aurora-config.yml",
    "tests/aurora-firmware-ordering.py": "pkgbuilds/omarchy-aurora-firmware/test.sh",
    "tests/build-isolation.sh": ".github/workflows/test.yml",
    "tests/builder-image.cjs": ".github/workflows/test.yml",
    "tests/neovim-remote-clipboard.lua": "tests/neovim-remote-clipboard.sh",
    "tests/pr-workflow-approval.cjs": ".github/workflows/test.yml",
    "tests/run-self-tests.py": ".github/workflows/test.yml",
    "tests/sync-upstream-summary.cjs": ".github/workflows/test.yml",
}


def _load_yaml(path):
    try:
        import yaml
    except ModuleNotFoundError as exc:
        raise RuntimeError(
            "PyYAML is required to verify workflow test coverage (install python-yaml / pyyaml)"
        ) from exc
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _has_shebang(path):
    try:
        with path.open("rb") as fh:
            return fh.read(2) == b"#!"
    except OSError:
        return False


def _discover_test_scripts(root):
    """Return (scripts, errors) for test entry points under tests/.

    Convention: every regular file under tests/ outside top-level tests/fixtures/,
    __pycache__/, and __init__.py package markers that has a TEST_SCRIPT_SUFFIXES
    extension, an execute bit, or an extensionless `#!` shebang is a test entry
    point. Shared helper libraries belong in helpers/ and fixture data in
    tests/fixtures/. Symlinks are rejected.
    """
    tests_dir = root / "tests"
    if not tests_dir.is_dir():
        return set(), []
    found, errors = set(), []
    for path in sorted(tests_dir.rglob("*")):
        rel = path.relative_to(root)
        if rel.parts[1] == "fixtures" or "__pycache__" in rel.parts[1:] or path.name == "__init__.py":
            continue
        if path.is_symlink():
            errors.append(f"{rel.as_posix()}: test entry must not be a symlink")
            continue
        if not path.is_file():
            continue
        if (
            path.suffix in TEST_SCRIPT_SUFFIXES
            or bool(path.stat().st_mode & 0o111)
            or (not path.suffix and _has_shebang(path))
        ):
            found.add(rel.as_posix())
    return found, errors


def _clean_repo_rel(tok, *, allow_root_vars=False):
    if not tok:
        return None
    raw = tok
    if allow_root_vars:
        m = ROOT_PREFIX_RE.match(tok)
        if m:
            raw = m.group(1)
    if raw.startswith("/") or "$" in raw:
        return None
    parts = [p for p in raw.split("/") if p and p != "."]
    if not parts or ".." in parts:
        return None
    rel = "/".join(parts)
    return rel if rel.startswith(("tests/", "pkgbuilds/")) else None


def _runner_target(cmd, *, allow_root_vars=False, allow_nvim=False):
    """Return (target_rel, error) for a supported test invocation command.

    Returns (None, None) for non-tests/pkgbuilds commands (e.g. bin/* self-tests),
    (target_rel, None) for supported test invocations, or (None, reason) when a
    command mentions a tests/ or pkgbuilds/ path in an unsupported/dry-run form.
    """
    argv = list(cmd)
    if len(argv) >= 4 and argv[0] == "runuser" and argv[1] == "-u" and argv[3] == "--":
        argv = argv[4:]
    if not argv:
        return None, None

    mentions_repo_test = any(_clean_repo_rel(a, allow_root_vars=allow_root_vars) is not None for a in argv)
    head = argv[0]
    if "/" in head and not head.startswith("/"):
        rel = _clean_repo_rel(head, allow_root_vars=allow_root_vars)
        if rel:
            return rel, None
        return None, None

    base = posixpath.basename(head)
    if head != base and head not in (f"/usr/bin/{base}", f"/bin/{base}"):
        return (None, f"unsupported interpreter path {head!r}") if mentions_repo_test else (None, None)

    i = 1
    if base in {"bash", "sh"}:
        while i < len(argv):
            tok = argv[i]
            if tok == "--":
                i += 1
                break
            if tok.startswith("-") and tok != "-":
                if tok.startswith("--"):
                    return (None, f"unsupported shell flag {tok!r}") if mentions_repo_test else (None, None)
                flags = tok[1:]
                if flags.endswith("o"):
                    if not set(flags[:-1]).issubset(SAFE_SHELL_SHORT_FLAGS):
                        return (None, f"unsupported shell flags {tok!r}") if mentions_repo_test else (None, None)
                    if i + 1 >= len(argv) or argv[i + 1] not in SAFE_SHELL_OPTIONS:
                        opt = argv[i + 1] if i + 1 < len(argv) else ""
                        return (None, f"unsupported shell option {opt!r}") if mentions_repo_test else (None, None)
                    i += 2
                elif set(flags).issubset(SAFE_SHELL_SHORT_FLAGS):
                    i += 1
                else:
                    return (None, f"unsupported shell flags {tok!r}") if mentions_repo_test else (None, None)
                continue
            break
    elif base in {"python", "python3"}:
        while i < len(argv):
            tok = argv[i]
            if tok == "--":
                i += 1
                break
            if tok in PYTHON_FLAGS_NO_ARG:
                i += 1
                continue
            if tok in PYTHON_FLAGS_WITH_ARG:
                i += 2
                continue
            if tok.startswith("-"):
                return (None, f"unsupported python flag {tok!r}") if mentions_repo_test else (None, None)
            break
    elif base == "node":
        while i < len(argv):
            tok = argv[i]
            if tok == "--":
                i += 1
                break
            if tok in NODE_FLAGS_NO_ARG:
                i += 1
                continue
            if tok in NODE_FLAGS_WITH_ARG:
                i += 2
                continue
            if tok.startswith("-"):
                return (None, f"unsupported node flag {tok!r}") if mentions_repo_test else (None, None)
            break
    elif allow_nvim and base == "nvim":
        while i < len(argv):
            tok = argv[i]
            if tok == "-l":
                i += 1
                break
            if tok in NVIM_FLAGS_NO_ARG:
                i += 1
                continue
            if tok in NVIM_FLAGS_WITH_ARG:
                i += 2
                continue
            return (None, f"unsupported nvim flag {tok!r}") if mentions_repo_test else (None, None)
        else:
            return (None, "nvim invocation missing -l") if mentions_repo_test else (None, None)
    else:
        return (None, f"unsupported runner {head!r}") if mentions_repo_test else (None, None)

    rel = _clean_repo_rel(argv[i], allow_root_vars=allow_root_vars) if i < len(argv) else None
    if rel:
        return rel, None
    return (None, f"unsupported runner command {cmd!r}") if mentions_repo_test else (None, None)


def _scan_shell_line(line, sq, dq, start_at_boundary=True):
    """Scan one physical line carrying quote state; return (code_part, sq, dq, cont)."""
    i, n = 0, len(line)
    comment_at = n
    cont = False
    while i < n:
        ch = line[i]
        if sq:
            sq = ch != "'"
            i += 1
        elif dq:
            if ch == "\\" and i + 1 < n:
                i += 2
            elif ch == "\\" and i + 1 == n:
                cont, i = True, i + 1
            else:
                dq = ch != '"'
                i += 1
        elif ch == "\\" and i + 1 < n:
            i += 2
        elif ch == "\\" and i + 1 == n:
            cont, i = True, i + 1
        elif ch == "'":
            sq = True
            i += 1
        elif ch == '"':
            dq = True
            i += 1
        elif ch == "#" and ((i == 0 and start_at_boundary) or (i > 0 and line[i - 1] in " \t;&|()")):
            comment_at = i
            break
        else:
            i += 1
    code_part = line[:comment_at - 1] if cont else line[:comment_at]
    return code_part, sq, dq, cont


def _extract_heredocs(code):
    """Return [(delim, strip_tabs), ...] for unquoted << / <<- operators in a logical command line."""
    heredocs = []
    sq = dq = False
    i, n = 0, len(code)
    while i < n:
        ch = code[i]
        if sq:
            sq = ch != "'"
            i += 1
        elif dq:
            if ch == "\\" and i + 1 < n:
                i += 2
            else:
                dq = ch != '"'
                i += 1
        elif ch == "\\" and i + 1 < n:
            i += 2
        elif ch == "'":
            sq = True
            i += 1
        elif ch == '"':
            dq = True
            i += 1
        elif ch == "<" and i + 1 < n and code[i + 1] == "<":
            if i + 2 < n and code[i + 2] == "<":
                i += 3
                continue
            j = i + 2
            strip_tabs = j < n and code[j] == "-"
            if strip_tabs:
                j += 1
            while j < n and code[j] in " \t":
                j += 1
            delim, saw_delim, quoted = [], False, False
            while j < n and code[j] not in " \t\n;&|<>()":
                saw_delim = True
                if code[j] in "'\"":
                    quoted = True
                    q = code[j]
                    j += 1
                    while j < n and code[j] != q:
                        if q == '"' and code[j] == "\\" and j + 1 < n and code[j + 1] in '"\\$`\n':
                            delim.append(code[j + 1])
                            j += 2
                        else:
                            delim.append(code[j])
                            j += 1
                    if j < n:
                        j += 1
                elif code[j] == "\\" and j + 1 < n:
                    quoted = True
                    delim.append(code[j + 1])
                    j += 2
                else:
                    delim.append(code[j])
                    j += 1
            if saw_delim:
                heredocs.append(("".join(delim), strip_tabs, quoted))
            i = j
        else:
            i += 1
    return heredocs


def _split_simple_commands(code):
    """Split a shell logical line on unquoted ;/&/| into commands, omitting unquoted redirections."""
    cmds, cur, word = [], [], []
    in_word = False
    skip_redir_target = False
    sq = dq = False
    i, n = 0, len(code)

    def flush_word():
        nonlocal in_word, skip_redir_target
        if not in_word:
            return
        tok = "".join(word)
        word.clear()
        in_word = False
        if skip_redir_target:
            skip_redir_target = False
        else:
            cur.append(tok)

    def flush_cmd():
        nonlocal skip_redir_target
        flush_word()
        skip_redir_target = False
        if cur:
            cmds.append(list(cur))
            cur.clear()

    while i < n:
        ch = code[i]
        if sq:
            if ch == "'":
                sq = False
            else:
                word.append(ch)
            i += 1
        elif dq:
            if ch == "\\" and i + 1 < n and code[i + 1] in '"\\$`\n':
                word.append(code[i + 1])
                i += 2
            elif ch == '"':
                dq = False
                i += 1
            else:
                word.append(ch)
                i += 1
        elif ch == "\\" and i + 1 < n:
            in_word = True
            word.append(code[i + 1])
            i += 2
        elif ch == "'":
            in_word = True
            sq = True
            i += 1
        elif ch == '"':
            in_word = True
            dq = True
            i += 1
        elif ch in " \t\n":
            flush_word()
            i += 1
        elif ch == "&" and i + 1 < n and code[i + 1] == ">":
            flush_word()
            i += 3 if (i + 2 < n and code[i + 2] == ">") else 2
            skip_redir_target = True
        elif ch in ";&|":
            flush_cmd()
            if i + 1 < n and code[i + 1] == ch and ch in "&|":
                i += 2
            else:
                i += 1
        elif ch in "<>":
            # Drop optional numeric fd prefix attached to the redirection operator (e.g. 2>/dev/null).
            if in_word and "".join(word).isdigit():
                word.clear()
                in_word = False
            else:
                flush_word()
            op_len = 1
            if i + 1 < n and code[i + 1] in "<>&|":
                op_len = 2
                if ch == "<" and i + 2 < n and code[i + 2] == "<":
                    op_len = 3
            i += op_len
            skip_redir_target = True
        else:
            in_word = True
            word.append(ch)
            i += 1
    if sq or dq:
        raise ValueError("unclosed quote")
    flush_cmd()
    return cmds


def _docker_bash_payload(tokens):
    """Return the inline bash -c/-lc script when bash/sh is the container command of `docker run`."""
    if len(tokens) < 5 or tokens[0] != "docker" or tokens[1] != "run":
        return None
    i = 2
    while i < len(tokens) and tokens[i].startswith("-"):
        flag = tokens[i]
        if flag == "--entrypoint" or flag.startswith("--entrypoint="):
            return None
        if "=" in flag:
            i += 1
        elif flag in DOCKER_RUN_VALUE_FLAGS:
            i += 2
        else:
            i += 1
    # tokens[i] is the image name; tokens[i + 1:] is the container command.
    cmd = tokens[i + 1:]
    if len(cmd) >= 3 and cmd[0] in {"bash", "sh"} and cmd[1] in {"-c", "-lc"}:
        return cmd[2]
    return None


def _line_invokes_test(text, test_rel):
    """Return True if an active non-comment, non-heredoc command in text invokes test_rel."""
    heredocs = []
    hd_buf = []
    buf = []
    sq = dq = False
    prev_boundary = True
    for raw in text.splitlines():
        if heredocs:
            delim, strip_tabs, quoted = heredocs[0]
            if not quoted and raw.endswith("\\") and not raw.endswith("\\\\"):
                hd_buf.append(raw[:-1])
                continue
            cand = "".join(hd_buf) + raw
            hd_buf = []
            if (cand.lstrip("\t") if strip_tabs else cand) == delim:
                heredocs.pop(0)
            continue
        code_part, sq, dq, cont = _scan_shell_line(raw, sq, dq, start_at_boundary=prev_boundary)
        prev_boundary = (not cont) or (not code_part) or (code_part[-1] in " \t;&|()")
        if not buf and not sq and not dq and not cont and not code_part.strip():
            continue
        buf.append(code_part)
        if cont:
            continue
        if sq or dq:
            buf.append("\n")
            continue
        code = "".join(buf).strip()
        buf = []
        if not code:
            continue
        heredocs.extend(_extract_heredocs(code))
        code = GITHUB_WORKSPACE_RE.sub("$PWD", code)
        try:
            cmds = _split_simple_commands(code)
        except ValueError:
            continue
        for tokens in cmds:
            payload = _docker_bash_payload(tokens)
            if payload is not None:
                if _line_invokes_test(payload, test_rel):
                    return True
                continue
            target, err = _runner_target(tokens, allow_root_vars=True, allow_nvim=True)
            if err is None and target == test_rel:
                return True
    return False


def _is_repo_root_wd(wd):
    if not wd:
        return True
    if not isinstance(wd, str):
        return False
    norm = wd.strip()
    return norm in {".", "./"} or (
        norm.startswith("${{") and norm.endswith("}}") and norm[3:-2].strip() == "github.workspace"
    )


def _workflow_invokes_test(doc, test_rel):
    if not isinstance(doc, dict):
        return False
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        return False
    wf_run = (doc.get("defaults") or {}).get("run") or {}
    wf_wd = wf_run.get("working-directory")
    wf_shell = wf_run.get("shell")
    for job in jobs.values():
        if not isinstance(job, dict) or job.get("if") is not None:
            continue
        job_run = (job.get("defaults") or {}).get("run") or {}
        job_wd = job_run.get("working-directory") or wf_wd
        job_shell = job_run.get("shell") or wf_shell
        for step in job.get("steps") or ():
            eff_shell = step.get("shell") or job_shell if isinstance(step, dict) else None
            if (
                isinstance(step, dict)
                and step.get("if") is None
                and (eff_shell is None or eff_shell == "bash")
                and _is_repo_root_wd(step.get("working-directory") or job_wd)
                and isinstance(step.get("run"), str)
                and _line_invokes_test(step["run"], test_rel)
            ):
                return True
    return False


def check_orphan_tests(root, test_items, external_tests=EXTERNAL_TESTS):
    """Return error messages for unregistered test scripts or stale/broken EXTERNAL_TESTS."""
    discovered, errors = _discover_test_scripts(root)
    runner_targets = set()

    for name, cmd, _ in test_items:
        target, err = _runner_target(cmd)
        if err:
            errors.append(f"{name}: {err}")
        elif target:
            runner_targets.add(target)

    accounted = set(runner_targets)
    wf_cache = {}
    for test_rel, caller_rel in sorted(external_tests.items()):
        if test_rel not in discovered:
            errors.append(f"{test_rel}: stale EXTERNAL_TESTS entry (file not found)")
            continue
        accounted.add(test_rel)
        if caller_rel.startswith(".github/workflows/"):
            if caller_rel not in wf_cache:
                wf_path = root / caller_rel
                wf_cache[caller_rel] = _load_yaml(wf_path) if wf_path.is_file() else {}
            if not _workflow_invokes_test(wf_cache[caller_rel], test_rel):
                errors.append(f"{test_rel}: not invoked by unconditional repo-root step in {caller_rel}")
        else:
            if caller_rel not in runner_targets:
                errors.append(f"{test_rel}: wrapper '{caller_rel}' is not registered in build_test_list()")
            else:
                caller_path = root / caller_rel
                if not (
                    caller_path.is_file()
                    and _line_invokes_test(caller_path.read_text(encoding="utf-8", errors="replace"), test_rel)
                ):
                    errors.append(f"{test_rel}: not invoked by wrapper '{caller_rel}'")

    for orphan in sorted(discovered - accounted):
        errors.append(f"{orphan}: unregistered test script (register in tests/run-self-tests.py)")

    return errors


def run_orphan_guard_self_test():
    with tempfile.TemporaryDirectory(prefix="omarchy-orphan-guard-") as tmp:
        root = Path(tmp)
        for rel, content in (
            ("tests/registered.sh", "#!/bin/sh\n"),
            ("tests/shell-euo.sh", "#!/bin/bash\n"),
            ("tests/shell-syntax-only.sh", "#!/bin/bash\n"),
            ("tests/shell-noexec.sh", "#!/bin/bash\n"),
            ("tests/nested/registered.py", ""),
            ("tests/nested/__init__.py", ""),
            ("tests/nobody.py", ""),
            ("tests/workflow.cjs", ""),
            ("tests/wf-shell-euo.sh", "#!/bin/bash\n"),
            ("tests/wf-shell-en.sh", "#!/bin/bash\n"),
            ("tests/wf-heredoc.sh", "#!/bin/bash\n"),
            ("tests/wf-workspace.sh", "#!/bin/bash\n"),
            ("tests/wf-after-bs-comment.sh", "#!/bin/bash\n"),
            ("tests/wf-after-inline-bs-comment.sh", "#!/bin/bash\n"),
            ("tests/wf-after-quoted-heredoc.sh", "#!/bin/bash\n"),
            ("tests/wf-multiline-str.sh", "#!/bin/bash\n"),
            ("tests/wf-after-cont-heredoc.sh", "#!/bin/bash\n"),
            ("tests/wf-semicolon.sh", "#!/bin/bash\n"),
            ("tests/wf-op-comment.sh", "#!/bin/bash\n"),
            ("tests/wf-quoted-sep.sh", "#!/bin/bash\n"),
            ("tests/wf-escaped-sep.sh", "#!/bin/bash\n"),
            ("tests/wf-escaped-heredoc.sh", "#!/bin/bash\n"),
            ("tests/wf-attached-redir.sh", "#!/bin/bash\n"),
            ("tests/wf-docker-echo.sh", "#!/bin/bash\n"),
            ("tests/wf-docker-entrypoint.sh", "#!/bin/bash\n"),
            ("tests/wf-amp-redir.sh", "#!/bin/bash\n"),
            ("tests/wf-clobber-redir.sh", "#!/bin/bash\n"),
            ("tests/wf-spaced-heredoc.sh", "#!/bin/bash\n"),
            ("tests/wf-empty-heredoc.sh", "#!/bin/bash\n"),
            ("tests/wf-dq-esc-heredoc.sh", "#!/bin/bash\n"),
            ("tests/wf-split-delim-heredoc.sh", "#!/bin/bash\n"),
            ("tests/wf-hash-cont-delim.sh", "#!/bin/bash\n"),
            ("tests/wf-cont-close-heredoc.sh", "#!/bin/bash\n"),
            ("tests/wf-bad-shell.sh", "#!/bin/bash\n"),
            ("tests/pkg-child.py", ""),
            ("tests/lua-driver.sh", '#!/bin/bash\nnvim --clean -n --headless -i NONE -l "$root/tests/lua-driver.lua"\n'),
            ("tests/lua-driver.lua", ""),
            ("tests/orphan.sh", "#!/bin/sh\n"),
            ("tests/orphan.bash", "#!/bin/bash\n"),
            ("tests/orphan-shebang", "#!/bin/bash\necho hi\n"),
            ("tests/orphan-exec", "#!/bin/sh\n"),
            ("tests/commented.cjs", ""),
            ("tests/echoed.cjs", ""),
            ("tests/conditional.py", ""),
            ("tests/wrong-wd.py", ""),
            ("tests/test-f-only.py", ""),
            ("tests/test-f-wrapper.sh", '#!/bin/bash\ntest -f "$root/tests/test-f-only.py"\n'),
            ("tests/unwrapped-child.py", ""),
            ("tests/fixtures/helper.sh", "#!/bin/sh\n"),
            ("tests/build-isolation.Dockerfile", "FROM scratch\n"),
            ("pkgbuilds/demo/test.sh", '#!/bin/bash\npython "$root/tests/pkg-child.py"\n'),
            (
                ".github/workflows/ci.yml",
                "jobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n"
                "      - run: |\n"
                "          # node --test tests/commented.cjs\n"
                "          echo tests/echoed.cjs\n"
                "          node --test tests/workflow.cjs\n"
                "          bash -euo pipefail tests/wf-shell-euo.sh\n"
                "          bash -en tests/wf-shell-en.sh\n"
                "          cat <<'EOF'\n"
                "          bash tests/wf-heredoc.sh\n"
                "          EOF\n"
                "          bash ${{ github.workspace }}/tests/wf-workspace.sh\n"
                "          # trailing backslash comment \\\n"
                "          bash tests/wf-after-bs-comment.sh\n"
                "          echo setup # inline note \\\n"
                "          bash tests/wf-after-inline-bs-comment.sh\n"
                "          echo 'Example <<EOF'\n"
                "          bash tests/wf-after-quoted-heredoc.sh\n"
                "          printf '%s\\n' 'Example:\n"
                "          bash tests/wf-multiline-str.sh\n"
                "          '\n"
                "          cat <<EOF \\\n"
                "            > /dev/null\n"
                "          body\n"
                "          EOF\n"
                "          bash tests/wf-after-cont-heredoc.sh\n"
                "          bash tests/wf-semicolon.sh; echo done\n"
                "          echo setup;# op-adjacent \\\n"
                "          bash tests/wf-op-comment.sh\n"
                "          printf '%s ' '|' bash tests/wf-quoted-sep.sh\n"
                "          printf '%s ' \\; bash tests/wf-escaped-sep.sh\n"
                "          cat <<\\EOF >/dev/null\n"
                "          body\n"
                "          EOF\n"
                "          bash tests/wf-escaped-heredoc.sh\n"
                "          bash tests/wf-attached-redir.sh>/dev/null\n"
                "          docker run archlinux echo bash -lc 'bash tests/wf-docker-echo.sh'\n"
                "          docker run --entrypoint /bin/echo archlinux bash -lc 'bash tests/wf-docker-entrypoint.sh'\n"
                "          echo &>/dev/null tests/wf-amp-redir.sh\n"
                "          bash >|/dev/null tests/wf-clobber-redir.sh\n"
                "          cat <<'END HELP' >/dev/null\n"
                "          docs\n"
                "          END HELP\n"
                "          bash tests/wf-spaced-heredoc.sh\n"
                "          cat <<''\n"
                "          bash tests/wf-empty-heredoc.sh\n"
                "\n"
                "          cat <<\"END\\ HELP\" >/dev/null\n"
                "          docs\n"
                "          END\\ HELP\n"
                "          bash tests/wf-dq-esc-heredoc.sh\n"
                "          cat <<END\\\n"
                "          OF >/dev/null\n"
                "          docs\n"
                "          ENDOF\n"
                "          bash tests/wf-split-delim-heredoc.sh\n"
                "          cat <<END\\\n"
                "          #TAG >/dev/null\n"
                "          docs\n"
                "          END#TAG\n"
                "          bash tests/wf-hash-cont-delim.sh\n"
                "          cat <<CLOSEEOF >/dev/null\n"
                "          docs\n"
                "          CLOSE\\\n"
                "          EOF\n"
                "          bash tests/wf-cont-close-heredoc.sh\n"
                "      - shell: bash -n {0}\n"
                "        run: bash tests/wf-bad-shell.sh\n"
                "      - if: ${{ false && success() }}\n"
                "        run: python tests/conditional.py\n"
                "      - working-directory: pkgbuilds\n"
                "        run: python tests/wrong-wd.py\n",
            ),
        ):
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content, encoding="utf-8")
        (root / "tests/orphan-exec").chmod(0o755)
        (root / "tests/link.sh").symlink_to(root / "tests/registered.sh")

        items = [
            ("registered", ["./tests/registered.sh"], {}),
            ("shell-euo", ["bash", "-euo", "pipefail", "tests/shell-euo.sh"], {}),
            ("shell-syntax-only", ["bash", "-en", "tests/shell-syntax-only.sh"], {}),
            ("shell-noexec", ["bash", "-euo", "noexec", "tests/shell-noexec.sh"], {}),
            ("nested", ["python", "tests/nested/registered.py"], {}),
            ("nobody", ["runuser", "-u", "nobody", "--", "python", "tests/nobody.py"], {}),
            ("lua-driver", ["./tests/lua-driver.sh"], {}),
            ("test-f-wrapper", ["bash", "tests/test-f-wrapper.sh"], {}),
            ("pkgbuilds/demo/test.sh", ["bash", "pkgbuilds/demo/test.sh"], {}),
        ]
        external = {
            "tests/workflow.cjs": ".github/workflows/ci.yml",
            "tests/wf-shell-euo.sh": ".github/workflows/ci.yml",
            "tests/wf-shell-en.sh": ".github/workflows/ci.yml",
            "tests/wf-heredoc.sh": ".github/workflows/ci.yml",
            "tests/wf-workspace.sh": ".github/workflows/ci.yml",
            "tests/wf-after-bs-comment.sh": ".github/workflows/ci.yml",
            "tests/wf-after-inline-bs-comment.sh": ".github/workflows/ci.yml",
            "tests/wf-after-quoted-heredoc.sh": ".github/workflows/ci.yml",
            "tests/wf-multiline-str.sh": ".github/workflows/ci.yml",
            "tests/wf-after-cont-heredoc.sh": ".github/workflows/ci.yml",
            "tests/wf-semicolon.sh": ".github/workflows/ci.yml",
            "tests/wf-op-comment.sh": ".github/workflows/ci.yml",
            "tests/wf-quoted-sep.sh": ".github/workflows/ci.yml",
            "tests/wf-escaped-sep.sh": ".github/workflows/ci.yml",
            "tests/wf-escaped-heredoc.sh": ".github/workflows/ci.yml",
            "tests/wf-attached-redir.sh": ".github/workflows/ci.yml",
            "tests/wf-docker-echo.sh": ".github/workflows/ci.yml",
            "tests/wf-docker-entrypoint.sh": ".github/workflows/ci.yml",
            "tests/wf-amp-redir.sh": ".github/workflows/ci.yml",
            "tests/wf-clobber-redir.sh": ".github/workflows/ci.yml",
            "tests/wf-spaced-heredoc.sh": ".github/workflows/ci.yml",
            "tests/wf-empty-heredoc.sh": ".github/workflows/ci.yml",
            "tests/wf-dq-esc-heredoc.sh": ".github/workflows/ci.yml",
            "tests/wf-split-delim-heredoc.sh": ".github/workflows/ci.yml",
            "tests/wf-hash-cont-delim.sh": ".github/workflows/ci.yml",
            "tests/wf-cont-close-heredoc.sh": ".github/workflows/ci.yml",
            "tests/wf-bad-shell.sh": ".github/workflows/ci.yml",
            "tests/commented.cjs": ".github/workflows/ci.yml",
            "tests/echoed.cjs": ".github/workflows/ci.yml",
            "tests/conditional.py": ".github/workflows/ci.yml",
            "tests/wrong-wd.py": ".github/workflows/ci.yml",
            "tests/pkg-child.py": "pkgbuilds/demo/test.sh",
            "tests/lua-driver.lua": "tests/lua-driver.sh",
            "tests/test-f-only.py": "tests/test-f-wrapper.sh",
            "tests/unwrapped-child.py": "tests/missing-wrapper.sh",
            "tests/stale.py": ".github/workflows/ci.yml",
        }
        errors = check_orphan_tests(root, items, external_tests=external)
        expected = [
            "tests/link.sh: test entry must not be a symlink",
            "shell-syntax-only: unsupported shell flags '-en'",
            "shell-noexec: unsupported shell option 'noexec'",
            "tests/commented.cjs: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/conditional.py: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/echoed.cjs: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/stale.py: stale EXTERNAL_TESTS entry (file not found)",
            "tests/test-f-only.py: not invoked by wrapper 'tests/test-f-wrapper.sh'",
            "tests/unwrapped-child.py: wrapper 'tests/missing-wrapper.sh' is not registered in build_test_list()",
            "tests/wf-amp-redir.sh: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/wf-bad-shell.sh: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/wf-docker-echo.sh: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/wf-docker-entrypoint.sh: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/wf-empty-heredoc.sh: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/wf-escaped-sep.sh: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/wf-heredoc.sh: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/wf-multiline-str.sh: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/wf-quoted-sep.sh: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/wf-shell-en.sh: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/wrong-wd.py: not invoked by unconditional repo-root step in .github/workflows/ci.yml",
            "tests/orphan-exec: unregistered test script (register in tests/run-self-tests.py)",
            "tests/orphan-shebang: unregistered test script (register in tests/run-self-tests.py)",
            "tests/orphan.bash: unregistered test script (register in tests/run-self-tests.py)",
            "tests/orphan.sh: unregistered test script (register in tests/run-self-tests.py)",
            "tests/shell-noexec.sh: unregistered test script (register in tests/run-self-tests.py)",
            "tests/shell-syntax-only.sh: unregistered test script (register in tests/run-self-tests.py)",
        ]
        if errors != expected:
            raise AssertionError(f"orphan guard self-test mismatch:\ngot:      {errors!r}\nexpected: {expected!r}")


def run_orphan_guard(test_items):
    t0 = time.monotonic()
    try:
        run_orphan_guard_self_test()
        errors = check_orphan_tests(ROOT, test_items)
    except Exception as exc:
        dt = time.monotonic() - t0
        print(f"=== orphan-tests [FAIL (rc=1), {dt:.2f}s] ===\nFAIL: {exc}", flush=True)
        return ("orphan-tests", 1, dt)

    dt = time.monotonic() - t0
    if errors:
        print(f"=== orphan-tests [FAIL (rc=1), {dt:.2f}s] ===", flush=True)
        for err in errors:
            print(f"FAIL: {err}", flush=True)
        return ("orphan-tests", 1, dt)

    print(f"=== orphan-tests [PASS, {dt:.2f}s] ===", flush=True)
    return ("orphan-tests", 0, dt)


def main():
    if len(sys.argv) > 1:
        if sys.argv[1:] == ["--self-test"]:
            off_cpu, cpu_bound = build_test_list()
            return run_orphan_guard(off_cpu + cpu_bound)[1]
        print(f"Usage: {sys.argv[0]} [--self-test]", file=sys.stderr)
        return 2

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
        results = [run_orphan_guard(off_cpu + cpu_bound)]

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
