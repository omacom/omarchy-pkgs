#!/bin/bash

# Installs the FaceTime HD (Broadcom 1570) camera's firmware and sensor calibration files on the Mac it runs on.
# Apple's license forbids redistributing them, so each Mac fetches only the byte ranges it needs from Apple's own download.
# The ranges, offsets and hashes are patjak/facetimehd-firmware's for firmware 5.60.0, which the 12-inch MacBook needs.

set -euo pipefail

dest=${FACETIMEHD_FIRMWARE_DIR:-/usr/lib/firmware/facetimehd}
state=${FACETIMEHD_FETCHER_STATE:-/var/lib/facetimehd-firmware-fetcher}
fetch_lock=${FACETIMEHD_FETCHER_LOCK:-/run/lock/facetimehd-firmware-fetcher.lock}
removing=${FACETIMEHD_FETCHER_REMOVING:-/run/facetimehd-firmware-fetcher.removing}
# Shared with Omarchy's hibernation guard, which marks a hibernating sleep in progress under the lock: loading the driver
# then would put back the driver that hangs hibernation, so activation waits, and the guard starts this service on wake.
# Activation stays pending until the camera works; /run, so a boot, which loads the driver fresh, clears it.
module_run=${FACETIMEHD_MODULE_RUN:-/run/lock}
activate=$module_run/facetimehd-firmware-fetcher.activate
retries=${FACETIMEHD_FETCH_RETRIES:-2}

# Each range is one complete xz stream of the macOS 10.12.6 combo update's pbzx payload, decompressing to a 16 MiB chunk.
url=https://updates.cdn-apple.com/2019/cert/041-90765-20191011-837e856d-b522-4865-b64c-641048ed77c4/macOSUpdCombo10.12.6.dmg

# name range sha256: the AppleCameraInterface driver spans the end of the first chunk and the start of the second.
ranges=(
  "driver-1 699186570-703316225 d9431f0fa8a2b5d2a31037cfe12c4f0abcb0a597739d925a0b8c834ddb6cb647"
  "driver-2 703316242-707986973 562c8b86a69e59ef4cc2eed45ba380b8572908a8232e91c258a45e13f6a2c127"
  "assistant 430282546-439105037 4c9c26a7ce607d749351428aee698e4fd487972392cc7ad06b69e2501dfe215a"
)
driver_tail=249719
driver_head=507353
driver_sha256=e959244db1e0561f6d5590c8e5000a36816c592e2820bafe89af0bea75556aca
firmware_offset=81920
firmware_size=602903
firmware_sha256=240ef2e991f1d089d8228ce11d92b66bfa4b3d7289ec4fee228b64a713024330

# The calibration files are in AppleCameraAssistant, the userspace camera plugin's helper, not in the kext.
assistant_skip=7477241
assistant_size=515632
assistant_sha256=af6a9de00472657e925f546753c818f9e33636030892b14ca96a1b4817ea58c7

# name offset size sha256, offsets into AppleCameraAssistant
calibration=(
  "9112_01XX.dat 217088 33060 4dd756fa8460d8dc3d78d0d76944b2f92275d1fe9c83181bbc8292c81c005f1a"
  "1771_01XX.dat 253952 19040 756c2bb7c5e55b395449e43a0be1cb7c40c37dfc6c2b5abfaffb8ae70ff0fc4b"
  "1871_01XX.dat 274432 19040 bf36fbde0668ab7e44368b584f9fa64b5945b01003d04c6e3c6f22c0be0fd5f3"
  "1874_01XX.dat 294912 19040 ffde89e7819ac16a9eb1c8f0bc6dba0e980b508b2022507679d901c190f7cef8"
  "1222_01XX.dat 315392 20076 04a6aa0d67c0353505a56187c573b27dfdef703dfb4b98329b1ee74f59e4ba7e"
  "8221_01XX.dat 335872 30240 2e041686cf2484345b08b18207266abe725f41f8869e04d427aa092071d9edde"
  "1571_01XX.dat 368640 18652 0f73f550b65121115fe0b999f016fb3be3d109057597863df9fe01fd4678c300"
  "1575_01XX.dat 389120 18652 31068eab65ba25a480fd4d0463e86f8e2807828a2e251a20b6f107499e0f7936"
  "1674_01XX.dat 409600 18044 32377ac603d764f33f1466b5e4a7e3e08780d7becc50ad5b00292e29e2dd0374"
  "1675_01XX.dat 430080 18044 b7a38aef2755721bb28c92d84a15654b17e9fb3b0a0f088a384a981fc8fe16d6"
  "1671_01XX.dat 450560 18044 0b90133936bf0bbcdde4b85df8d3fc18722b58d2f8a1afc2564c6c242b6c57fa"
)

fail() {
  echo "facetimehd-firmware-fetcher: $*" >&2
  exit 1
}

# Apple's files changing is not cured by retrying, so the service stops on this status rather than downloading again.
mismatch() {
  echo "facetimehd-firmware-fetcher: $* (Apple's download has changed; this package needs updating)" >&2
  exit 3
}

matches() {
  [[ -f $1 ]] && sha256sum --status -c <<<"$2  $1"
}

# Byte offsets with full-size reads, rather than one byte at a time.
slice() {
  dd if="$1" bs=64K iflag=skip_bytes,count_bytes skip="$2" count="$3" status=none
}

# For testing on a machine without the camera: 1 treats it as present and working, present as present only.
camera_present() {
  local device
  [[ -n ${FACETIMEHD_FETCH_ANY_HARDWARE:-} ]] && return 0
  for device in /sys/bus/pci/devices/*; do
    [[ $(<"$device/vendor") == 0x14e4 && $(<"$device/device") == 0x1570 ]] && return 0
  done 2>/dev/null
  return 1
}

# A file another package installed, such as the AUR facetimehd-data's calibration, is that package's to manage.
owned_elsewhere() {
  pacman -Qqo "$1" &>/dev/null
}

wanted() {
  local entry name sha
  matches "$dest/firmware.bin" "$firmware_sha256" || owned_elsewhere "$dest/firmware.bin" || echo firmware.bin
  for entry in "${calibration[@]}"; do
    read -r name _ _ sha <<<"$entry"
    matches "$dest/$name" "$sha" || owned_elsewhere "$dest/$name" || echo "$name"
  done
}

# Apple's license allows these files only on Apple hardware, and only this camera needs them.
if ! camera_present; then
  echo "No FaceTime HD camera (PCI 14e4:1570) here; nothing to fetch"
  exit 0
fi

(( EUID == 0 )) || fail "run it as root"

exec 9>>"$fetch_lock"
flock -w 120 9 || fail "another fetch is still running"
[[ ! -e $removing ]] || fail "the package is being removed"
mkdir -p "$state"

sleep_in_progress() {
  local states
  [[ -e $module_run/facetimehd.sleeping ]] || return 1
  # A marker left by a guard that never finished is stale once no hibernating sleep is running, which only an answer
  # from systemd can say: without one, loading could put the driver back before the freeze.
  states=$(systemctl show -p ActiveState --value systemd-hibernate.service systemd-hybrid-sleep.service \
    systemd-suspend-then-hibernate.service) || fail "cannot tell whether the Mac is hibernating; retrying later"
  grep -qxE 'activating|active|deactivating' <<<"$states"
}

# The camera works once its PCI function is bound to facetimehd and has registered a video device; the module loading
# proves neither, since the kernel keeps a module whose device failed to probe.
camera_ready() {
  local device found=
  [[ ${FACETIMEHD_FETCH_ANY_HARDWARE:-} == 1 ]] && return 0
  for device in /sys/bus/pci/devices/*; do
    [[ $(<"$device/vendor") == 0x14e4 && $(<"$device/device") == 0x1570 ]] || continue
    [[ $(readlink "$device/driver") == */facetimehd ]] && compgen -G "$device/video4linux/video*" >/dev/null || return 1
    found=1
  done 2>/dev/null
  [[ -n $found ]]
}

# A probe still finishing gets a moment before it counts as failed.
wait_for_camera() {
  for _ in {1..15}; do
    camera_ready && return 0
    sleep 1
  done
  camera_ready
}

# A driver that probed before the firmware existed stays unbound until it loads again, and one DKMS built after boot
# found the camera never loaded at all. A camera already working is left alone, and anything short of one working
# leaves activation pending for the service's retry.
# Under the lock, so a request the guard renewed after a failed restore is never cleared on an older reading.
acknowledge() {
  exec 8>>"$module_run/facetimehd.lock"
  flock -w 120 8 || fail "the camera driver is busy; retrying later"
  ! sleep_in_progress || fail "the Mac is hibernating; the camera driver loads after it wakes"
  camera_ready || fail "the camera is not up; retrying later"
  rm -f "$activate"
  exec 8>&-
}

activate_driver() {
  if [[ -d /sys/module/facetimehd ]] && wait_for_camera; then
    acknowledge
    return 0
  fi
  exec 8>>"$module_run/facetimehd.lock"
  flock -w 120 8 || fail "the camera driver is busy; retrying later"
  # Failing rather than returning keeps the service's retry, which a start request from the guard's wake step can miss
  # while this run is still going.
  ! sleep_in_progress || fail "the Mac is hibernating; the camera driver loads after it wakes"
  if [[ -d /sys/module/facetimehd ]]; then
    { modprobe -r facetimehd && modprobe facetimehd; } || fail "could not load the camera driver; retrying later"
  else
    modprobe facetimehd || fail "could not load the camera driver; retrying later"
  fi
  # The wait changes nothing, so it does not hold up a sleep's guard behind the lock.
  exec 8>&-
  wait_for_camera || fail "the camera driver loaded but the camera did not come up (see the kernel log); retrying later"
  acknowledge
}

# A camera that is present but not working gets activated too, even with nothing to fetch: a driver DKMS built after
# boot had found the camera never loads on its own. One blacklisted on purpose stays out.
needs_activation() {
  [[ -e $activate ]] && return 0
  modprobe -c 2>/dev/null | grep -x 'blacklist facetimehd' >/dev/null && return 1
  ! camera_ready
}

mapfile -t missing < <(wanted)
if (( ${#missing[@]} == 0 )); then
  echo "FaceTime HD firmware and calibration are installed in $dest"
  if [[ ${1:-} == --reload ]] && needs_activation; then
    activate_driver
  fi
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Each range is a few MB; the size cap stops a server that ignores Range from sending the whole update.
fetch() {
  curl -fsSL --proto =https --proto-redir =https --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
    --max-time 300 --max-filesize 16M --retry "$retries" --retry-delay 5 --retry-all-errors "$@"
}

# A range of the wrong length came from the network, such as a captive portal, and is worth retrying; one of the
# right length that hashes differently is Apple's file changing. Nothing parses a range before it matches.
echo "Fetching the FaceTime HD firmware and calibration from Apple"
for entry in "${ranges[@]}"; do
  read -r name range sha <<<"$entry"
  fetch -r "$range" "$url" -o "$work/$name.xz" || fail "could not download the macOS 10.12.6 update range $range"
  [[ $(stat -c %s "$work/$name.xz") == $(( ${range#*-} - ${range%-*} + 1 )) ]] ||
    fail "the download of range $range was cut short or replaced; retrying later"
  matches "$work/$name.xz" "$sha" || mismatch "the macOS 10.12.6 update range $range is not the one expected"
  xz -dcq "$work/$name.xz" >"$work/$name" || fail "could not decompress range $range"
done

{ tail -c "$driver_tail" "$work/driver-1"; head -c "$driver_head" "$work/driver-2"; } >"$work/AppleCameraInterface"
matches "$work/AppleCameraInterface" "$driver_sha256" || mismatch "AppleCameraInterface is not the driver expected"
slice "$work/AppleCameraInterface" "$firmware_offset" "$firmware_size" | gunzip >"$work/firmware.bin"
matches "$work/firmware.bin" "$firmware_sha256" || mismatch "the extracted firmware is not the one expected"

slice "$work/assistant" "$assistant_skip" "$assistant_size" >"$work/AppleCameraAssistant"
matches "$work/AppleCameraAssistant" "$assistant_sha256" || mismatch "AppleCameraAssistant is not the one expected"
for entry in "${calibration[@]}"; do
  read -r name offset size sha <<<"$entry"
  slice "$work/AppleCameraAssistant" "$offset" "$size" >"$work/$name"
  matches "$work/$name" "$sha" || mismatch "$name is not the calibration expected"
done

# Only what was missing is written, so removal leaves a copy put there by hand. Each is recorded before it is written,
# so a fetch stopped in between leaves nothing unrecorded, and renamed into place, so the kernel never reads half a file.
touch "$activate"
for name in "${missing[@]}"; do
  # A package can install the file while this downloads, and then it is that package's.
  if owned_elsewhere "$dest/$name"; then
    echo "Leaving $name to the package that now installs it"
    continue
  fi
  grep -qxF "$name" "$state/installed-files" 2>/dev/null || echo "$name" >>"$state/installed-files"
  install -Dm644 "$work/$name" "$dest/.$name.new"
  mv -f "$dest/.$name.new" "$dest/$name"
done
echo "FaceTime HD firmware and calibration are installed in $dest"
[[ ${1:-} != --reload ]] || activate_driver
