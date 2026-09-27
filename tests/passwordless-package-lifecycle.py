#!/usr/bin/python3
"""Exercise settings scriptlet callbacks against private, inert filesystem state."""

import re
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CALLBACKS = (
    "_passwordless_package_transition",
    "pre_remove",
    "pre_upgrade",
    "post_install",
    "post_upgrade",
    "post_remove",
)
START = re.compile(r"^([a-z_]+)\(\) ([({])$")


def isolated_callbacks(scriptlet):
    """Copy definitions only; reject any host path left in the executable copy."""
    lines = scriptlet.read_text().splitlines(keepends=True)
    selected = []
    for index, line in enumerate(lines):
        match = START.match(line.rstrip("\n"))
        if not match or match.group(1) not in CALLBACKS:
            continue
        end = "}\n" if match.group(2) == "{" else ")\n"
        for last in range(index + 1, len(lines)):
            if lines[last] == end:
                selected.extend(lines[index : last + 1])
                break
        else:
            raise AssertionError(f"unclosed callback in {scriptlet}: {match.group(1)}")
    source = "".join(selected)
    redirects = {
        "/usr/bin/stat": "fixture_stat",
        "/usr/bin/flock": "flock",
        "/usr/bin/rm": "fixture_rm",
        "/etc/sudoers.d/": '"$FIXTURE_ROOT/etc/sudoers.d"/',
        "/etc/tmpfiles.d/": '"$FIXTURE_ROOT/etc/tmpfiles.d"/',
        "/run/lock/": '"$FIXTURE_ROOT/run/lock"/',
        "/run/": '"$FIXTURE_ROOT/run"/',
        "/run": '"$FIXTURE_ROOT/run"',
    }
    source = re.sub(
        "|".join(re.escape(path) for path in redirects),
        lambda match: redirects[match.group()],
        source,
    )
    # The extracted callbacks may only operate in the fixture. Refuse new
    # absolute system paths until the test explicitly models them.
    executable = "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("#"))
    executable = re.sub(r'"\$FIXTURE_ROOT(?:/[^\"]*)?"', "FIXTURE_PATH", executable)
    host_path = re.search(r"(?<![\w$])/[A-Za-z][A-Za-z0-9_./-]*", executable)
    if host_path:
        raise AssertionError(f"unredirected host path in {scriptlet}: {host_path.group()}")
    return source


HARNESS = r'''#!/bin/bash
set -u
fixture_stat() {
  [[ $# == 3 && $1 == -Lc ]] || return 2
  [[ $3 == "$FIXTURE_ROOT/run" || $3 == "$FIXTURE_ROOT/run/lock" ]] || return 2
  [[ -d $3 && ! -L $3 ]] || return 2
  case "$2" in
    %u) printf '0\n' ;;
    %a) /usr/bin/stat -Lc '%a' "$3" ;;
    *) return 2 ;;
  esac
}
fixture_rm() {
  [[ $# -ge 3 && $1 == -f && $2 == -- ]] || return 2
  shift 2
  local path
  for path in "$@"; do
    case "$path" in
      "$FIXTURE_ROOT/etc/sudoers.d/99-omarchy-nopasswd-"*|"$FIXTURE_ROOT/run/omarchy-sudo-passwordless-package-removing") ;;
      *) return 2 ;;
    esac
    /usr/bin/rm -f -- "$path" || return 1
  done
}
_etc_overrides_apply() { :; }
'''


def run_callback(source, root, callback, failglob=False):
    script = root / "callbacks.sh"
    script.write_text(
        HARNESS
        + source
        + '\n# pacman skips callbacks absent from an older installed scriptlet.\n'
        + 'if [[ ${FIXTURE_FAILGLOB:-} == 1 ]]; then shopt -s failglob; fi\n'
        + 'if declare -F "$1" >/dev/null; then "$1"; fi\n'
    )
    result = subprocess.run(
        ["/bin/bash", "-p", str(script), callback],
        env={"PATH": "/usr/bin:/bin", "FIXTURE_ROOT": str(root), "FIXTURE_FAILGLOB": "1" if failglob else "0"},
        text=True,
        capture_output=True,
        timeout=5,
        check=False,
    )
    return result.returncode, result.stderr.strip()


def fixture(root, rule=True, cleanup=True):
    for directory in ("run/lock", "etc/sudoers.d", "etc/tmpfiles.d"):
        path = root / directory
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(0o755)
    if rule:
        (root / "etc/sudoers.d/99-omarchy-nopasswd-alice").write_text("synthetic rule\n")
    if cleanup:
        (root / "etc/tmpfiles.d/omarchy-nopasswd-sudo.conf").write_text("synthetic cleanup\n")


def run_suite(scriptlet, channel):
    source = isolated_callbacks(scriptlet)
    failures = []
    count = 0

    def check(name, actual, expected):
        nonlocal count
        count += 1
        if actual != expected:
            failures.append(f"{name}: expected {expected!r}, got {actual!r}")
        else:
            print(f"PASS {channel}: {name}")

    with tempfile.TemporaryDirectory(prefix="omarchy-settings-lifecycle-") as temporary:
        base = Path(temporary)
        root = base / "upgrade"
        fixture(root)
        status, _ = run_callback(source, root, "pre_upgrade")
        check("upgrade revokes rule and blocks publication", (status, (root / "etc/sudoers.d/99-omarchy-nopasswd-alice").exists(), (root / "run/omarchy-sudo-passwordless-package-removing").exists()), (0, False, True))
        (root / "etc/sudoers.d/99-omarchy-nopasswd-late").write_text("synthetic late rule\n")
        status, _ = run_callback(source, root, "post_upgrade")
        check("upgrade sweeps late rule before clearing blocker", (status, (root / "etc/sudoers.d/99-omarchy-nopasswd-late").exists(), (root / "run/omarchy-sudo-passwordless-package-removing").exists()), (0, False, False))

        root = base / "remove"
        fixture(root)
        status, _ = run_callback(source, root, "pre_remove")
        check("removal revokes rule and keeps blocker", (status, (root / "etc/sudoers.d/99-omarchy-nopasswd-alice").exists(), (root / "run/omarchy-sudo-passwordless-package-removing").exists()), (0, False, True))
        (root / "etc/sudoers.d/99-omarchy-nopasswd-late").write_text("synthetic late rule\n")
        status, _ = run_callback(source, root, "post_remove")
        check("removal re-sweeps and leaves publication blocked", (status, (root / "etc/sudoers.d/99-omarchy-nopasswd-late").exists(), (root / "run/omarchy-sudo-passwordless-package-removing").exists()), (0, False, True))

        root = base / "failed-revocation"
        fixture(root, rule=False)
        # A directory in the reserved namespace makes rm -f fail safely.
        (root / "etc/sudoers.d/99-omarchy-nopasswd-blocked").mkdir()
        status, _ = run_callback(source, root, "pre_upgrade")
        check("failed revocation refuses upgrade and retains blocker", (status != 0, (root / "etc/sudoers.d/99-omarchy-nopasswd-blocked").is_dir(), (root / "run/omarchy-sudo-passwordless-package-removing").exists()), (True, True, True))
        status, _ = run_callback(source, root, "post_upgrade")
        check("failed install cannot certify nonempty namespace", (status != 0, (root / "run/omarchy-sudo-passwordless-package-removing").exists()), (True, True))
        (root / "etc/sudoers.d/99-omarchy-nopasswd-blocked").rmdir()
        status, _ = run_callback(source, root, "post_upgrade")
        check("retry recovers after namespace clears", (status, (root / "run/omarchy-sudo-passwordless-package-removing").exists()), (0, False))

        root = base / "missing-cleanup"
        fixture(root, rule=False, cleanup=False)
        status, _ = run_callback(source, root, "post_install")
        check("fresh install without boot cleanup stays blocked", (status != 0, (root / "run/omarchy-sudo-passwordless-package-removing").exists()), (True, True))
        (root / "etc/tmpfiles.d/omarchy-nopasswd-sudo.conf").write_text("synthetic cleanup\n")
        status, _ = run_callback(source, root, "post_install")
        check("fresh install retries normally", (status, (root / "run/omarchy-sudo-passwordless-package-removing").exists()), (0, False))

        root = base / "ordinary"
        fixture(root, rule=False)
        status, _ = run_callback(source, root, "post_install")
        check("ordinary install without grant succeeds", (status, (root / "run/omarchy-sudo-passwordless-package-removing").exists()), (0, False))

        root = base / "inherited-failglob"
        fixture(root, rule=False)
        status, _ = run_callback(source, root, "post_install", failglob=True)
        check("no-rule install clears blocker with failglob enabled", (status, (root / "run/omarchy-sudo-passwordless-package-removing").exists(), list((root / "etc/sudoers.d").glob("99-omarchy-nopasswd-*"))), (0, False, []))

    for failure in failures:
        print(f"FAIL {channel}: {failure}", file=sys.stderr)
    print(f"{channel}: {count - len(failures)}/{count} assertions passed")
    return not failures


def main():
    if len(sys.argv) == 1:
        scriptlets = [ROOT / "pkgbuilds" / name / f"{name}.install" for name in ("omarchy-settings", "omarchy-settings-dev")]
    else:
        scriptlets = [Path(path).resolve() for path in sys.argv[1:]]
    results = [run_suite(path, path.parent.name) for path in scriptlets]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
