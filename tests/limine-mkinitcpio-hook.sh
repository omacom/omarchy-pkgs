#!/bin/bash
# limine-mkinitcpio-hook: the x86_64 package is upstream's as before. On
# aarch64, limine-apple-gate leaves every machine but an Apple Silicon Mac as
# the x86_64 package behaves; a Mac keeps /boot current through mkinitcpio's
# own kernel hook, and Limine waits until Omarchy activates it.
#
# The package() of the PKGBUILD runs over an upstream-shaped source tree
# (LIMINE_ENTRY_TOOL_SRC may name a real limine-entry-tool checkout instead),
# and pacman transactions replay through the packaged hooks on fixture machines.
set -euo pipefail

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
RECIPE=$REPO_ROOT/pkgbuilds/limine-mkinitcpio-hook
GATE=$RECIPE/limine-apple-gate
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "not ok - $1" >&2
  [[ $# -lt 2 ]] || printf '%s\n' "$2" >&2
  exit 1
}
pass() {
  echo "ok - $1"
}

# pacman hands NeedsTargets to a hook over a socket, and a hook that stops
# reading early fails the write ("unable to write to pipe").
SOCKET_FEED='
import socket, subprocess, sys
parent, child = socket.socketpair()
hook = subprocess.Popen(sys.argv[1:], stdin=child)
child.close()
try:
    parent.sendall(sys.stdin.buffer.read())
    parent.shutdown(socket.SHUT_WR)
except OSError as error:
    print("unable to write to pipe (%s)" % error.strerror, file=sys.stderr)
    hook.wait()
    sys.exit(141)
sys.exit(hook.wait())
'
socket_feed() { python3 -c "$SOCKET_FEED" "$@"; }

apple_tree() { printf 'apple,j316s\0apple,t6000\0apple,arm-platform\0'; }
live_is_mac() {
  local source
  for source in /proc/device-tree/compatible /sys/firmware/devicetree/base/compatible; do
    [[ -r $source ]] && tr '\0' '\n' <"$source" | grep -q '^apple,' && return 0
  done
  return 1
}

# The gate trusts fixtures only from an unprivileged caller: as root it reads
# the live machine. Check that, then carry on as nobody.
if ((EUID == 0)); then
  if ! live_is_mac; then
    mkdir -p "$TEST_ROOT/root-proc/device-tree"
    apple_tree >"$TEST_ROOT/root-proc/device-tree/compatible"
    out=$(OMARCHY_PROC_ROOT=$TEST_ROOT/root-proc bash "$GATE" echo ran </dev/null)
    [[ $out == ran ]] || fail "as root the gate ignores a fixture device tree" "$out"
    pass "as root the gate reads the live machine, not fixtures"
  fi
  rm -rf "$TEST_ROOT"
  exec setpriv --reuid=nobody --regid=nobody --clear-groups -- bash "$REPO_ROOT/tests/limine-mkinitcpio-hook.sh"
fi

# ---------------------------------------------------------------------------
# Sources: the local aarch64 sources are pinned, x86_64 has none.
bash -n "$RECIPE/PKGBUILD"
bash -n "$GATE"
mapfile -t sources < <(CARCH=aarch64 bash -c 'source "$1"; printf "%s\n" "${source_aarch64[@]}"' _ "$RECIPE/PKGBUILD")
mapfile -t sums < <(CARCH=aarch64 bash -c 'source "$1"; printf "%s\n" "${sha256sums_aarch64[@]}"' _ "$RECIPE/PKGBUILD")
((${#sources[@]} == ${#sums[@]})) || fail "every aarch64 source has a checksum"
local_sources=0
for i in "${!sources[@]}"; do
  [[ ${sources[i]} == *://* ]] && continue
  ((++local_sources))
  [[ $(sha256sum "$RECIPE/${sources[i]}" | cut -d' ' -f1) == "${sums[i]}" ]] ||
    fail "the PKGBUILD pins ${sources[i]} by its sha256"
done
((local_sources == 2)) || fail "limine-apple-gate and mkinitcpio-install.hook are the aarch64 local sources"
x86_sources=$(CARCH=x86_64 bash -c 'source "$1"; printf "%s\n" "${source[@]}" "${source_x86_64[@]}"' _ "$RECIPE/PKGBUILD")
[[ $x86_sources != *limine-apple-gate* && $x86_sources != *mkinitcpio-install.hook* ]] ||
  fail "x86_64 builds take no Apple Silicon source"
grep -Fxq 'Exec = /usr/share/libalpm/scripts/mkinitcpio install' "$RECIPE/mkinitcpio-install.hook" ||
  fail "mkinitcpio-install.hook is mkinitcpio's own kernel hook"
pass "the Apple Silicon sources are aarch64-only and pinned by checksum"

# ---------------------------------------------------------------------------
# package() for both architectures over the same upstream tree.
SRC=$TEST_ROOT/src
upstream=$SRC/limine-entry-tool
mkdir -p "$upstream/build/native/nativeCompile"
if [[ -n ${LIMINE_ENTRY_TOOL_SRC:-} ]]; then
  cp -a "$LIMINE_ENTRY_TOOL_SRC/install" "$LIMINE_ENTRY_TOOL_SRC/README.md" "$LIMINE_ENTRY_TOOL_SRC/CHANGELOG.md" "$upstream/"
else
  tool=$upstream/install/arch-linux/limine-entry-tool
  hook=$upstream/install/arch-linux/limine-mkinitcpio-hook
  mkdir -p "$tool/etc/boot/hooks/pre.d" "$tool/usr/bin" "$tool/usr/lib/limine" "$tool/usr/share/libalpm/hooks" \
    "$hook/etc/pacman.d/hooks" "$hook/usr/bin" "$hook/usr/local/bin" "$hook/usr/share/libalpm/hooks" "$hook/usr/share/libalpm/scripts"
  echo '# README' >"$upstream/README.md"
  echo '# CHANGELOG' >"$upstream/CHANGELOG.md"
  echo 'ESP_PATH=""' >"$tool/etc/limine-entry-tool.conf"
  echo 'ESP_PATH=""' >"$hook/etc/limine-entry-tool.conf"
  for name in limine-install limine-entry-tool limine-reset-enroll limine-enroll-config; do
    printf '#!/usr/bin/env bash\n' >"$tool/usr/bin/$name"
  done
  printf '#!/usr/bin/env bash\n' >"$tool/usr/lib/limine/limine-common-functions"
  for name in limine-mkinitcpio limine-update; do
    printf '#!/usr/bin/env bash\n' >"$hook/usr/bin/$name"
  done
  for name in limine-mkinitcpio-install limine-mkinitcpio-remove; do
    printf '#!/usr/bin/env bash\n' >"$hook/usr/share/libalpm/scripts/$name"
  done
  cat >"$tool/usr/share/libalpm/hooks/80-limine-efi-deploy.hook" <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine
Target = limine-git
Target = limine-dev

[Action]
Description = Deploying Limine after upgrade...
When = PostTransaction
Exec = /usr/bin/limine-install --no-efi-register
HOOK
  cat >"$hook/usr/share/libalpm/hooks/80-limine-efi-deploy.hook" <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine
Target = limine-git
Target = limine-dev
Target = limine-mkinitcpio-hook
Target = limine-mkinitcpio-hook-git

[Action]
Description = Deploying Limine after upgrade...
When = PostTransaction
Exec = /usr/bin/limine-install
HOOK
  cat >"$hook/usr/share/libalpm/hooks/60-limine-mkinitcpio-remove-pre.hook" <<'HOOK'
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/modules.builtin

[Action]
Description = Record kernels marked for removal in Limine
When = PreTransaction
Exec = /usr/share/libalpm/scripts/limine-mkinitcpio-remove pre
NeedsTargets
HOOK
  cat >"$hook/usr/share/libalpm/hooks/90-limine-mkinitcpio-remove-post.hook" <<'HOOK'
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/modules.builtin

[Action]
Description = Clean Limine boot entries of removed kernels
When = PostTransaction
Exec = /usr/share/libalpm/scripts/limine-mkinitcpio-remove post
HOOK
  cat >"$hook/etc/pacman.d/hooks/90-mkinitcpio-install.hook" <<'HOOK'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Operation = Remove
Target = usr/lib/initcpio/*
Target = usr/lib/firmware/*
Target = usr/lib/modules/*/extramodules/
Target = usr/src/*/dkms.conf
Target = usr/lib/systemd/systemd
Target = usr/bin/cryptsetup
Target = usr/bin/lvm

[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/modules.builtin

[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = mkinitcpio
Target = mkinitcpio-git

[Action]
Description = Updating linux initcpios...
When = PostTransaction
Exec = /usr/share/libalpm/scripts/limine-mkinitcpio-install
NeedsTargets
HOOK
  cat >"$hook/usr/local/bin/mkinitcpio" <<'WRAPPER'
#!/usr/bin/env bash

/usr/bin/mkinitcpio "$@"

_color_reset=""
_color_yellow=""
colors="$(tput colors 2>/dev/null || echo 0)"
if ((colors >= 8)); then
	_color_reset="\033[0m"
	_color_yellow="\033[1;33m"
fi

if [[ " $* " == *" -P "* || " $* " == *" --allpresets "* || " $* " == *" -p "* || " $* " == *" --preset "* ]]; then
	printf '%b==> WARNING: This does not update Limine boot entries.%b\n' "${_color_yellow}" "${_color_reset}" >&2
	printf "%b    Use 'limine-mkinitcpio' or 'limine-update' instead.%b\n" "${_color_yellow}" "${_color_reset}" >&2

	read -rp "==> Would you like to run 'limine-mkinitcpio' now? [Y/n]: " answer
	case "${answer,,}" in
	"" | "y" | "yes")
		/usr/bin/limine-mkinitcpio
		;;
	*)
		# nothing
		;;
	esac
fi
WRAPPER
fi
printf 'native image\n' >"$upstream/build/native/nativeCompile/limine-entry-tool"
chmod -R u+w,go+rX "$upstream"
find "$upstream/install" -path '*/bin/*' -type f -exec chmod 755 {} + -o -path '*/scripts/*' -type f -exec chmod 755 {} +
ln -s "$RECIPE/limine-apple-gate" "$RECIPE/mkinitcpio-install.hook" "$SRC/"

# makepkg runs package() with errexit.
build_package() {
  local arch=$1 out=$2
  mkdir -p "$out"
  CARCH=$arch srcdir=$SRC pkgdir=$out bash -euo pipefail -c 'source "$1"; package' _ "$RECIPE/PKGBUILD" ||
    fail "package() succeeds for $arch"
}
PKG_X86=$TEST_ROOT/pkg-x86_64
PKG_ARM=$TEST_ROOT/pkg-aarch64
build_package x86_64 "$PKG_X86"
build_package aarch64 "$PKG_ARM"

manifest() {
  (cd "$1" && find . \( -type f -o -type l \) -printf '%p %m %l\n' | LC_ALL=C sort) |
    while read -r path mode target; do
      if [[ -n $target ]]; then
        echo "$path $mode -> $target"
      else
        echo "$path $mode $(sha256sum "$1/$path" | cut -d' ' -f1)"
      fi
    done
}

scripts=/usr/share/libalpm/scripts
gate=$scripts/limine-apple-gate
upstream_hook=$upstream/install/arch-linux/limine-mkinitcpio-hook
for file in etc/pacman.d/hooks/90-mkinitcpio-install.hook usr/local/bin/mkinitcpio \
  usr/share/libalpm/hooks/{60-limine-mkinitcpio-remove-pre,80-limine-efi-deploy,90-limine-mkinitcpio-remove-post}.hook; do
  cmp -s "$upstream_hook/$file" "$PKG_X86/$file" || fail "x86_64 ships upstream's $file unchanged"
done
[[ ! -e $PKG_X86$gate && ! -e $PKG_X86/usr/share/libalpm/hooks/90-mkinitcpio-apple-install.hook ]] ||
  fail "x86_64 ships no Apple Silicon file"
pass "x86_64 packages upstream's hooks and wrapper unchanged"

differences=$(diff <(manifest "$PKG_X86") <(manifest "$PKG_ARM") || true)
changed=$(sed -n 's/^> \(\S*\) .*/\1/p' <<<"$differences")
expected=$(printf '%s\n' ./etc/pacman.d/hooks/90-mkinitcpio-install.hook \
  ./usr/local/bin/mkinitcpio \
  ./usr/share/libalpm/hooks/60-limine-mkinitcpio-remove-pre.hook \
  ./usr/share/libalpm/hooks/80-limine-efi-deploy.hook \
  ./usr/share/libalpm/hooks/90-limine-mkinitcpio-remove-post.hook \
  ./usr/share/libalpm/hooks/90-mkinitcpio-apple-install.hook \
  ./usr/share/libalpm/scripts/limine-apple-gate)
[[ $changed == "$expected" ]] || fail "aarch64 differs from x86_64 only in the gated hooks, the wrapper and the gate" "$changed"
[[ -z $(sed -n 's/^< \(\S*\) .*/\1/p' <<<"$differences" | grep -vxF "$expected") ]] ||
  fail "aarch64 keeps every x86_64 file"
[[ $(stat -c %a "$PKG_ARM$gate") == 755 ]] || fail "the gate is executable"
diff <(grep -v '^Exec = \|^Description = ' "$RECIPE/mkinitcpio-install.hook") \
  <(grep -v '^Exec = \|^Description = ' "$PKG_ARM/usr/share/libalpm/hooks/90-mkinitcpio-apple-install.hook") >/dev/null ||
  fail "the Mac's kernel hook keeps mkinitcpio's triggers"
[[ $(sed -n 2p "$PKG_ARM/usr/local/bin/mkinitcpio") == "$gate --mac && exec /usr/bin/mkinitcpio \"\$@\"" ]] ||
  fail "the aarch64 wrapper is plain mkinitcpio on a Mac"
pass "aarch64 routes Limine's hooks and the wrapper through the gate and adds the Mac's kernel hook"

# ---------------------------------------------------------------------------
# Fixture machines, read through OMARCHY_PROC_ROOT, OMARCHY_LIMINE_GATE and
# OMARCHY_LIMINE_DEFAULT.
machine() {
  local name=$1 compatible=$2 dir=$TEST_ROOT/machines/$1
  mkdir -p "$dir/proc" "$dir/state"
  if [[ -n $compatible ]]; then
    mkdir -p "$dir/proc/device-tree"
    printf "$compatible" >"$dir/proc/device-tree/compatible"
  fi
}
machine x86 ''
machine generic-aarch64 'linux,dummy-virt\0'
machine qualcomm 'lenovo,thinkpad-t14s\0qcom,x1e78100\0qcom,x1e80100\0'
machine mac-dormant 'apple,j316s\0apple,t6000\0apple,arm-platform\0'
machine mac-marker-only 'apple,j316s\0apple,t6000\0apple,arm-platform\0'
machine mac-active 'apple,j316s\0apple,t6000\0apple,arm-platform\0'
: >"$TEST_ROOT/machines/mac-marker-only/state/limine.enabled"
: >"$TEST_ROOT/machines/mac-active/state/limine.enabled"
echo 'ESP_PATH="/boot/efi"' >"$TEST_ROOT/machines/mac-active/state/limine"

on() {
  local dir=$TEST_ROOT/machines/$1
  shift
  (
    export OMARCHY_PROC_ROOT=$dir/proc OMARCHY_LIMINE_GATE=$dir/state/limine.enabled OMARCHY_LIMINE_DEFAULT=$dir/state/limine
    "$@"
  )
}
status() {
  local rc=0
  "$@" || rc=$?
  echo "$rc"
}

for m in x86 generic-aarch64 qualcomm; do
  [[ $(on "$m" status bash "$GATE" --mac) == 1 ]] || fail "$m is not a Mac"
  [[ $(printf 'a\nb\n' | on "$m" bash "$GATE" cat) == $'a\nb' ]] || fail "$m runs Limine's hooks with their targets"
  [[ $(on "$m" status bash "$GATE" bash -c 'exit 7' </dev/null) == 7 ]] || fail "$m keeps the hook's status"
  [[ -z $(printf 'a\n' | on "$m" bash "$GATE" --mac cat 2>&1) ]] || fail "$m skips the Mac's hooks quietly"
  [[ $(on "$m" bash "$GATE" --not-mac echo ran </dev/null) == ran ]] || fail "$m deploys Limine's EFI binary"
done
for m in mac-dormant mac-marker-only mac-active; do
  [[ $(on "$m" status bash "$GATE" --mac) == 0 ]] || fail "$m is a Mac"
  [[ $(printf 'a\n' | on "$m" bash "$GATE" --mac cat) == a ]] || fail "$m runs the Mac's hooks with their targets"
  [[ -z $(printf 'a\n' | on "$m" bash "$GATE" --not-mac cat 2>&1) ]] || fail "$m leaves Limine's EFI binary to omarchy-mac-boot"
done
for m in mac-dormant mac-marker-only; do
  out=$(printf 'usr/lib/modules/7.1.0/modules.builtin\n' | on "$m" bash "$GATE" bash -c 'echo ran; exit 100' 2>&1) ||
    fail "$m passes over Limine's hooks successfully"
  [[ -z $out ]] || fail "$m passes over Limine's hooks quietly" "$out"
  [[ -z $(on "$m" bash "$GATE" echo ran <&- 2>&1) ]] || fail "$m passes over a hook without targets"
done
# A linux-firmware upgrade streams thousands of targets, more than a socket holds.
many_targets() { printf 'usr/lib/firmware/fixture/%s.bin\n' $(seq 60000); }
many_targets | on mac-dormant socket_feed bash "$GATE" true || fail "a dormant Mac reads every target of a hook it passes over"
many_targets | on x86 socket_feed bash "$GATE" --mac true || fail "other machines read every target of the Mac's hooks"
many_targets | on mac-active socket_feed bash "$GATE" --not-mac true || fail "a Mac reads every target of the deploy hook"
many_targets | on mac-dormant bash "$GATE" true || fail "a dormant Mac reads every target piped to a hook it passes over"
[[ $(printf 'a\n' | on mac-active bash "$GATE" bash -c 'echo "ran $1"; cat' _ post) == $'ran post\na' ]] ||
  fail "an active Mac runs Limine's hooks with their arguments and targets"
[[ $(on mac-active status bash "$GATE" bash -c 'exit 7' </dev/null) == 7 ]] || fail "an active Mac keeps the hook's status"
[[ $(on x86 status bash "$GATE" </dev/null 2>/dev/null) == 2 ]] || fail "the gate needs a command"
pass "the gate runs Limine's hooks everywhere but a Mac that has not activated Limine"

# ---------------------------------------------------------------------------
# pacman: hooks from /usr/share/libalpm/hooks, overridden by name from
# /etc/pacman.d/hooks, run in name order, each with the targets of the
# transaction its triggers match (sorted, over a socket for NeedsTargets,
# else no stdin).
# Transactions are lines of "<Operation> <Path|Package> <target>".
fake_root() {
  local pkg=$1 root=$2 name
  cp -a "$pkg" "$root"
  cp "$RECIPE/mkinitcpio-install.hook" "$root/usr/share/libalpm/hooks/90-mkinitcpio-install.hook"
  for name in usr/share/libalpm/scripts/limine-mkinitcpio-install usr/share/libalpm/scripts/limine-mkinitcpio-remove \
    usr/bin/limine-install usr/share/libalpm/scripts/mkinitcpio usr/bin/mkinitcpio usr/bin/limine-mkinitcpio; do
    rm -f "$root/$name"
    printf '#!/bin/bash\n{ printf %%s %q; if (($#)); then printf " %%s" "$@"; fi; echo; if [[ -S /dev/stdin || -p /dev/stdin ]]; then sed "s/^/  /"; fi; } >>"$SIM_LOG"\n' \
      "${name##*/}" >"$root/$name"
    chmod 755 "$root/$name"
  done
}

run_hook() {
  local root=$1 hook=$2 when=$3 transaction=$4
  local line section='' hook_when='' exec_line='' needs=0 type='' ops='' targets=''
  local -a triggers=()
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
    '[Trigger]' | '[Action]')
      [[ $section != Trigger ]] || triggers+=("$type|$ops|$targets")
      section=${line//[][]/} type='' ops=' ' targets=''
      ;;
    NeedsTargets) needs=1 ;;
    *' = '*)
      case $section/${line%% = *} in
      Trigger/Type) type=${line#* = } ;;
      Trigger/Operation) ops+="${line#* = } " ;;
      Trigger/Target) targets+="${line#* = } " ;;
      Action/When) hook_when=${line#* = } ;;
      Action/Exec) exec_line=${line#* = } ;;
      esac
      ;;
    esac
  done <"$hook"
  [[ $hook_when == "$when" ]] || return 0

  local op kind target trigger t_type t_ops t_targets pattern
  local -a matched=() patterns=()
  while read -r op kind target; do
    for trigger in "${triggers[@]}"; do
      IFS='|' read -r t_type t_ops t_targets <<<"$trigger"
      [[ $t_type == "$kind" && $t_ops == *" $op "* ]] || continue
      read -ra patterns <<<"$t_targets"
      for pattern in "${patterns[@]}"; do
        # shellcheck disable=SC2053
        if [[ $target == $pattern ]]; then
          matched+=("$target")
          break 2
        fi
      done
    done
  done <"$transaction"
  ((${#matched[@]})) || return 0

  local word
  local -a argv=() command=()
  read -ra argv <<<"$exec_line"
  for word in "${argv[@]}"; do
    if [[ $word == /* && -e $root$word ]]; then command+=("$root$word"); else command+=("$word"); fi
  done
  if ((needs)); then
    printf '%s\n' "${matched[@]}" | LC_ALL=C sort -u | socket_feed "${command[@]}"
  else
    "${command[@]}" <&-
  fi
}

run_transaction() {
  local root=$1 transaction=$2 when name
  local -A hooks=()
  for name in "$root"/usr/share/libalpm/hooks/*.hook "$root"/etc/pacman.d/hooks/*.hook; do
    [[ -e $name ]] && hooks[${name##*/}]=$name
  done
  for when in PreTransaction PostTransaction; do
    while read -r name; do
      run_hook "$root" "${hooks[$name.hook]}" "$when" "$transaction"
    done < <(printf '%s\n' "${!hooks[@]}" | sed 's/\.hook$//' | LC_ALL=C sort)
  done
}

fake_root "$PKG_X86" "$TEST_ROOT/root-x86_64"
fake_root "$PKG_ARM" "$TEST_ROOT/root-aarch64"

transaction() {
  local name=$1
  shift
  printf '%s\n' "$@" >"$TEST_ROOT/tx-$name"
}
transaction kernel \
  'Install Path usr/lib/modules/7.1.0-asahi/vmlinuz' \
  'Install Path usr/lib/modules/7.1.0-asahi/modules.builtin' \
  'Install Path usr/lib/modules/7.1.0-asahi/pkgbase' \
  'Remove Path usr/lib/modules/7.0.0-asahi/vmlinuz' \
  'Remove Path usr/lib/modules/7.0.0-asahi/modules.builtin' \
  'Remove Path usr/lib/modules/7.0.0-asahi/pkgbase' \
  'Upgrade Package linux-asahi'
transaction firmware 'Upgrade Path usr/lib/firmware/brcm/fixture.bin' 'Upgrade Package linux-firmware'
transaction modprobe 'Upgrade Path usr/lib/modprobe.d/' 'Install Path usr/lib/modprobe.d/omarchy-mac.conf' 'Upgrade Package omarchy-mac'
transaction limine 'Upgrade Path usr/share/limine/BOOTAA64.EFI' 'Upgrade Package limine'

replay() {
  local arch=$1 m=$2 name=$3
  export SIM_LOG=$TEST_ROOT/log
  : >"$SIM_LOG"
  local out
  out=$(on "$m" run_transaction "$TEST_ROOT/root-$arch" "$TEST_ROOT/tx-$name" 2>&1) || fail "$name on $arch/$m replays"
  [[ -z $out ]] || fail "$name on $arch/$m prints nothing of the gate's" "$out"
  cat "$SIM_LOG"
}

limine_kernel=$'limine-mkinitcpio-remove pre\n  usr/lib/modules/7.0.0-asahi/modules.builtin\nlimine-mkinitcpio-remove post\nlimine-mkinitcpio-install\n  usr/lib/modules/7.1.0-asahi/modules.builtin'
stock_kernel=$'mkinitcpio install\n  usr/lib/modules/7.1.0-asahi/vmlinuz'
limine_firmware=$'limine-mkinitcpio-install\n  usr/lib/firmware/brcm/fixture.bin'
stock_firmware=$'mkinitcpio install\n  usr/lib/firmware/brcm/fixture.bin'
stock_modprobe=$'mkinitcpio install\n  usr/lib/modprobe.d/'

declare -A want=(
  [kernel/other]=$limine_kernel
  [firmware/other]=$limine_firmware
  [modprobe/other]=''
  [limine/other]='limine-install'
  [kernel/mac-dormant]=$stock_kernel
  [firmware/mac-dormant]=$stock_firmware
  [modprobe/mac-dormant]=$stock_modprobe
  [limine/mac-dormant]=''
  [kernel/mac-active]=$'limine-mkinitcpio-remove pre\n  usr/lib/modules/7.0.0-asahi/modules.builtin\nlimine-mkinitcpio-remove post\n'"$stock_kernel"$'\nlimine-mkinitcpio-install\n  usr/lib/modules/7.1.0-asahi/modules.builtin'
  [firmware/mac-active]=$stock_firmware$'\n'$limine_firmware
  [modprobe/mac-active]=$stock_modprobe
  [limine/mac-active]=''
)
want[kernel/mac-marker-only]=${want[kernel/mac-dormant]}

for name in kernel firmware modprobe limine; do
  got=$(replay x86_64 x86 "$name")
  [[ $got == "${want[$name/other]}" ]] || fail "x86_64: $name transaction runs upstream's hooks" "$got"
  for m in generic-aarch64 qualcomm; do
    got=$(replay aarch64 "$m" "$name")
    [[ $got == "${want[$name/other]}" ]] || fail "aarch64 $m: $name transaction runs as on x86_64" "$got"
  done
done
pass "x86_64, generic aarch64 and Snapdragon transactions run Limine's hooks as upstream ships them"

for m in mac-dormant mac-marker-only mac-active; do
  for name in kernel firmware modprobe limine; do
    [[ -v want[$name/$m] ]] || continue
    got=$(replay aarch64 "$m" "$name")
    [[ $got == "${want[$name/$m]}" ]] || fail "$m: $name transaction" "$got"
  done
done
pass "a dormant Mac defers to mkinitcpio's own hook; an active Mac also writes Limine's entries after it"

# ---------------------------------------------------------------------------
# The wrapper, as sudo mkinitcpio -P and mkinitcpio's hook script call it
# (/usr/local/bin first in PATH, stdin at its end).
wrapper() {
  local root=$1 m=$2
  sed "s|/usr/|$root/usr/|g" "$root/usr/local/bin/mkinitcpio" >"$TEST_ROOT/wrapper"
  export SIM_LOG=$TEST_ROOT/log
  : >"$SIM_LOG"
  on "$m" bash "$TEST_ROOT/wrapper" -P </dev/null >/dev/null 2>&1 || true
  cat "$SIM_LOG"
}
upstream_wrapper=$'mkinitcpio -P\nlimine-mkinitcpio'
[[ $(wrapper "$TEST_ROOT/root-x86_64" x86) == "$upstream_wrapper" ]] || fail "x86_64 keeps upstream's wrapper"
for m in generic-aarch64 qualcomm; do
  [[ $(wrapper "$TEST_ROOT/root-aarch64" "$m") == "$upstream_wrapper" ]] || fail "$m keeps upstream's wrapper"
done
for m in mac-dormant mac-active; do
  [[ $(wrapper "$TEST_ROOT/root-aarch64" "$m") == 'mkinitcpio -P' ]] || fail "$m runs plain mkinitcpio"
done
pass "the mkinitcpio wrapper is upstream's everywhere but a Mac, where it is plain mkinitcpio"
