#!/usr/bin/env python3
"""Nested Wayland regression for grouped cross-monitor swaps (Hyprland 0.56).

Requires python3, foot, and the selected compositor's installed runtime libraries.
Run: python3 pkgbuilds/hyprland/test-group-workspace.py \
         --hyprland /path/to/Hyprland --hyprctl /usr/bin/hyprctl
The parent Wayland display is used only as a rendering backend (one temporary
nested window). No parent IPC, plugins, desktop configuration, or bus is used.
Each case gets a fresh compositor; --members and --both-groups select one case.
"""

import argparse
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time


class RegressionError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise RegressionError(message)


def stop(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)


def run_case(args, members, both_groups):
    label = f"members={members}, both_groups={both_groups}"
    print(f"CASE {label}", flush=True)
    with tempfile.TemporaryDirectory(prefix="hypr-group-workspace-") as directory:
        root = Path(directory)
        # Deliberate allowlist: never inherit DISPLAY, HYPRLAND_*,
        # DBUS_*, AQ_*, XDG_*, plugin preload variables, or a desktop HOME.
        env = {"PATH": os.defpath, "LANG": "C.UTF-8",
               "WAYLAND_DISPLAY": args.parent_display, "XDG_SESSION_TYPE": "wayland",
               # 0.56.2 has no headless-only support. Force the Wayland fallback,
               # never the live DRM session; parent socket is explicitly absolute.
               "AQ_DRM_DEVICES": str(root / "no-drm-device")}
        for key in ("HOME", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
                    "XDG_STATE_HOME", "XDG_DATA_HOME", "TMPDIR"):
            path = root / key.lower()
            path.mkdir(mode=0o700)
            env[key] = str(path)
        # Keep actual files in TMPDIR, but use a short private directory alias:
        # scratch paths plus Hyprland's instance name exceed sockaddr_un.sun_path.
        runtime_fd = os.open(env["XDG_RUNTIME_DIR"], os.O_RDONLY | os.O_DIRECTORY)
        runtime = Path(f"/proc/{os.getpid()}/fd/{runtime_fd}")
        env["XDG_RUNTIME_DIR"] = str(runtime)
        config = root / "hyprland.lua"
        config.write_text('''hl.config({
    general = { layout = "dwindle" },
    debug = { enable_stdout_logs = true },
    animations = { enabled = false },
    misc = { disable_hyprland_logo = true, disable_splash_rendering = true }
})
hl.monitor({ output = "", mode = "1280x720@60", position = "auto", scale = 1 })
''')
        children = []
        logs = []
        proc = None
        identity = None
        failure = None

        def launch(command, name):
            log = open(root / (name + ".log"), "w")
            logs.append(log)
            return subprocess.Popen(command, env=env, cwd=root, stdout=log,
                                    stderr=log, start_new_session=True)

        def ctl(*command):
            require(proc.poll() is None, f"compositor exited {proc.returncode}: {command}")
            require(identity is not None or command == ("instances", "-j"),
                    "refusing a control command before child PID identification")
            argv = [args.hyprctl]
            if identity:
                argv += ["--instance", identity["instance"]]
            result = subprocess.run(argv + list(command), env=env, cwd=root,
                                    capture_output=True, text=True, timeout=3)
            require(result.returncode == 0,
                    f"hyprctl {command}: {result.stdout} {result.stderr}")
            return result.stdout.strip()

        def wait_for(description, predicate, timeout=8):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                require(proc.poll() is None,
                        f"compositor exited {proc.returncode} waiting for {description}")
                result = predicate()
                if result:
                    return result
                time.sleep(0.05)
            raise RegressionError(f"timeout waiting for {description}")

        def ev(code):
            response = ctl("eval", code)
            require(response == "ok", f"eval {code}: {response}")

        def dispatch(code):
            ev(f"hl.dispatch(hl.dsp.{code})")

        def clients():
            return json.loads(ctl("-j", "clients"))

        def group_windows(addresses):
            windows = [w for w in clients() if w["address"] in addresses]
            require(len(windows) == len(addresses), "a test group member disappeared")
            return windows

        def focus(address):
            dispatch(f'focus({{ window = "address:{address}" }})')

        def open_window():
            child = launch([args.foot, "--config=/dev/null", "--app-id=group-workspace-test",
                            "sleep", "600"], f"foot-{len(children)}")
            children.append(child)
            return wait_for("foot window", lambda: next(
                (w["address"] for w in clients() if w["pid"] == child.pid), None))

        def make_group(monitor, workspace, count, grouped):
            dispatch(f'focus({{ monitor = "{monitor}" }})')
            dispatch(f'focus({{ workspace = "{workspace}" }})')
            first = open_window()
            addresses = [first]
            if grouped:
                focus(first)
                dispatch("group.toggle()")
                for _ in range(count - 1):
                    focus(first)
                    addresses.append(open_window())
                expected = set(addresses)
                wait_for("complete group", lambda: all(
                    set(w["grouped"]) == expected for w in clients()
                    if w["address"] in expected))
            return addresses

        try:
            proc = launch([args.hyprland, "--config", str(config)], "compositor")

            def discover():
                try:
                    found = json.loads(ctl("instances", "-j"))
                except (RegressionError, json.JSONDecodeError):
                    return None
                return next((i for i in found if i["pid"] == proc.pid), None)

            identity = wait_for("private IPC identity", discover)
            instance_path = runtime / "hypr" / identity["instance"]
            wait_for("private IPC socket", lambda: (instance_path / ".socket.sock").is_socket())
            wait_for("private Wayland socket", lambda: (runtime / identity["wl_socket"]).is_socket())
            require(os.path.samefile(f"/proc/{proc.pid}/exe", args.hyprland),
                    "running compositor is not the selected executable")
            env.update(HYPRLAND_INSTANCE_SIGNATURE=identity["instance"],
                       WAYLAND_DISPLAY=identity["wl_socket"])
            print(f"PRIVATE pid={proc.pid} runtime={runtime} instance={identity['instance']} "
                  f"binary={args.hyprland}", flush=True)
            require(not ctl("configerrors"), "configuration errors")
            for name, x in (("TEST-LEFT", 0), ("TEST-RIGHT", 1280)):
                require(ctl("output", "create", "headless", name) == "ok", "create output failed")
                ev(f'hl.monitor({{ output = "{name}", mode = "1280x720@60", '
                   f'position = "{x}x0", scale = 1 }})')
            # Remove only the child's nested backend output after test outputs
            # exist. Otherwise a third monitor changes directional swap selection.
            for monitor in json.loads(ctl("-j", "monitors")):
                if monitor["name"].startswith("WAYLAND-"):
                    require(ctl("output", "remove", monitor["name"]) == "ok",
                            "remove child nested output failed")
            wait_for("two headless outputs", lambda: len(json.loads(ctl("-j", "monitors"))) == 2)
            left = make_group("TEST-LEFT", 11, members, True)
            right = make_group("TEST-RIGHT", 12, members if both_groups else 1, both_groups)
            focus(left[0])
            dispatch('window.swap({ direction = "r" })')
            observed = clients()
            print("AFTER_SWAP " + json.dumps(observed), flush=True)
            mismatches = []
            for addresses, workspace, monitor, grouped in (
                    (left, 12, "TEST-RIGHT", True), (right, 11, "TEST-LEFT", both_groups)):
                monitor_id = next(m["id"] for m in json.loads(ctl("-j", "monitors"))
                                  if m["name"] == monitor)
                for address in addresses:
                    window = next(w for w in observed if w["address"] == address)
                    if window["workspace"]["id"] != workspace or window["monitor"] != monitor_id:
                        mismatches.append(f"{address}: workspace={window['workspace']['id']}, "
                                          f"monitor={window['monitor']}; expected {workspace}/{monitor}")
                    require(set(window["grouped"]) == (set(addresses) if grouped else set()),
                            f"group membership changed for {address}")
            # Do not stop at the assignment failure: exercise the stale-space transition too.
            if mismatches:
                print("WORKSPACE_MISMATCH " + "; ".join(mismatches), flush=True)
            for address in left:
                dispatch(f'window.float({{ action = "on", window = "address:{address}" }})')
            require(all(w["floating"] for w in group_windows(left)),
                    "not all group members floated")
            for monitor, workspace in (("TEST-LEFT", 21), ("TEST-RIGHT", 22)):
                dispatch(f'focus({{ monitor = "{monitor}" }})')
                dispatch(f'focus({{ workspace = "{workspace}" }})')
            if mismatches:
                wait_for("stale layout workspace 12 destruction", lambda:
                         all(w["id"] != 12 for w in json.loads(ctl("-j", "workspaces"))))
                print("STALE_WORKSPACE_DESTROYED 12", flush=True)
            else:
                require(any(w["id"] == 12 for w in json.loads(ctl("-j", "workspaces"))),
                        "destination workspace disappeared despite containing the group")
            for _ in range(10):
                for action, floating in (("off", False), ("on", True)):
                    for address in left:
                        dispatch(f'window.float({{ action = "{action}", window = "address:{address}" }})')
                    require(all(w["floating"] == floating for w in group_windows(left)),
                            f"float action {action} did not apply to every member")
            for address in left:
                dispatch(f'window.float({{ action = "off", window = "address:{address}" }})')
            require(all(w["workspace"]["id"] == 12 and not w["floating"]
                        for w in group_windows(left)),
                    "group failed to remain on destination workspace after retiling")
            require(not mismatches, "cross-monitor group workspace mismatch: " + "; ".join(mismatches))
            print(f"PASS {label}: assignments and 10 float/retile cycles", flush=True)
        except Exception as error:
            failure = error
        finally:
            for child in children:
                stop(child)
            if proc is not None:
                if identity and proc.poll() is None:
                    try:
                        wait_for("all client unmaps before shutdown", lambda: not clients())
                    except Exception as error:
                        failure = failure or error
                stop(proc)
                print(f"COMPOSITOR_EXIT {proc.returncode}", flush=True)
                if proc.returncode != 0:
                    failure = failure or RegressionError(f"unclean compositor exit: {proc.returncode}")
            for log in logs:
                log.close()
            if args.results_dir:
                destination = args.results_dir / f"members-{members}-both-{int(both_groups)}"
                shutil.copytree(root, destination, ignore=lambda directory, names: [
                    name for name in names if (Path(directory) / name).is_socket()])
                print(f"LOGS {destination}", flush=True)
            os.close(runtime_fd)
            if failure:
                print(f"FAIL {label}: {failure}", file=sys.stderr)
                paths = set(root.glob("*.log")) | set(root.rglob("hyprland.log"))
                for path in sorted(paths):
                    print(f"--- {path.name} (last 60 lines) ---", file=sys.stderr)
                    print("\n".join(path.read_text(errors="replace").splitlines()[-60:]), file=sys.stderr)
        return failure is None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hyprland", required=True, help="exact compositor executable to test")
    parser.add_argument("--hyprctl", required=True, help="compatible hyprctl executable")
    parser.add_argument("--parent-display", help="parent Wayland socket (default: current display)")
    parser.add_argument("--results-dir", type=Path, help="new directory to preserve each case's logs")
    parser.add_argument("--members", type=int, choices=(1, 2), help="select group size (default: both)")
    parser.add_argument("--both-groups", action="store_true", help="select group-to-group cases only")
    args = parser.parse_args()
    parent_display = args.parent_display or os.environ.get("WAYLAND_DISPLAY")
    if not parent_display:
        parser.error("a parent Wayland display is required")
    parent = Path(parent_display)
    if not parent.is_absolute():
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        if not runtime:
            parser.error("relative parent display requires XDG_RUNTIME_DIR")
        parent = Path(runtime) / parent
    if not parent.is_socket():
        parser.error(f"not a parent Wayland socket: {parent}")
    args.parent_display = str(parent.absolute())
    if args.results_dir:
        args.results_dir = args.results_dir.resolve()
        args.results_dir.mkdir(parents=True, exist_ok=False)
    for key in ("hyprland", "hyprctl"):
        path = Path(getattr(args, key)).resolve()
        parser.error(f"not executable: {path}") if not os.access(path, os.X_OK) else None
        setattr(args, key, str(path))
    args.foot = shutil.which("foot")
    if not args.foot:
        parser.error("foot is required")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    results = [run_case(args, members, both) for members in
               ([args.members] if args.members else (1, 2)) for both in
               ((True,) if args.both_groups else (False, True))]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
