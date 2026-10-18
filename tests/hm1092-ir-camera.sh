#!/bin/bash
# hm1092-ir-camera's relay, LED helper, udev rule, units and dkms configs agree
# with each other, exercised without the camera: the relay and the LED helper
# run against a fixture sysfs and /dev and a stubbed media-ctl. The relay's
# unit tests run in the package's check().
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
PKG="$ROOT/pkgbuilds/hm1092-ir-camera"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; [[ -z ${2:-} ]] || printf '%s\n' "$2"; exit 1; }

python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$PKG/hm1092-relay" ||
  fail "the relay is valid Python"
pass "the relay is valid Python"

# --probe needs nothing beyond what sysfs and media-ctl say.
mkdir -p "$T/bin" "$T/dev" "$T/sys/class/leds/HIMX1092_00::ir_flood_led" "$T/sys/class/video4linux/video51"
echo "HM1092 IR Camera" >"$T/sys/class/video4linux/video51/name"
: >"$T/dev/media0"
cat >"$T/bin/media-ctl" <<'SH'
#!/bin/bash
[[ $1 == -d && $3 == -p ]] || exit 1
cat <<'TOPO'
Device topology
- entity 4: Intel IPU7 CSI2 2 (2 pads, 5 links, 0 routes)
            device node name /dev/v4l-subdev1
	pad1: Source
		-> "Intel IPU7 ISYS Capture 8":0 []

- entity 43: hm1092 17-0024 (1 pad, 1 link, 0 routes)
            device node name /dev/v4l-subdev8
	pad0: Source
		-> "Intel IPU7 CSI2 2":0 [ENABLED,IMMUTABLE]

- entity 50: Intel IPU7 ISYS Capture 8 (1 pad, 1 link)
            device node name /dev/video8
TOPO
SH
chmod +x "$T/bin/media-ctl"
probe() {
  HM1092_SYS_ROOT="$T/sys" HM1092_DEV_ROOT="$T/dev" PATH="$T/bin:$PATH" python3 -I "$PKG/hm1092-relay" --probe >"$T/probe" 2>&1
}
probe || fail "--probe succeeds on a complete graph" "$(<"$T/probe")"
grep -q 'capture      : Intel IPU7 ISYS Capture 8  (/dev/video8)' "$T/probe" ||
  fail "--probe names the capture node behind the sensor" "$(<"$T/probe")"
grep -q "loopback     : $T/dev/video51" "$T/probe" || fail "--probe finds the loopback by name" "$(<"$T/probe")"
pass "--probe resolves the graph, the loopback and the LED through the test seams"

rmdir "$T/sys/class/leds/HIMX1092_00::ir_flood_led"
probe && fail "--probe fails without the flood LED"
grep -q 'flood led    : none' "$T/probe" || fail "--probe reports the missing LED" "$(<"$T/probe")"
pass "--probe fails without the flood LED"

led="$T/sys/class/leds/HIMX1092_00::ir_flood_led"
mkdir -p "$led"
echo 0 >"$led/brightness"
HM1092_SYS_ROOT="$T/sys" bash "$PKG/hm1092-ir-led" on || fail "hm1092-ir-led on succeeds"
[[ $(<"$led/brightness") == 1 ]] || fail "hm1092-ir-led on writes 1"
HM1092_SYS_ROOT="$T/sys" bash "$PKG/hm1092-ir-led" off || fail "hm1092-ir-led off succeeds"
[[ $(<"$led/brightness") == 0 ]] || fail "hm1092-ir-led off writes 0"
HM1092_SYS_ROOT="$T/nowhere" bash "$PKG/hm1092-ir-led" off || fail "hm1092-ir-led off is a no-op without a LED"
HM1092_SYS_ROOT="$T/nowhere" bash "$PKG/hm1092-ir-led" on 2>/dev/null && fail "hm1092-ir-led on fails without a LED"
status=0
bash "$PKG/hm1092-ir-led" blink 2>/dev/null || status=$?
(( status == 2 )) || fail "hm1092-ir-led rejects an unknown verb with usage" "exit $status"
pass "hm1092-ir-led drives the flood LED and never fails on off"

# The device name is spelled in the conf, the udev rule and the WirePlumber rule.
label=$(sed -n 's/^CARD_LABEL="\(.*\)"$/\1/p' "$PKG/hm1092-ir-camera.conf")
[[ -n $label ]] || fail "the conf names the device"
rule=$(grep -F "ATTR{name}==\"$label\"" "$PKG/72-hm1092-ir-camera.rules") || fail "the udev rule uses the conf's device name"
(( $(grep -cF "\"$label\"" "$PKG/hide-hm1092-ir-camera.conf") == 2 )) || fail "the WirePlumber rule hides the conf's device name"
pass "the device name agrees across the conf, udev and WirePlumber"

# Only root reads the relay device: Howdy runs as root, and a session process
# that could open it could watch the IR camera or, while the relay restarts,
# take the producer side and feed it frames. 70-uaccess tags every
# video4linux node for the seat user and 73-seat-late turns that tag into an
# ACL, so the rule must sit between them.
for part in 'TAG-="uaccess"' 'TAG-="seat"' 'MODE="0600"' 'GROUP="root"' 'SYMLINK+="video-hm1092-ir"'; do
  grep -qF "$part" <<<"$rule" || fail "the relay device rule carries $part" "$rule"
done
[[ $(grep -o '[0-9]*-hm1092-ir-camera.rules' "$PKG/PKGBUILD" | sort -u) =~ ^7[12]-hm1092-ir-camera.rules$ ]] ||
  fail "the rule is installed between 70-uaccess and 73-seat-late"
for hook in post_install post_upgrade; do
  sed -n "/^$hook() {/,/^}/p" "$PKG/hm1092-ir-camera.install" |
    grep -qF "udevadm trigger --action=change --subsystem-match=video4linux --attr-match=name=\"$label\"" ||
    fail "$hook applies the rule to a relay device that already exists"
done
pass "the relay device is root's alone, also right after an install or upgrade"

# Howdy reads the device through OpenCV, which hands a path to FFmpeg first;
# FFmpeg takes a path for a camera only when it starts with /dev/video.
[[ $(sed -n 's/.*SYMLINK+="\([^"]*\)".*/\1/p' <<<"$rule") == video* ]] ||
  fail "the stable link starts with video, so FFmpeg reads it as a camera"
pass "the stable link is named for FFmpeg's camera probe"

while read -r exe; do
  [[ -f $PKG/${exe##*/} ]] || fail "a unit references $exe, which the package does not ship"
done < <(grep -ho '/usr/lib/hm1092-ir-camera/[a-z0-9-]*' "$PKG"/*.service "$PKG/hm1092-ir-led-sleep" | sort -u)
grep -q '^EnvironmentFile=/etc/hm1092-ir-camera.conf$' "$PKG/hm1092-relay.service" || fail "the relay unit reads the shipped conf"
grep -q '^ConditionPathExistsGlob=/sys/bus/acpi/devices/HIMX1092:\*$' "$PKG/hm1092-relay.service" ||
  fail "the relay unit is conditional on the sensor"
# Units ordered after the relay should find the loopback in place, so systemd
# waits for the relay's READY=1, sent once the device is primed.
grep -q '^Type=notify$' "$PKG/hm1092-relay.service" || fail "the relay unit waits for the relay's readiness"
grep -qF 'sd_notify("READY=1")' "$PKG/hm1092-relay" || fail "the relay reports readiness"
pass "the units agree with the shipped files"

# The README's support matrix quotes the shipped limits; a change to the conf or
# the fix pack release has to reach it too.
readme="$PKG/README.md"
conf_value() { sed -n "s/^$1=//p" "$PKG/hm1092-ir-camera.conf"; }
burst_s=$(awk -v ms="$(conf_value MAX_ILLUMINATION_MS)" 'BEGIN { print ms / 1000 }')
duty_pct=$(awk -v f="$(conf_value DUTY_FRACTION)" 'BEGIN { print f * 100 }')
grep -qF "at most $burst_s s (\`MAX_ILLUMINATION_MS\`)" "$readme" || fail "the README quotes the burst cap of $burst_s s"
grep -qF "at most $duty_pct % (\`DUTY_FRACTION\`)" "$readme" || fail "the README quotes the duty fraction of $duty_pct %"
grep -qF "$(conf_value DUTY_WINDOW_S) s window (\`DUTY_WINDOW_S\`)" "$readme" || fail "the README quotes the duty window"
grep -qF "$(conf_value WIDTH)×$(conf_value HEIGHT) at 30 fps is the only mode" "$readme" || fail "the README quotes the sensor mode"
grep -qF "release $(sed -n 's/^_fixpack_ver=//p' "$PKG/PKGBUILD") of" "$readme" || fail "the README names the packaged fix pack release"
grep -q 'README\.md.*/usr/share/doc/\$pkgname/' "$PKG/PKGBUILD" || fail "the package installs the README"
pass "the README's support matrix matches the shipped limits and is installed"

# ipu-bridge must list the sensor, or it never binds. Mainline does from 7.3 and
# Omarchy's kernels patch it in before that, so the package relies on them and
# never displaces their ipu-bridge, which carries other machines' fixes too.
kernels=0
for kernel in "$ROOT"/pkgbuilds/linux-omarchy-{bore,eevdf,muqss}; do
  [[ -f $kernel/PKGBUILD ]] || continue
  kernels=$((kernels + 1))
  version=$(sed -n 's/^pkgver=//p' "$kernel/PKGBUILD")
  [[ $(printf '%s\n' 7.3 "$version" | sort -V | head -n1) == 7.3 ]] && continue
  grep -qF 'IPU_SENSOR_CONFIG("HIMX1092", 2, 180000000, 180480000)' "$kernel"/*.patch ||
    fail "${kernel##*/} $version lists the HM1092 in ipu-bridge"
done
(( kernels > 0 )) || fail "the repository has Omarchy kernels to check"
if grep -l '^BUILT_MODULE_NAME\[[0-9]*\]="ipu-bridge"' "$PKG"/*.dkms.conf; then
  fail "the package leaves ipu-bridge to the kernel"
fi
pass "the package relies on the kernel's ipu-bridge entry and never replaces the module"

# linux-omarchy-headers is a meta package that owns no files since 7.2.8, so
# check() finds the build tree it pulls in by path, as xpadneo-dkms does.
if grep -nF 'pacman -Qql linux-omarchy-headers' "$PKG/PKGBUILD"; then
  fail "check() finds the kernel build tree without listing linux-omarchy-headers' files"
fi
pass "check() finds the kernel build tree on a split kernel"
