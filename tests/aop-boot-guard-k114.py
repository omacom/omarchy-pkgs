#!/usr/bin/env python3
"""Contract tests for pkgbuilds/aop-boot-guard-k114/aop-boot-guard-load (tests only).

Installed name: /usr/lib/aop-boot-guard/load. Run with:
python tests/aop-boot-guard-k114.py
(compiles the real loader file before any patching, then executes it as
 __main__ inside the mocked boundary; no root, no hardware, no /dev/watchdog,
 no host services: every OS/subprocess boundary is a stdlib mock below.
 os.path.realpath is patched to a deterministic /lib -> /usr/lib resolver so
 symlink resolution cannot recurse through mocked lstat. No production env
 flags or config seam.)

Loader contract pinned here:
- Runs as root only (os.geteuid()==0); refuses otherwise with no module attempts,
  and must sys.exit nonzero on every refusal/failure (systemd Restart=no reads it).
- /proc/device-tree/compatible: NUL-delimited entries; must contain the exact
  entry 'apple,k114c' (no prefix/substring matches).
- /usr/lib/aop-boot-guard/manifests/<release>/manifest.json: one verified pin per
  running kernel release; JSON with exactly the keys release, aop_sha256, dai_sha256.
  The running release must have that file and its release must equal os.uname().release
  (safe charset). Unknown releases refuse; never rewritten by the loader at boot.
- Stock modules /lib/modules/<release>/kernel/drivers/soc/apple/aop.ko and
  /lib/modules/<release>/kernel/sound/soc/apple/snd-soc-t8152-aop-audio.ko must
  hash to the manifest values and contain 'vermagic=<release> '.
- Watchdog runner /usr/lib/aop-boot-guard/wdt-run must hash byte-for-byte to the
  hash below; module loads go through it:
  [runner, '90', '/usr/bin/insmod', <module path>].
- speakerguardd-k114 must be installed at 0.1.12-4 ('/usr/bin/pacman -Q
  speakerguardd-k114'); wrong/missing result refuses. The loader never starts,
  stops or configures any daemon and never touches the mixer or blacklist.
- group/other-writable or unreadable manifest/runner/modules or any parent dir,
  resolved through the standard /lib symlink, refuses.
- /run/aop-boot-guard-once: one os.mkdir before any module action; kept after
  failures; a present marker (or lost mkdir race) is an inert no-op exiting 0.
- /var/lib/aop-boot-guard/inflight: exclusive, durable latch before each runner;
  cleared and directory-fsynced only after runner rc 0. Any nonzero runner status
  refuses and retains the latch, requiring manual review across boots.
- Order: pacman precheck, then mkdir, runner(insmod aop), sleep(20),
  runner(insmod dai); a module whose /sys/module/<name> dir exists is skipped.

Boundary mocks the loader may rely on (stdlib only): os.uname, os.geteuid,
os.stat, os.lstat, os.access, os.mkdir, os.rmdir, os.remove, os.path.exists/
isdir/isfile/lexists/realpath (realpath is the pure /lib -> /usr/lib
resolver), builtins.open and io.open (virtual filesystem),
subprocess.run (capture-aware like the stdlib: stdout/stderr None when not
captured, bytes unless text=True, then str), time.sleep. subprocess argv
values are str. Nothing outside
these boundaries is mocked; if the loader needs another OS boundary, that is a
design gap to resolve with the parent, not a reason to widen this seam.
"""
import contextlib
import errno
import hashlib
import io
import json
import os
import pathlib
import stat as statmod
import unittest
from types import SimpleNamespace
from unittest import mock

ROOT = pathlib.Path(__file__).absolute().parents[1]
LOADER = ROOT / "pkgbuilds/aop-boot-guard-k114/aop-boot-guard-load"
SHIPPED_RUNNER = ROOT / "pkgbuilds/aop-boot-guard-k114/aop-boot-guard-wdt-run"

REL = "7.3.0-k114c-1"  # representative; the live pin comes from the manifest
COMPAT_DATA = b"apple,k114c\x00apple,t6050\x00apple,arm-platform\x00"
COMPAT_PATH = "/proc/device-tree/compatible"
MANIFEST_PATH = "/usr/lib/aop-boot-guard/manifests/" + REL + "/manifest.json"
RUNNER = "/usr/lib/aop-boot-guard/wdt-run"
AOP = "/lib/modules/%s/kernel/drivers/soc/apple/aop.ko" % REL
DAI = "/lib/modules/%s/kernel/sound/soc/apple/snd-soc-t8152-aop-audio.ko" % REL
MARKER = "/run/aop-boot-guard-once"
PACMAN = "/usr/bin/pacman"
INSMOD = "/usr/bin/insmod"
LATCH_DIR = "/var/lib/aop-boot-guard"
LATCH = LATCH_DIR + "/inflight"
SPEAKERGUARDD = "speakerguardd-k114 0.1.12-4"
WDT_SHA = "d4a3bf7cf1dabd936446d1ba37e5d878bcaf25bb59ef641941dc8542b47a3f74"

# Byte-exact watchdog runner (758 B). Its hash is asserted in
# test_proven_runner_bytes; do not reformat this string.
WDT_SRC = r'''#!/usr/bin/python3
"""Run a command with the SoC watchdog armed (for module tests on a confirmed boot).

usage: aop-boot-guard-wdt-run TIMEOUT_S CMD...
Pets /dev/watchdog every 2 s while CMD runs. If the system hangs, petting stops and
the SoC resets after TIMEOUT_S. On a normal exit the watchdog is stopped with the
magic close ('V').
"""
import fcntl
import os
import struct
import subprocess
import sys
import time

WDIOC_SETTIMEOUT = 0xC0045706

timeout = int(sys.argv[1])
fd = os.open("/dev/watchdog", os.O_WRONLY)
fcntl.ioctl(fd, WDIOC_SETTIMEOUT, struct.pack("I", timeout))
os.write(fd, b"\0")
p = subprocess.Popen(sys.argv[2:])
while p.poll() is None:
    os.write(fd, b"\0")
    time.sleep(2)
os.write(fd, b"V")
os.close(fd)
sys.exit(p.returncode)
'''

SYMLINKS = {"/lib": "/usr/lib"}  # standard merged-usr symlink, permitted by contract


def resolve(path):
    """Deterministic realpath stand-in: pure string mapping, never touches lstat."""
    p = os.path.normpath(str(path))
    for src, dst in SYMLINKS.items():
        if p == src or p.startswith(src + os.sep):
            p = dst + p[len(src):]
            break
    return p


sha = lambda b: hashlib.sha256(b).hexdigest()
VERMAGIC = ("vermagic=%s SMP preempt mod_unload aarch64\n" % REL).encode()


def manifest_bytes(rel=REL, aop=None, dai=None, extra=None):
    doc = {"release": rel,
           "aop_sha256": aop or sha(VERMAGIC),
           "dai_sha256": dai or sha(VERMAGIC)}
    if extra:
        doc.update(extra)
    return json.dumps(doc).encode()


class FS:
    """Minimal virtual filesystem over the contract paths only."""

    def __init__(self):
        self.files = {}            # real path -> bytes
        self.dirs = set()
        self.modes = {}            # real path -> permission bits
        self.uids = {}             # real path -> owner uid (0 = root)
        self.lexists_extra = set()  # dangling symlinks: lexists true, stat fails
        self.mkdir_calls = []
        self.mkdir_fail = False    # marker already exists / lost the race
        self.rmdir_calls = []
        self.remove_calls = []

    def add_file(self, path, data, mode=0o644):
        real = resolve(path)
        self.files[real] = data
        self.modes.setdefault(real, mode)
        parent = os.path.dirname(real)
        while parent not in self.dirs:
            self.add_dir(parent)

    def add_dir(self, path, mode=0o755):
        real = resolve(path)
        self.dirs.add(real)
        self.modes.setdefault(real, mode)
        parent = os.path.dirname(real)
        if parent != real and parent not in self.dirs:
            self.add_dir(parent)

    def chmod(self, path, mode):
        self.modes[resolve(path)] = mode

    def chown(self, path, uid):
        self.uids[resolve(path)] = uid

    # -- boundary implementations -------------------------------------------
    def stat(self, path):
        real = resolve(str(path))
        uid = self.uids.get(real, 0)
        if real in self.files:
            bits = 0o100000 | self.modes.get(real, 0o644)
            return os.stat_result((bits, 1, 1, 1, uid, 0, len(self.files[real]), 0, 0, 0))
        if real in self.dirs:
            bits = 0o040000 | self.modes.get(real, 0o755)
            return os.stat_result((bits, 1, 1, 2, uid, 0, 0, 0, 0, 0))
        raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), real)

    def open(self, path, mode="r", *args, **kwargs):
        real = resolve(str(path))
        data = self.files.get(real)
        if data is None:
            raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), real)
        return io.BytesIO(data) if "b" in mode else io.StringIO(data.decode())

    def lexists(self, path):
        real = resolve(str(path))
        return real in self.files or real in self.dirs or real in self.lexists_extra

    def mkdir(self, path, mode=0o700):
        real = resolve(str(path))
        self.mkdir_calls.append(real)
        if self.mkdir_fail or real in self.dirs or real in self.files:
            raise FileExistsError(errno.EEXIST, os.strerror(errno.EEXIST), real)
        self.dirs.add(real)


def make_fs(**manifest_kw):
    fs = FS()
    fs.add_dir("/run")  # marker parent: real systems always have it
    fs.add_file(COMPAT_PATH, COMPAT_DATA)
    fs.add_file(MANIFEST_PATH, manifest_bytes(**manifest_kw), 0o644)
    fs.add_file(RUNNER, WDT_SRC.encode(), 0o755)
    fs.add_file(INSMOD, b"\x7fELF-insmod-stand-in\n", 0o755)
    fs.add_dir(LATCH_DIR)
    fs.add_file(AOP, VERMAGIC, 0o644)
    fs.add_file(DAI, VERMAGIC, 0o644)
    return fs


@contextlib.contextmanager
def boundary(fs, pacman_stdout=SPEAKERGUARDD + "\n", pacman_rc=0,
             runner_fails_first=False, runner_raises=False, runner_rc=0,
             latch_open_fails=False, fsync_fails=False, run_oserror=False,
             euid=0, release=REL):
    """Patch every OS/subprocess boundary the contract names onto the fixture."""
    events = []  # ordered: argv lists for subprocess, ("mkdir"|"sleep", value) tuples

    class FakeFd:
        def __init__(self, real, isdir=False):
            self.real, self.isdir = real, isdir

        def fsync(self):
            if fsync_fails:
                raise OSError(errno.EIO, "simulated fsync failure", self.real)
            events.append(("fsync_dir" if self.isdir else "fsync_file", self.real))

        def close(self):
            pass

    def fake_os_open(path, flags, *args):
        real = resolve(str(path))
        events.append(("open", flags, real))
        if flags & os.O_CREAT:
            if latch_open_fails:
                raise OSError(errno.EIO, "simulated latch open failure", real)
            if fs.lexists(real):
                raise FileExistsError(errno.EEXIST, os.strerror(errno.EEXIST), real)
            fs.files[real] = b""
            fs.modes.setdefault(real, 0o600)
            return FakeFd(real)
        if real in fs.dirs:
            return FakeFd(real, isdir=True)
        if real in fs.files:
            return FakeFd(real)
        raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), real)

    def fake_run(argv, capture_output=False, text=False, **kwargs):
        # Mirrors the real subprocess.run contract: nothing captured -> stdout/stderr
        # None; captured -> bytes unless text=True. Flag mutants must not survive.
        argv = [str(a) for a in argv]
        if argv[0] not in (PACMAN, RUNNER):
            events.append(["FORBIDDEN"] + argv)
            return SimpleNamespace(returncode=1, stdout=None, stderr=None)
        events.append(argv)
        rc, out = 0, ""
        if argv[0] == PACMAN:
            rc, out = pacman_rc, pacman_stdout
        elif argv[0] == RUNNER:
            if run_oserror:
                raise OSError(errno.EIO, "simulated runner exec failure")
            if runner_raises:
                raise RuntimeError("simulated runner crash/kill")
            rc = runner_rc
            if runner_fails_first and not any(a[0] == RUNNER for a in events[:-1]):
                rc = 1
        if not capture_output:
            return SimpleNamespace(returncode=rc, stdout=None, stderr=None)
        return SimpleNamespace(returncode=rc, stdout=out if text else out.encode(), stderr="")

    def fake_mkdir(path, mode=0o700):
        events.append(("mkdir", resolve(str(path))))
        fs.mkdir(path, mode)

    def fake_sleep(seconds):
        events.append(("sleep", seconds))

    patches = [
        mock.patch("os.uname", return_value=SimpleNamespace(sysname="Linux", release=release, machine="aarch64")),
        mock.patch("os.geteuid", return_value=euid),
        mock.patch("os.stat", side_effect=lambda p, **k: fs.stat(p)),
        mock.patch("os.lstat", side_effect=lambda p, **k: fs.stat(p)),
        mock.patch("os.access",
                   side_effect=lambda p, m, **k: (statmod.S_IMODE(fs.stat(p).st_mode) & 0o022) == 0 if m & os.W_OK else True),
        mock.patch("os.mkdir", side_effect=fake_mkdir),
        mock.patch("os.rmdir", side_effect=lambda p, **k: fs.rmdir_calls.append(resolve(str(p)))),
        mock.patch("os.remove", side_effect=lambda p, **k: (
            events.append(("unlink", resolve(str(p)))),
            fs.remove_calls.append(resolve(str(p))),
            fs.files.pop(resolve(str(p)), None))),
        mock.patch("os.open", side_effect=fake_os_open),
        mock.patch("os.fsync", side_effect=lambda fd: fd.fsync()),
        mock.patch("os.close", side_effect=lambda fd: fd.close()),
        mock.patch("os.path.exists", side_effect=lambda p: resolve(str(p)) in fs.files or resolve(str(p)) in fs.dirs),
        mock.patch("os.path.isdir", side_effect=lambda p: resolve(str(p)) in fs.dirs),
        mock.patch("os.path.isfile", side_effect=lambda p: resolve(str(p)) in fs.files),
        mock.patch("os.path.lexists", side_effect=fs.lexists),
        mock.patch("os.path.realpath", side_effect=lambda p, **k: resolve(p)),
        mock.patch("builtins.open", side_effect=fs.open),
        mock.patch("io.open", side_effect=fs.open),
        mock.patch("subprocess.run", side_effect=fake_run),
        mock.patch("time.sleep", side_effect=fake_sleep),
    ]
    with contextlib.ExitStack() as stack:
        for p in patches:
            stack.enter_context(p)
        yield events


def execute_pinned_runner(poll_results):
    """Execute actual pinned runner bytes with watchdog and child boundaries mocked."""
    program = compile(SHIPPED_RUNNER.read_bytes(), str(RUNNER), "exec")
    writes, closes = [], []

    class FakeProcess:
        def __init__(self):
            self.returncode = None

        def poll(self):
            result = poll_results.pop(0)
            if isinstance(result, BaseException):
                raise result
            if result is not None:
                self.returncode = result
            return result
    def fake_write(fd, value):
        writes.append(value)

    try:
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch("os.open", return_value=17))
            stack.enter_context(mock.patch("os.write", side_effect=fake_write))
            stack.enter_context(mock.patch("os.close", side_effect=lambda fd: closes.append(fd)))
            stack.enter_context(mock.patch("fcntl.ioctl"))
            stack.enter_context(mock.patch("subprocess.Popen", return_value=FakeProcess()))
            stack.enter_context(mock.patch("time.sleep"))
            stack.enter_context(mock.patch(
                "sys.argv", [str(RUNNER), "90", "/usr/bin/insmod", "/module.ko"]))
            exec(program, {"__name__": "__main__", "__file__": str(RUNNER)})
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
        return (code if code >= 0 else code & 0xff), writes, closes, None
    except Exception as e:
        # An uncaught runner exception exits the Python process with status 1.
        return 1, writes, closes, e
    raise AssertionError("pinned runner unexpectedly returned")


def run_loader(fs, **kw):
    """Compile the real loader bytes, then exec them as __main__ inside the boundary."""
    if not LOADER.is_file():
        raise RuntimeError("loader missing: %s - write it to satisfy this contract" % LOADER)
    program = compile(LOADER.read_bytes(), str(LOADER), "exec")  # before any patching
    try:
        with boundary(fs, **kw) as events:
            exec(program, {"__name__": "__main__", "__file__": str(LOADER)})
            code = 0
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    return code, events


def subprocess_events(events):
    return [a for a in events if isinstance(a, list)]


def runner_calls(events):
    return [a for a in events if isinstance(a, list) and a[0] == RUNNER]


class AopBootGuardContract(unittest.TestCase):

    def assert_refused(self, fs=None, **kw):
        fs = fs if fs is not None else make_fs()
        code, events = run_loader(fs, **kw)
        self.assertNotEqual(code, 0, "refusal must exit nonzero")
        self.assertFalse(runner_calls(events), "refusal made a module attempt")
        self.assertTrue(all(a[0] in (PACMAN,) for a in subprocess_events(events)),
                        "unexpected subprocess during refusal: %r" % subprocess_events(events))
        self.assertNotIn(resolve(MARKER), fs.mkdir_calls, "refusal created the marker")
        self.assertEqual(fs.rmdir_calls + fs.remove_calls, [], "loader removed files")
        return fs, events

    def test_proven_runner_bytes(self):
        self.assertEqual(sha(WDT_SRC.encode()), WDT_SHA,
                         "embedded runner bytes must be the shipped watchdog, byte for byte")
        self.assertEqual(sha(SHIPPED_RUNNER.read_bytes()), WDT_SHA,
                         "shipped runner %s must hash to the pinned build, byte for byte" % SHIPPED_RUNNER)
        self.assertTrue(os.stat(SHIPPED_RUNNER).st_mode & 0o111,
                        "shipped runner %s must be executable (mode 0755)" % SHIPPED_RUNNER)

    def test_pinned_runner_exception_exits_before_magic_close(self):
        status, writes, closes, error = execute_pinned_runner(
            [None, RuntimeError("simulated child poll exception")])
        self.assertEqual(status, 1, "uncaught runner exception maps to process exit 1")
        self.assertIsInstance(error, RuntimeError, "captured the actual pre-V exception")
        self.assertNotIn(b"V", writes, "magic-close was not written")
        self.assertEqual(closes, [], "watchdog fd remains open after exception")

    def test_pinned_runner_maps_negative_insmod_status_to_positive_exit(self):
        status, writes, closes, error = execute_pinned_runner([-9])
        self.assertIsNone(error, "runner exits normally through sys.exit(-9)")
        self.assertEqual(status, 247, "sys.exit(-9) appears as process exit 247")
        self.assertEqual(writes[-1], b"V", "normal runner exit wrote magic-close")
        self.assertEqual(closes, [17], "normal runner exit closed watchdog fd")

    def test_boundary_smoke(self):
        """Harness correctness is observable without the loader."""
        fs = make_fs()
        with boundary(fs) as events:
            self.assertTrue(os.path.realpath("/lib/modules/x/y").startswith("/usr/lib/modules/"))
            self.assertEqual(os.stat(AOP).st_mode & 0o777, 0o644)
            with io.open(MANIFEST_PATH, "rb") as f:
                self.assertEqual(json.loads(f.read())["release"], REL)
            os.mkdir(MARKER)
            self.assertEqual(events[-1], ("mkdir", resolve(MARKER)))
            with self.assertRaises(FileExistsError):
                os.mkdir(MARKER)
        self.assertFalse(os.path.exists(AOP))  # boundaries scoped to the context

    def test_refusals_make_no_module_attempt(self):
        manifest_cases = [
            ("manifest-release-mismatch", dict(rel="9.9.9-other")),
            ("manifest-release-shape-invalid", dict(rel="../7.3.0-evil k114c")),
            ("manifest-extra-key", dict(extra={"note": "x"})),
            ("manifest-sha-uppercase", dict(aop=sha(VERMAGIC).upper())),
        ]
        boundary_cases = [
            ("pacman-missing", dict(pacman_rc=1, pacman_stdout="")),
            ("pacman-wrong-version", dict(pacman_stdout="speakerguardd-k114 0.1.12-2\n")),
            ("pacman-superseded-handoff", dict(pacman_stdout="speakerguardd-k114 0.1.12-3\n")),
            ("not-root", dict(euid=1000)),
        ]
        mutate_cases = [
            ("wrong-compatible",
             lambda fs: fs.add_file(COMPAT_PATH, b"apple,j516c\x00apple,t6031\x00")),
            ("compatible-prefix-not-exact",
             lambda fs: fs.add_file(COMPAT_PATH, b"apple,k114c-evil\x00apple,t6050\x00")),
            ("aop-hash-mismatch", lambda fs: fs.add_file(AOP, b"tampered\n")),
            ("dai-hash-mismatch", lambda fs: fs.add_file(DAI, b"tampered\n")),
            ("vermagic-mismatch", lambda fs: (
                fs.add_file(AOP, b"no-vermagic-here\n"),
                fs.add_file(MANIFEST_PATH, manifest_bytes(aop=sha(b"no-vermagic-here\n"))))),
            ("runner-hash-mismatch",
             lambda fs: fs.add_file(RUNNER, b"#!/bin/sh\nexit 0\n", 0o755)),
            ("manifest-missing", lambda fs: fs.files.pop(resolve(MANIFEST_PATH))),
            ("manifest-malformed", lambda fs: fs.add_file(MANIFEST_PATH, b"{not json")),
            ("manifest-not-object", lambda fs: fs.add_file(MANIFEST_PATH, b"[]")),
            ("manifest-missing-key", lambda fs: fs.add_file(
                MANIFEST_PATH, json.dumps({"release": REL, "aop_sha256": sha(VERMAGIC)}).encode())),
            ("writable-manifest", lambda fs: fs.chmod(MANIFEST_PATH, 0o666)),
            ("writable-runner", lambda fs: fs.chmod(RUNNER, 0o775)),
            ("writable-module-parent", lambda fs: fs.chmod(os.path.dirname(AOP), 0o777)),
            ("writable-run-parent", lambda fs: fs.chmod("/run", 0o777)),
            ("manifest-owner-not-root", lambda fs: fs.chown(MANIFEST_PATH, 1000)),
            ("runner-owner-not-root", lambda fs: fs.chown(RUNNER, 1000)),
            ("module-owner-not-root", lambda fs: fs.chown(AOP, 1000)),
            ("runner-not-regular", lambda fs: (
                fs.files.pop(resolve(RUNNER)), fs.dirs.add(resolve(RUNNER)))),
            ("module-not-regular", lambda fs: (
                fs.files.pop(resolve(AOP)), fs.dirs.add(resolve(AOP)))),
            ("module-missing", lambda fs: fs.files.pop(resolve(AOP))),
            ("module-parent-not-root", lambda fs: fs.chown(os.path.dirname(AOP), 1000)),
            ("module-ancestor-not-root", lambda fs: fs.chown("/usr/lib", 1000)),
            ("module-ancestor-writable", lambda fs: fs.chmod("/usr/lib/modules", 0o777)),
            ("manifest-release-not-string", lambda fs: fs.add_file(MANIFEST_PATH, json.dumps(
                {"release": 1, "aop_sha256": sha(VERMAGIC), "dai_sha256": sha(VERMAGIC)}).encode())),
            ("manifest-sha-not-string", lambda fs: fs.add_file(MANIFEST_PATH, json.dumps(
                {"release": REL, "aop_sha256": 0, "dai_sha256": sha(VERMAGIC)}).encode())),
        ]
        for name, kw in manifest_cases:
            with self.subTest(case=name):
                self.assert_refused(make_fs(**kw))
        for name, kw in boundary_cases:
            with self.subTest(case=name):
                self.assert_refused(make_fs(), **kw)
        for name, mutate in mutate_cases:
            with self.subTest(case=name):
                fs = make_fs()
                mutate(fs)
                self.assert_refused(fs)

    def test_clean_boot_order(self):
        fs = make_fs()
        code, events = run_loader(fs)
        self.assertEqual(code, 0, "clean boot must succeed")
        subs = subprocess_events(events)
        self.assertTrue(all(a[0] in (PACMAN, RUNNER) for a in subs),
                        "loader ran only its contract subprocesses: %r" % subs)
        pacman = [a for a in subs if a[0] == PACMAN and "speakerguardd-k114" in a]
        self.assertEqual(len(pacman), 1, "one pacman -Q precheck")
        runners = runner_calls(events)
        self.assertEqual(len(runners), 2, "exactly two guarded insmods")
        self.assertEqual([str(a[1]) for a in runners], ["90", "90"], "calibrated 90 s runner")
        self.assertEqual([a[2] for a in runners], [INSMOD, INSMOD], "absolute /usr/bin/insmod")
        for a, ko in zip(runners, (AOP, DAI)):
            self.assertEqual(os.path.realpath(a[3]), resolve(ko), "stock module path: %r" % a[3])
        mkdirs = [e for e in events if isinstance(e, tuple) and e[0] == "mkdir"]
        sleeps = [e for e in events if isinstance(e, tuple) and e[0] == "sleep"]
        self.assertEqual(mkdirs, [("mkdir", resolve(MARKER))], "exactly one marker mkdir")
        self.assertEqual(sleeps, [("sleep", 20)], "proven settle sleep")
        self.assertLess(events.index(pacman[0]),
                        events.index(mkdirs[0]), "prechecks precede the marker")
        self.assertLess(events.index(mkdirs[0]), events.index(runners[0]),
                        "marker precedes any module action")
        self.assertLess(events.index(runners[0]), events.index(sleeps[0]),
                        "settle sleep follows the AOP load")
        self.assertLess(events.index(sleeps[0]), events.index(runners[1]),
                        "DAI load follows the settle sleep")
        self.assertNotIn(resolve(MARKER), fs.rmdir_calls + fs.remove_calls, "marker retained")

    def test_aop_already_loaded_skips(self):
        fs = make_fs()
        fs.add_dir("/sys/module/aop")
        code, events = run_loader(fs)
        self.assertEqual(code, 0)
        runners = runner_calls(events)
        self.assertEqual(len(runners), 1, "only the DAI load runs")
        self.assertEqual(os.path.realpath(runners[0][3]), resolve(DAI))

    def test_dai_already_loaded_skips(self):
        fs = make_fs()
        fs.add_dir("/sys/module/snd_soc_t8152_aop_audio")
        code, events = run_loader(fs)
        self.assertEqual(code, 0)
        runners = runner_calls(events)
        self.assertEqual(len(runners), 1, "only the AOP load runs")
        self.assertEqual(os.path.realpath(runners[0][3]), resolve(AOP))

    def test_insmod_failure_retains_marker_and_latch_and_never_retries(self):
        fs = make_fs()
        code, events = run_loader(fs, runner_fails_first=True)
        self.assertNotEqual(code, 0, "insmod failure must exit nonzero")
        self.assertEqual(len(runner_calls(events)), 1, "no retry after failure")
        self.assertIn(resolve(MARKER), fs.mkdir_calls, "marker kept after failure")
        self.assertNotIn(resolve(MARKER), fs.rmdir_calls + fs.remove_calls)
        self.assertIn(resolve(LATCH), fs.files, "nonzero result retains latch")
        fs.mkdir_fail = True  # same-boot rerun must stop at the persistent latch
        code2, events2 = run_loader(fs)
        self.assertNotEqual(code2, 0, "retained latch refuses even with marker present")
        self.assertEqual(runner_calls(events2), [], "rerun makes no module attempt")

    def test_marker_race_is_inert_noop(self):
        fs = make_fs()
        fs.mkdir_fail = True  # another instance won the mkdir
        code, events = run_loader(fs)
        self.assertEqual(code, 0)
        self.assertEqual(runner_calls(events), [])

    # -- inflight latch and execute validation --------------------------------

    def tuple_events(self, events, kind):
        return [e for e in events if isinstance(e, tuple) and e[0] == kind]

    def assert_no_module_path_taken(self, fs, events):
        self.assertEqual(runner_calls(events), [], "no module attempt")
        self.assertEqual(self.tuple_events(events, "mkdir"), [], "marker not consumed")
        creates = [e for e in events if isinstance(e, tuple) and e[0] == "open"
                   and e[2] == resolve(LATCH) and e[1] & os.O_CREAT]
        self.assertEqual(creates, [], "no new latch creation")

    def test_runner_or_insmod_not_executable_refuses_before_marker(self):
        cases = [
            ("runner-not-executable", lambda fs: fs.chmod(RUNNER, 0o644)),
            ("runner-missing", lambda fs: fs.files.pop(resolve(RUNNER))),
            ("insmod-not-executable", lambda fs: fs.chmod(INSMOD, 0o644)),
            ("insmod-group-writable", lambda fs: fs.chmod(INSMOD, 0o775)),
            ("runner-group-writable", lambda fs: fs.chmod(RUNNER, 0o775)),
            ("insmod-missing", lambda fs: fs.files.pop(resolve(INSMOD))),
        ]
        for name, mutate in cases:
            with self.subTest(case=name):
                fs = make_fs()
                mutate(fs)
                code, events = run_loader(fs)
                self.assertNotEqual(code, 0, "%s must refuse" % name)
                self.assert_no_module_path_taken(fs, events)

    def test_existing_or_dangling_latch_refuses(self):
        for name, seed in (("existing-latch", lambda fs: fs.add_file(LATCH, b"")),
                           ("dangling-latch", lambda fs: fs.lexists_extra.add(resolve(LATCH)))):
            with self.subTest(case=name):
                fs = make_fs()
                seed(fs)
                code, events = run_loader(fs)
                self.assertNotEqual(code, 0, "%s must refuse" % name)
                self.assert_no_module_path_taken(fs, events)
                self.assertEqual(fs.remove_calls, [], "refusal never clears the latch")

    def test_normal_return_clears_latch_durably(self):
        # A zero runner result takes, fsyncs (file then dir), runs, then unlinks.
        fs = make_fs()
        code, events = run_loader(fs)
        self.assertEqual(code, 0)
        self.assertNotIn(resolve(LATCH), fs.files, "latch cleared on success")
        runners = runner_calls(events)
        self.assertEqual(len(runners), 2)
        opens = [e for e in events if isinstance(e, tuple) and e[0] == "open"
                 and e[2] == resolve(LATCH)]
        self.assertEqual(len(opens), 2, "one latch per guarded load")
        open_idx = [i for i, e in enumerate(events) if e is opens[0] or e is opens[1]]
        runner_idx = [i for i, e in enumerate(events) if isinstance(e, list) and e[0] == RUNNER]
        unlink_idx = [i for i, e in enumerate(events)
                      if isinstance(e, tuple) and e[0] == "unlink" and e[1] == resolve(LATCH)]
        fsync_file = self.tuple_events(events, "fsync_file")
        fsync_dir = self.tuple_events(events, "fsync_dir")
        self.assertEqual([e[1] for e in fsync_file], [resolve(LATCH)] * 2)
        self.assertEqual(sorted(set(e[1] for e in fsync_dir)), [resolve(LATCH_DIR)])
        self.assertEqual(len(fsync_dir), 4, "dir fsynced on take and on clear, both loads")
        self.assertEqual([e[1] for e in self.tuple_events(events, "unlink")],
                         [resolve(LATCH)] * 2)
        for o_i, r_i, u_i in zip(open_idx, runner_idx, unlink_idx):
            kinds = [e[0] for e in events[o_i + 1:r_i]
                     if isinstance(e, tuple) and e[0].startswith("fsync")]
            self.assertEqual(kinds, ["fsync_file", "fsync_dir"],
                             "file then directory fsync before the runner runs")
            self.assertLess(r_i, u_i, "latch cleared only after the subprocess returned")
        self.assertNotIn(resolve(MARKER), fs.rmdir_calls + fs.remove_calls, "marker retained")

    def test_nonzero_runner_result_retains_latch(self):
        for rc in (1, 247):
            with self.subTest(runner_rc=rc):
                fs = make_fs()
                code, events = run_loader(fs, runner_rc=rc)
                self.assertNotEqual(code, 0, "nonzero runner status must refuse")
                self.assertEqual(len(runner_calls(events)), 1, "no retry after runner failure")
                self.assertIn(resolve(LATCH), fs.files, "nonzero runner status retains latch")
                self.assertEqual(self.tuple_events(events, "unlink"), [],
                                 "nonzero runner status must not clear latch")

    def test_signaled_runner_retains_latch_and_blocks_next_boot(self):
        fs = make_fs()
        with mock.patch("sys.stderr", new=io.StringIO()) as err:
            code, events = run_loader(fs, runner_rc=-9)  # runner child SIGKILLed
        self.assertNotEqual(code, 0, "signaled runner must refuse")
        self.assertIn("killed by signal 9", err.getvalue(),
                      "user-visible refusal must name signal 9")
        self.assertEqual(runner_calls(events), [ [RUNNER, "90", INSMOD, AOP] ],
                         "exactly the initial guarded load, no retry")
        self.assertEqual(self.tuple_events(events, "unlink"), [], "latch kept on signal")
        self.assertIn(resolve(LATCH), fs.files, "durable latch retained")
        self.assertIn(resolve(MARKER), fs.mkdir_calls, "marker kept")
        # Simulated reboot: /run marker lost, latch persists.
        fs.dirs.discard(resolve("/run"))
        fs.dirs.discard(resolve(MARKER))
        fs.mkdir_calls.clear()
        code2, events2 = run_loader(fs)  # next boot
        self.assertNotEqual(code2, 0, "latch refusal carries to the next boot")
        self.assertEqual(runner_calls(events2), [], "no module attempt after signal")

    def test_latch_faults_fail_closed(self):
        # os.open on the latch raises: refuse, no runner, no latch left.
        fs = make_fs()
        code, events = run_loader(fs, latch_open_fails=True)
        self.assertNotEqual(code, 0, "latch open failure must refuse")
        self.assertEqual(runner_calls(events), [], "no module attempt")
        self.assertNotIn(resolve(LATCH), fs.files, "no latch created")

        # fsync failure mid-take: latch file exists but never cleared; no runner ran.
        fs = make_fs()
        with self.assertRaises(OSError):
            run_loader(fs, fsync_fails=True)
        self.assertIn(resolve(LATCH), fs.files, "latch retained after fsync failure")
        self.assertEqual(fs.remove_calls, [], "latch never cleared")
        code2, events2 = run_loader(fs)  # next boot: retained latch refuses
        self.assertNotEqual(code2, 0, "latch refusal after fsync failure")
        self.assertEqual(runner_calls(events2), [], "no module attempt after fsync failure")

        # subprocess.run raises OSError (exec failure): refuse, latch retained, marker kept.
        fs = make_fs()
        with mock.patch("sys.stderr", new=io.StringIO()) as err:
            code, events = run_loader(fs, run_oserror=True)
        self.assertNotEqual(code, 0)
        self.assertIn("cannot execute the watchdog runner", err.getvalue())
        self.assertIn(resolve(LATCH), fs.files, "latch retained on runner OSError")
        self.assertEqual(fs.remove_calls, [], "latch never cleared")
        self.assertIn(resolve(MARKER), fs.mkdir_calls, "marker kept")

    def test_crash_retains_latch_and_blocks_next_boot(self):
        fs = make_fs()
        with self.assertRaises(RuntimeError):
            run_loader(fs, runner_raises=True)  # simulated kill/exception mid-load
        self.assertIn(resolve(LATCH), fs.files, "crash retains the durable latch")
        # Simulated /run loss between boots: the latch alone must still refuse.
        fs.dirs.discard(resolve("/run"))
        fs.dirs.discard(resolve(MARKER))
        fs.mkdir_calls.clear()
        code, events = run_loader(fs)
        self.assertNotEqual(code, 0, "latch refusal after /run loss")
        self.assert_no_module_path_taken(fs, events)

    def test_manifest_selected_for_running_release(self):
        release = "7.3.0-k114c-2"
        path = "/usr/lib/aop-boot-guard/manifests/%s/manifest.json" % release
        blob = ("vermagic=%s SMP preempt mod_unload aarch64\n" % release).encode()
        fs = make_fs()
        fs.add_file(path, manifest_bytes(rel=release, aop=sha(blob), dai=sha(blob)), 0o644)
        aop = "/lib/modules/%s/kernel/drivers/soc/apple/aop.ko" % release
        dai = "/lib/modules/%s/kernel/sound/soc/apple/snd-soc-t8152-aop-audio.ko" % release
        fs.add_file(aop, blob)
        fs.add_file(dai, blob)
        code, events = run_loader(fs, release=release)
        self.assertEqual(code, 0, "manifest must be selected by running release")
        self.assertEqual([call[-1] for call in runner_calls(events)], [aop, dai])
        self.assertNotIn(resolve(LATCH), fs.files, "successful loads clear latch")

    def test_unknown_release_and_hash_mismatch_still_refuse(self):
        unknown = make_fs()
        code, events = run_loader(unknown, release="7.3.0-k114c-9")
        self.assertNotEqual(code, 0, "unknown release must refuse")
        self.assertFalse(runner_calls(events))
        wrong = make_fs()
        wrong.add_file(AOP, VERMAGIC + b"x")
        with mock.patch("sys.stderr", new=io.StringIO()) as err:
            code, events = run_loader(wrong)
        self.assertNotEqual(code, 0, "wrong module hash must refuse")
        self.assertFalse(runner_calls(events))
        self.assertIn("aop module %s does not match the pinned manifest hash" % AOP,
                      err.getvalue(), "valid vermagic must reach the hash check")

    def test_manifest_release_must_match_running_release(self):
        fs = make_fs()
        fs.add_file(MANIFEST_PATH, manifest_bytes(rel="7.3.0-k114c-0"), 0o644)
        with mock.patch("sys.stderr", new=io.StringIO()) as err:
            code, events = run_loader(fs)
        self.assertNotEqual(code, 0)
        self.assertFalse(runner_calls(events))
        self.assertIn("manifest pins 7.3.0-k114c-0 but %s is running" % REL,
                      err.getvalue())


if __name__ == "__main__":
    unittest.main()
