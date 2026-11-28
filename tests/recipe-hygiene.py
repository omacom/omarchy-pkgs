#!/usr/bin/env python3
"""Enforce recipe hygiene invariants across pkgbuilds/ so fixed issues do not regress.

Checks every package directory under pkgbuilds/ (for both x86_64 and aarch64),
plus self-tests against synthetic good and bad fixtures:
  1. No mutable HTTP(S) branch archives (/archive/refs/heads/, /archive/HEAD.*,
     /archive/main|master.*, codeload branch archives, GitHub /tarball|zipball/...,
     GitLab /-/archive/main|master/).
  2. No SKIP checksums on HTTP(S) non-signature sources (except explicit PGP-verified
     apt repository metadata allowlist), and every active source array has matching
     checksums.
  3. No generic/version-only source archive filenames without a :: prefix
     (prevents shared SRCDEST collisions and namcap Non-unique source name warnings).
  4. No $startdir / ${startdir...} references in PKGBUILDs (prevents namcap errors).
  5. Package-local tests are discoverable and executable:
     - every pkgbuilds/*/test.sh is executable
     - no stray pkgbuilds/*/test-*.sh files outside test.sh
     - every pkgbuilds/*/tests/test_*.py suite is invoked by pkgbuilds/<pkg>/test.sh
  6. No unreferenced top-level *.patch or *.install files in pkgbuilds/*/.
"""
import os
import re
import stat
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
PKGBUILDS_DIR = Path(os.environ.get("PKGBUILDS_DIR", str(ROOT / "pkgbuilds"))).resolve()

# Packages whose upstream apt Release/Packages metadata is verified via PGP
# signature rather than static checksums.
SKIP_HTTP_ALLOWLIST = {
    ("spotify", "https://repository.spotify.com/dists/testing/Release"),
    ("spotify", "https://repository.spotify.com/dists/testing/non-free/binary-amd64/Packages"),
}

ARCH_SUM_ALGOS = ("sha256", "sha512", "b2", "sha224", "sha384", "sha1", "md5")

MUTABLE_PATH_RE = re.compile(
    r"("
    r"/archive/(refs/heads/|(HEAD|main|master)\.(tar\.(gz|xz|bz2|zst)|tgz|zip)$)"
    r"|/(tarball|zipball)/(refs/heads/|HEAD$|main$|master$)"
    r"|/(tar\.gz|zip)/(refs/heads/|HEAD$|main$|master$)"
    r"|/-/archive/(HEAD|main|master)/"
    r")",
    re.IGNORECASE,
)
SIG_PATH_RE = re.compile(r"\.(sig|asc|gpg|sign|minisig)$", re.IGNORECASE)
GENERIC_ARCHIVE_RE = re.compile(
    r"^(v?\d[\d._-]*(?:[-._]?(?:alpha|beta|rc|pre|dev|post)[\d._-]*)?|latest|download|linux|archive|release|main|master|head)"
    r"(\.(tar\.(gz|xz|bz2|zst)|tgz|zip))?$",
    re.IGNORECASE,
)
GENERIC_BARE_NAMES = {"latest", "download", "linux"}
STARTDIR_RE = re.compile(r"\$(?:startdir\b|\{startdir(?:\}|[^a-zA-Z0-9_}][^}]*\}))")

END_SENTINEL = "__RECIPE_HYGIENE_END__"

EXTRACT_BASH = r"""
set +e
# shellcheck disable=SC1090
source "$1" >/dev/null 2>&1 || exit 2
arch="$2"
for v in source "source_${arch}"; do
  eval "arr=(\"\${${v}[@]}\")"
  for x in "${arr[@]}"; do printf "SRC|%s|%s\n" "$v" "$x"; done
done
for alg in sha256 sha512 b2 sha224 sha384 sha1 md5; do
  for suf in "" "_${arch}"; do
    v="${alg}sums${suf}"
    eval "arr=(\"\${${v}[@]}\")"
    for x in "${arr[@]}"; do printf "SUM|%s|%s\n" "$v" "$x"; done
  done
done
printf "VAR|pkgname|%s\n" "${pkgname[0]:-}"
printf "VAR|_pkgname|%s\n" "${_pkgname:-}"
printf "VAR|_name|%s\n" "${_name:-}"
printf "VAR|install|%s\n" "${install:-}"
printf "%s\n" "__RECIPE_HYGIENE_END__"
"""


def strip_comments(line: str) -> str:
    """Return the shell line with unquoted # comments removed, preserving quoted text."""
    out = []
    in_sq = False
    in_dq = False
    escaped = False
    word_start = True
    for ch in line:
        if escaped:
            out.append(ch)
            escaped = False
            word_start = False
            continue
        if ch == "\\" and not in_sq:
            escaped = True
            out.append(ch)
            word_start = False
            continue
        if ch == "'" and not in_dq:
            in_sq = not in_sq
            out.append(ch)
            word_start = False
            continue
        if ch == "\"" and not in_sq:
            in_dq = not in_dq
            out.append(ch)
            word_start = False
            continue
        if ch == "#" and not in_sq and not in_dq and word_start:
            break
        out.append(ch)
        word_start = (not in_sq and not in_dq and ch in " \t;|&()")
    return "".join(out)


def strip_single_quotes_and_comments(line: str) -> str:
    """Return the non-comment, non-single-quoted, non-escaped-dollar shell portion of a line."""
    out = []
    in_sq = False
    in_dq = False
    escaped = False
    word_start = True
    for ch in line:
        if escaped:
            if not in_sq and ch != "$":
                out.append(ch)
            escaped = False
            word_start = False
            continue
        if ch == "\\" and not in_sq:
            escaped = True
            word_start = False
            continue
        if ch == "\x27" and not in_dq:
            in_sq = not in_sq
            word_start = False
            continue
        if ch == "\"" and not in_sq:
            in_dq = not in_dq
            word_start = False
            continue
        if ch == "#" and not in_sq and not in_dq and word_start:
            break
        if not in_sq:
            out.append(ch)
        word_start = (not in_sq and not in_dq and ch in " \t;|&()")
    return "".join(out)


def is_generic_archive_name(fname: str) -> bool:
    if not fname:
        return False
    low = fname.lower()
    if low in GENERIC_BARE_NAMES:
        return True
    if "." not in low:
        return False
    return bool(GENERIC_ARCHIVE_RE.match(low))


def audit_tree(pkgbuilds_dir: Path) -> list[str]:
    pkgbuilds_dir = pkgbuilds_dir.resolve()
    errors: list[str] = []
    base_env = {k: v for k, v in os.environ.items() if k != "OMARCHY_SRC"}

    for pkg_dir in sorted(p for p in pkgbuilds_dir.iterdir() if p.is_dir()):
        name = pkg_dir.name
        pb = pkg_dir / "PKGBUILD"
        if not pb.is_file():
            continue
        text = pb.read_text(errors="replace")
        code_text = "\n".join(strip_comments(l) for l in text.splitlines())
        expandable_lines = [strip_single_quotes_and_comments(l) for l in text.splitlines()]

        # 4. No $startdir references outside comments/single quotes/escaped dollars
        for lineno, code_line in enumerate(expandable_lines, 1):
            if STARTDIR_RE.search(code_line):
                errors.append(
                    f"{name}/PKGBUILD:{lineno}: references $startdir (declare local files in source=())"
                )

        # 5. Package-local test discovery & permissions
        test_sh = pkg_dir / "test.sh"
        if test_sh.is_file() and not (test_sh.stat().st_mode & stat.S_IXUSR):
            errors.append(f"{name}/test.sh: must be executable (chmod +x)")
        for stray in sorted(pkg_dir.glob("test-*.sh")):
            if stray.is_file():
                errors.append(
                    f"{name}/{stray.name}: stray test script will not be run by CI (rename to test.sh)"
                )
        tests_subdir = pkg_dir / "tests"
        if tests_subdir.is_dir() and any(tests_subdir.glob("test_*.py")):
            if not test_sh.is_file():
                errors.append(
                    f"{name}/tests/: Python test suite has no {name}/test.sh entrypoint for CI"
                )
            else:
                runner_code = "\n".join(
                    strip_comments(l)
                    for l in test_sh.read_text(errors="replace").splitlines()
                )
                if not (re.search(r"\b(unittest|pytest)\b", runner_code) and "tests" in runner_code):
                    errors.append(
                        f"{name}/test.sh: does not appear to invoke {name}/tests/ Python suite"
                    )

        # Evaluate PKGBUILD for both architectures (catching conditional source+=)
        seen_src_errors: set[str] = set()
        all_source_items: set[str] = set()
        install_vals: set[str] = set()
        vars_map: dict[str, str] = {}

        for arch in ("x86_64", "aarch64"):
            r = subprocess.run(
                ["bash", "-c", EXTRACT_BASH, "_", str(pb.resolve()), arch],
                cwd=pkg_dir,
                env={**base_env, "CARCH": arch},
                capture_output=True,
                text=True,
                timeout=10,
            )
            lines = r.stdout.splitlines()
            if r.returncode != 0 or not lines or lines[-1] != END_SENTINEL:
                msg = f"{name}/PKGBUILD ({arch}): failed to source cleanly in bash"
                if msg not in seen_src_errors:
                    seen_src_errors.add(msg)
                    errors.append(msg)
                continue

            srcs: dict[str, list[str]] = defaultdict(list)
            sums: dict[str, list[str]] = defaultdict(list)
            for line in lines[:-1]:
                parts = line.split("|", 2)
                if parts[0] == "SRC" and len(parts) == 3:
                    srcs[parts[1]].append(parts[2])
                    all_source_items.add(parts[2])
                elif parts[0] == "SUM" and len(parts) == 3:
                    sums[parts[1]].append(parts[2])
                elif parts[0] == "VAR" and len(parts) == 3 and parts[2]:
                    if parts[1] == "install":
                        install_vals.add(parts[2])
                    else:
                        vars_map[parts[1]] = parts[2]

            for s_var, s_list in srcs.items():
                suf = s_var[len("source"):]
                matched_sums = [
                    sums[f"{alg}sums{suf}"]
                    for alg in ARCH_SUM_ALGOS
                    if sums[f"{alg}sums{suf}"]
                ]
                if s_list and not matched_sums:
                    msg = f"{name} ({s_var}): missing checksum array"
                    if msg not in seen_src_errors:
                        seen_src_errors.add(msg)
                        errors.append(msg)
                for sl in matched_sums:
                    if len(sl) != len(s_list):
                        msg = (
                            f"{name} ({s_var}): checksum count ({len(sl)}) "
                            f"does not match source count ({len(s_list)})"
                        )
                        if msg not in seen_src_errors:
                            seen_src_errors.add(msg)
                            errors.append(msg)

                for idx, src_item in enumerate(s_list):
                    has_prefix = "::" in src_item
                    url_part = src_item.split("::", 1)[-1]
                    if not re.match(r"^https?://", url_part, re.IGNORECASE):
                        continue
                    url_path = urlsplit(url_part).path

                    if MUTABLE_PATH_RE.search(url_path):
                        msg = f"{name} ({s_var}): mutable branch archive URL {url_part} (pin to a commit or tag)"
                        if msg not in seen_src_errors:
                            seen_src_errors.add(msg)
                            errors.append(msg)

                    if not has_prefix:
                        fname = url_path.rstrip("/").rsplit("/", 1)[-1]
                        if is_generic_archive_name(fname):
                            msg = (
                                f"{name} ({s_var}): non-unique source filename {fname!r} "
                                "(prefix with $pkgname-$pkgver...::)"
                            )
                            if msg not in seen_src_errors:
                                seen_src_errors.add(msg)
                                errors.append(msg)

                    if not SIG_PATH_RE.search(url_path) and (name, url_part) not in SKIP_HTTP_ALLOWLIST:
                        if matched_sums and any(
                            idx < len(sl) and sl[idx] == "SKIP" for sl in matched_sums
                        ):
                            msg = f"{name} ({s_var}): HTTP(S) source uses SKIP checksum: {src_item}"
                            if msg not in seen_src_errors:
                                seen_src_errors.add(msg)
                                errors.append(msg)

        # 6. No unreferenced top-level *.patch or *.install files
        pn = vars_map.get("pkgname") or name
        up = vars_map.get("_pkgname") or ""
        un = vars_map.get("_name") or ""

        for child in sorted(pkg_dir.iterdir()):
            if not child.is_file():
                continue
            fname = child.name
            if not (fname.endswith(".patch") or fname.endswith(".install")):
                continue
            if fname.endswith(".install"):
                if fname in install_vals or fname in all_source_items or fname in code_text:
                    continue
                alts = [
                    fname.replace(name, "$pkgname"),
                    fname.replace(name, "${pkgname}"),
                    fname.replace(pn, "$pkgname") if pn else "",
                    fname.replace(pn, "${pkgname}") if pn else "",
                    fname.replace(up, "$_pkgname") if up else "",
                    fname.replace(up, "${_pkgname}") if up else "",
                    fname.replace(un, "$_name") if un else "",
                    fname.replace(un, "${_name}") if un else "",
                ]
                if any(a and a in code_text for a in alts):
                    continue
                errors.append(f"{name}/{fname}: unreferenced .install scriptlet")
            elif fname.endswith(".patch"):
                if fname in code_text or "*.patch" in code_text or any(fname in s for s in all_source_items):
                    continue
                errors.append(f"{name}/{fname}: unreferenced .patch file")

    return errors


def check(cond: bool, message: str) -> None:
    if not cond:
        raise AssertionError(message)


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="recipe-hygiene-test-") as td:
        root = Path(td)

        # Good fixture: unique prefix, sha384sums, arch-conditional install/source, safe $startdir literals
        good = root / "good-pkg"
        good.mkdir()
        (good / "PKGBUILD").write_text(
            "pkgname=good-pkg\npkgver=1.0.0\npkgrel=1\n"
            "# Do not use $startdir or *.patch comments to confuse parser\n"
            "source=(\"good-pkg-1.0.0.tar.gz::https://example.com/archive/v1.0.0.tar.gz?ref=/archive/refs/heads/main\" \"fix.patch\")\n"
            "sha384sums=(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" \"SKIP\")\n"
            "if [[ $CARCH == x86_64 ]]; then\n"
            "  install=good-x86.install\n"
            "  source_x86_64=(\"good-x86-1.0.0.tar.gz::https://example.com/good-x86.tar.gz\")\n"
            "  sha256sums_x86_64=(\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\")\n"
            "else\n"
            "  install=good-arm.install\n"
            "fi\n"
            "build() { echo \x27$startdir literal is fine\x27 \"\\$startdir escaped\"; }\n"
        )
        (good / "fix.patch").write_text("--- a\n+++ b\n")
        (good / "good-x86.install").write_text("post_install() { :; }\n")
        (good / "good-arm.install").write_text("post_install() { :; }\n")
        (good / "test.sh").write_text("#!/bin/bash\npython3 -m unittest discover -s 'tests'\n")
        (good / "test.sh").chmod(0o755)
        (good / "tests").mkdir()
        (good / "tests/test_ok.py").write_text("pass\n")
        (good / "test-dir.sh").mkdir()
        errs = audit_tree(root)
        check(errs == [], f"expected no errors for good fixture, got: {errs}")

        # Bad fixtures covering every rule and bypass attempt
        bad = root / "bad-pkg"
        bad.mkdir()
        (bad / "PKGBUILD").write_text(
            "pkgname=bad-pkg\npkgver=1.0.0\npkgrel=1\n"
            "# *.patch in comment must not exempt unused.patch\n"
            "source=(\n"
            "  \"https://github.com/org/repo/archive/refs/heads/main.tar.gz\"\n"
            "  \"https://github.com/org/repo/archive/HEAD.tar.gz\"\n"
            "  \"dev.tar.gz::https://github.com/org/repo/tarball/refs/heads/develop\"\n"
            "  \"https://github.com/org/repo/archive/refs/tags/v1.0.0.tar.gz\"\n"
            "  \"https://github.com/org/repo/archive/refs/tags/v1.2.3-rc1.tar.gz\"\n"
            "  \"https://github.com/org/repo/archive/refs/tags/1.2.3-beta.tar.gz\"\n"
            "  \"https://example.com/latest.zip\"\n"
            "  \"pinned.tar.gz::https://github.com/org/repo/archive/deadbeef.tar.gz?hint=.sig\"\n"
            ")\n"
            "sha256sums=(\n"
            "  \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n"
            "  \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n"
            "  \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n"
            "  \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"\n"
            "  \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"\n"
            "  \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"\n"
            "  \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"\n"
            "  \"SKIP\"\n"
            ")\n"
            "build() { echo foo#bar \"${startdir%/}/foo\"; }\n"
        )
        (bad / "unused.patch").write_text("--- a\n+++ b\n")
        (bad / "unused.install").write_text("post_install() { :; }\n")
        (bad / "test-check.sh").write_text("#!/bin/bash\nexit 0\n")
        (bad / "test.sh").write_text("#!/bin/bash\nexit 0\n")
        (bad / "test.sh").chmod(0o644)

        bad_py = root / "bad-py"
        bad_py.mkdir()
        (bad_py / "PKGBUILD").write_text("pkgname=bad-py\npkgver=1\npkgrel=1\n")
        (bad_py / "tests").mkdir()
        (bad_py / "tests/test_sample.py").write_text("pass\n")
        (bad_py / "test.sh").write_text("#!/bin/bash\n# pytest tests/\nexit 0\n")
        (bad_py / "test.sh").chmod(0o755)

        bad_sums = root / "bad-sums"
        bad_sums.mkdir()
        (bad_sums / "PKGBUILD").write_text(
            "pkgname=bad-sums\npkgver=1\npkgrel=1\n"
            "source=(\"a.tar.gz::https://example.com/a.tar.gz\" \"b.tar.gz::https://example.com/b.tar.gz\")\n"
            "sha256sums=(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\")\n"
            "source_aarch64=(\"c.tar.gz::https://example.com/c.tar.gz\")\n"
        )

        bad_exit = root / "bad-exit"
        bad_exit.mkdir()
        (bad_exit / "PKGBUILD").write_text("pkgname=bad-exit\nexit 0\n")

        errs = audit_tree(root)
        joined = "\n".join(errs)
        for expected in (
            "references $startdir",
            "must be executable",
            "stray test script",
            "does not appear to invoke bad-py/tests/",
            "mutable branch archive URL https://github.com/org/repo/archive/refs/heads/main.tar.gz",
            "mutable branch archive URL https://github.com/org/repo/archive/HEAD.tar.gz",
            "mutable branch archive URL https://github.com/org/repo/tarball/refs/heads/develop",
            "non-unique source filename 'v1.2.3-rc1.tar.gz'",
            "non-unique source filename '1.2.3-beta.tar.gz'",
            "non-unique source filename \x27v1.0.0.tar.gz\x27",
            "non-unique source filename \x27latest.zip\x27",
            "HTTP(S) source uses SKIP checksum",
            "unreferenced .patch file",
            "unreferenced .install scriptlet",
            "checksum count (1) does not match source count (2)",
            "bad-sums (source_aarch64): missing checksum array",
            "bad-exit/PKGBUILD (x86_64): failed to source cleanly",
        ):
            check(expected in joined, f"missing expected error {expected!r} in:\n{joined}")


def main() -> int:
    self_test()
    errors = audit_tree(PKGBUILDS_DIR)
    if errors:
        for err in errors:
            print(f"FAIL: {err}", file=sys.stderr)
        print(f"{len(errors)} recipe hygiene error(s) found.", file=sys.stderr)
        return 1
    print(f"PASS: recipe hygiene checks passed across {PKGBUILDS_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
