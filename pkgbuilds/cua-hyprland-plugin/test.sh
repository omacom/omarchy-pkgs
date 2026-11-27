#!/bin/bash

# cua-hyprland-plugin-load against a stand-in Hyprland, verifier and session. Nothing of Cua's runs here.

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# /proc names files by their real path.
scratch=$(realpath "$(mktemp -d)")
fixtures=()
trap 'kill "${fixtures[@]}" 2>/dev/null || true; wait 2>/dev/null || true; rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

module=/usr/lib/cua/hyprland/cua-hyprland-plugin.so
stubs="$scratch/bin"
session="$scratch/run/hypr/session"
mkdir -p "$stubs" "$session"

# hyprctl: the plugin list follows $scratch/loaded, and a load answers $scratch/answer and loads only on "ok".
cat >"$stubs/hyprctl" <<EOF
#!/bin/bash
echo "\$*" >>"$scratch/hyprctl.calls"
case "\$*" in
  "plugin list") [[ -e "$scratch/loaded" ]] && printf '\nPlugin cua-hyprland-plugin by Cua:\n\tHandle: 1\n' ;;
  "plugin load "*) cat "$scratch/answer"; [[ \$(cat "$scratch/answer") == "ok" ]] && touch "$scratch/loaded" ;;
esac
exit 0
EOF
# The verifier: records how it was asked and answers as $scratch/verdict says, on the streams Cua's uses.
cat >"$stubs/python3" <<EOF
#!/bin/bash
echo "\$*" >>"$scratch/verifier.calls"
if [[ \$(cat "$scratch/verdict") == "0" ]]; then echo "Passed installed profile compatibility checks"; else echo "error: native package mismatch: hyprland" >&2; fi
exit "\$(cat "$scratch/verdict")"
EOF
printf '#!/bin/bash\n[[ $1 == "/usr/share/cua-hyprland-plugin/KIT-PROVENANCE.json" ]] && echo "digest-of-the-installed-kit  $1"\n' >"$stubs/sha256sum"
chmod +x "$stubs"/*

# A session's compositor: a process running a file at a path with a space, which an update can replace under it.
cp "$(command -v sleep)" "$scratch/a compositor"
"$scratch/a compositor" 600 &
compositor=$!
fixtures+=("$compositor")
for _ in $(seq 100); do [[ $(readlink "/proc/$compositor/exe") == "$scratch/a compositor" ]] && break; sleep 0.1; done
[[ $(readlink "/proc/$compositor/exe") == "$scratch/a compositor" ]] || fail "the compositor fixture is running its own file"
printf '%s\nwayland-1\n' "$compositor" >"$session/hyprland.lock"

# The loader names the system's compositor and interpreter outright. The copy under test gets this run's stand-ins for those two lines and nothing else.
grep -qx 'hyprland=/usr/bin/Hyprland' "$package_dir/cua-hyprland-plugin-load" && grep -qx 'python=/usr/bin/python3' "$package_dir/cua-hyprland-plugin-load" ||
  fail "the loader names the system's compositor and interpreter"
installed="$scratch/a compositor"

load() {
  rm -f "$scratch/hyprctl.calls" "$scratch/verifier.calls"
  sed -e "s|^hyprland=.*|hyprland='$installed'|" -e "s|^python=.*|python='$stubs/python3'|" "$package_dir/cua-hyprland-plugin-load" >"$scratch/loader"
  PATH="$stubs:$PATH" XDG_RUNTIME_DIR="$scratch/run" HYPRLAND_INSTANCE_SIGNATURE=session \
    bash "$scratch/loader" >"$scratch/out" 2>&1
}

load_asked() {
  grep -q "^plugin load" "$scratch/hyprctl.calls" 2>/dev/null
}

fresh() {
  rm -f "$scratch/loaded"
  echo 0 >"$scratch/verdict"
  echo ok >"$scratch/answer"
}

fresh
load || fail "a fresh session with the matching packages loads the module: $(cat "$scratch/out")"
(( $(grep -c "^plugin load" "$scratch/hyprctl.calls") == 1 )) && grep -qxF "plugin load $module" "$scratch/hyprctl.calls" && [[ -e $scratch/loaded ]] ||
  fail "the packaged module is loaded through hyprctl, once"
grep -qxF -- "-I /usr/share/cua-hyprland-plugin/profile_verify.py --kit /usr/share/cua-hyprland-plugin --kit-sha256 digest-of-the-installed-kit --consumer $module" "$scratch/verifier.calls" ||
  fail "Cua's consumer check is run isolated, against the installed kit and module"

load || fail "a second run in the same session succeeds"
load_asked && fail "a module that is already loaded is not loaded again"
[[ ! -e $scratch/verifier.calls ]] || fail "a module that is already loaded is not checked again"

fresh
echo 1 >"$scratch/verdict"
load && fail "packages the module was not built for are refused"
load_asked && fail "nothing is loaded when the consumer check fails"
grep -q "does not match the Hyprland and libraries installed" "$scratch/out" || fail "the refusal says the packages moved"
grep -q "native package mismatch: hyprland" "$scratch/out" || fail "the refusal passes on which package the verifier named"

fresh
echo "Plugin $module could not be loaded: ABI fingerprint mismatch" >"$scratch/answer"
load && fail "a module Hyprland turned down is not reported as loaded"
grep -q "Hyprland did not load the plugin: Plugin $module could not be loaded: ABI fingerprint mismatch" "$scratch/out" ||
  fail "Hyprland's own answer is passed on"

# Executable memory with no file behind it reads as deleted without any file having been replaced.
fresh
/usr/bin/python3 -c '
import mmap, os, time
fd = os.memfd_create("jit")
os.ftruncate(fd, mmap.PAGESIZE)
private = mmap.mmap(fd, mmap.PAGESIZE, flags=mmap.MAP_PRIVATE, prot=mmap.PROT_READ | mmap.PROT_EXEC)
shared = mmap.mmap(-1, mmap.PAGESIZE, flags=mmap.MAP_SHARED | mmap.MAP_ANONYMOUS, prot=mmap.PROT_READ | mmap.PROT_EXEC)
print(os.getpid(), flush=True)
time.sleep(600)' >"$scratch/memfd.pid" &
fixtures+=($!)
for _ in $(seq 100); do [[ -s $scratch/memfd.pid ]] && break; sleep 0.1; done
memfd=$(cat "$scratch/memfd.pid")
grep -q '^[^ ]* r-xp .*/memfd:jit (deleted)$' "/proc/$memfd/maps" || fail "the fixture holds a private executable memfd mapping"
grep -q '^[^ ]* r-xs .*/dev/zero (deleted)$' "/proc/$memfd/maps" || fail "the fixture holds a shared anonymous executable mapping"
printf '%s\nwayland-1\n' "$memfd" >"$session/hyprland.lock"
installed=$(readlink "/proc/$memfd/exe")
load || fail "executable memory with no file behind it is not a replaced file: $(cat "$scratch/out")"

# The same healthy process, when the installed compositor is another file: started from elsewhere on PATH, say.
fresh
installed="$scratch/a compositor"
load && fail "a session running a compositor other than the installed one is refused"
load_asked && fail "nothing is loaded into a compositor other than the installed one"
grep -qF "This session is not running the installed $scratch/a compositor." "$scratch/out" || fail "the refusal says which compositor is the installed one"
printf '%s\nwayland-1\n' "$compositor" >"$session/hyprland.lock"

# A scan of the session that could not run says nothing about it.
fresh
printf '#!/bin/bash\nexit 2\n' >"$stubs/awk"
chmod +x "$stubs/awk"
load && fail "a session that could not be scanned is refused"
load_asked && fail "nothing is loaded when the session could not be scanned"
grep -q "Could not scan this session" "$scratch/out" || fail "a failed scan is not reported as a replaced file"
rm "$stubs/awk"

# An update replaces the compositor's file; the session goes on running the old one.
fresh
rm "$scratch/a compositor"
grep -q "^[^ ]* r.x.* $scratch/a compositor (deleted)\$" "/proc/$compositor/maps" || fail "the compositor fixture still maps the file that was replaced"
load && fail "a session that predates an update is refused"
load_asked && fail "nothing is loaded into a compositor that predates an update"
grep -qF "An update replaced $scratch/a compositor under this session. Log out and back in" "$scratch/out" ||
  fail "the refusal names the replaced file and says to start a new session"
grep -q "Passed" "$scratch/out" && fail "a refusal does not open with the verifier's pass"
grep -q "not running the installed" "$scratch/out" && fail "a replaced compositor is not also reported as another compositor"

fresh
printf '%s\nwayland-1\n' 999999999 >"$session/hyprland.lock"
load && fail "a compositor that cannot be read is refused"
load_asked && fail "nothing is loaded when the compositor cannot be read"
grep -q "No Hyprland session here" "$scratch/out" || fail "a compositor that cannot be read is reported as no session"

# /proc/self would be the reader's own mappings, not a compositor's.
fresh
printf 'self\nwayland-1\n' >"$session/hyprland.lock"
load && fail "a lock that names no process is refused"
[[ ! -e $scratch/hyprctl.calls && ! -e $scratch/verifier.calls ]] || fail "nothing is asked of Hyprland or the verifier on a lock that names no process"

fresh
rm "$session/hyprland.lock"
load && fail "a session directory with no compositor behind it is refused"
[[ ! -e $scratch/hyprctl.calls && ! -e $scratch/verifier.calls ]] || fail "nothing is asked of Hyprland or the verifier without a session"

printf '%s\nwayland-1\n' "$memfd" >"$session/hyprland.lock"
PATH="$stubs:$PATH" bash -c 'unset XDG_RUNTIME_DIR HYPRLAND_INSTANCE_SIGNATURE; exec bash "$1"' _ "$scratch/loader" >"$scratch/out" 2>&1 &&
  fail "a shell with no session in its environment is refused"
grep -q "No Hyprland session here" "$scratch/out" || fail "the refusal outside a session says where to run it"

echo "ok - cua-hyprland-plugin-load loads only a checked module into a current session"
