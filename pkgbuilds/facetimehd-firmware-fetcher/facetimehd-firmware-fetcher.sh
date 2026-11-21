#!/bin/bash

# Installs the FaceTime HD (Broadcom 1570) camera's firmware and sensor calibration files on the Mac it runs on.
# Apple's license forbids redistributing them, so each Mac fetches only the byte ranges it needs from Apple's own downloads.

set -euo pipefail

dest=${FACETIMEHD_FIRMWARE_DIR:-/usr/lib/firmware/facetimehd}
state=${FACETIMEHD_FETCHER_STATE:-/var/lib/facetimehd-firmware-fetcher}
retries=${FACETIMEHD_FETCH_RETRIES:-2}

# The firmware is gzipped inside the AppleCameraInterface driver of OS X 10.11.5, which this range of the update holds.
firmware_url=https://updates.cdn-apple.com/2019/cert/041-88431-20191011-e7ee7d98-2878-4cd9-bc0a-d98b3a1e24b1/OSXUpd10.11.5.dmg
firmware_range=204909802-207733123
firmware_range_sha256=61b60ba96202f8be0e78ecc25e2ae07528005984e3131ee6b7eaee8c20cd0c69
driver_path=System/Library/Extensions/AppleCameraInterface.kext/Contents/MacOS/AppleCameraInterface
driver_sha256=f56e68a880b65767335071531a1c75f3cfd4958adc6d871adf8dbf3b788e8ee1
firmware_offset=81920
firmware_size=603715
firmware_sha256=e3e6034a67dfdaa27672dd547698bbc5b33f47f1fc7f5572a2fb68ea09d32d3d

# The calibration files sit inside AppleCamera.sys, in the one zip entry of Boot Camp 5.1 that holds AppleCamera64.exe.
data_url=https://download.info.apple.com/Mac_OS_X/031-30890-20150812-ea191174-4130-11e5-a125-930911ba098f/bootcamp5.1.5769.zip
data_entry_offset=2337987
data_entry_length=1154522
data_entry_sha256=73745c1948da9d37121cbd8d38e97daddac445364b8f5edb8b8eb1d6f7ac1c2a
installer_sha256=dcfb6205c54d66bf8a5ad32f5a6b461b3d537c6beb50a4a3d5f8f2e65c9b0e49

# name offset size sha256, offsets into AppleCamera.sys
calibration=(
  "9112_01XX.dat 1663920 33060 4dd756fa8460d8dc3d78d0d76944b2f92275d1fe9c83181bbc8292c81c005f1a"
  "1771_01XX.dat 1644880 19040 756c2bb7c5e55b395449e43a0be1cb7c40c37dfc6c2b5abfaffb8ae70ff0fc4b"
  "1871_01XX.dat 1606800 19040 bf36fbde0668ab7e44368b584f9fa64b5945b01003d04c6e3c6f22c0be0fd5f3"
  "1874_01XX.dat 1625840 19040 ffde89e7819ac16a9eb1c8f0bc6dba0e980b508b2022507679d901c190f7cef8"
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

# A range of the wrong length came from the network, such as a captive portal, and is worth retrying; one of the
# right length that hashes differently is Apple's file changing.
range_matches() {
  [[ $(stat -c %s "$1") == "$2" ]] || fail "the download of ${1##*/} was cut short or replaced; retrying later"
  matches "$1" "$3"
}

matches() {
  [[ -f $1 ]] && sha256sum --status -c <<<"$2  $1"
}

# Byte offsets with full-size reads, where the recipes' bs=1 reads one byte at a time.
slice() {
  dd if="$1" bs=64K iflag=skip_bytes,count_bytes skip="$2" count="$3" status=none
}

camera_present() {
  local device
  [[ -n ${FACETIMEHD_FETCH_ANY_HARDWARE:-} ]] && return 0
  for device in /sys/bus/pci/devices/*; do
    [[ $(<"$device/vendor") == 0x14e4 && $(<"$device/device") == 0x1570 ]] && return 0
  done 2>/dev/null
  return 1
}

wanted() {
  local entry name sha
  matches "$dest/firmware.bin" "$firmware_sha256" || echo firmware.bin
  for entry in "${calibration[@]}"; do
    read -r name _ _ sha <<<"$entry"
    matches "$dest/$name" "$sha" || echo "$name"
  done
}

# Apple's license allows these files only on Apple hardware, and only this camera needs them.
if ! camera_present; then
  echo "No FaceTime HD camera (PCI 14e4:1570) here; nothing to fetch"
  exit 0
fi

(( EUID == 0 )) || fail "run it as root"

mkdir -p "$state"
exec 9>"$state/lock"
flock -w 120 9 || fail "another fetch is still running"

mapfile -t missing < <(wanted)
if (( ${#missing[@]} == 0 )); then
  echo "FaceTime HD firmware and calibration are installed in $dest"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Each range is a few MB; the size cap stops a server that ignores Range from sending a whole download.
fetch() {
  curl -fsSL --proto =https --proto-redir =https --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
    --max-time 300 --max-filesize 16M --retry "$retries" --retry-delay 5 --retry-all-errors "$@"
}

# The range is a truncated xz stream, so cpio complains at the end after writing the one file asked for.
echo "Fetching the FaceTime HD firmware from Apple"
fetch -r "$firmware_range" "$firmware_url" -o "$work/update.part" || fail "could not download the OS X 10.11.5 update range"
# Checked before anything parses it, so only the bytes these pins describe ever reach xz and cpio.
range_matches "$work/update.part" 2823322 "$firmware_range_sha256" || mismatch "the OS X 10.11.5 update range is not the one expected"
(cd "$work" && xzcat -qq -Q update.part | cpio --quiet --format odc -i -d "./$driver_path" 2>/dev/null) || true
matches "$work/$driver_path" "$driver_sha256" || mismatch "AppleCameraInterface is not the driver expected"
slice "$work/$driver_path" "$firmware_offset" "$firmware_size" | gunzip >"$work/firmware.bin"
matches "$work/firmware.bin" "$firmware_sha256" || mismatch "the extracted firmware is not the one expected"

echo "Fetching the FaceTime HD sensor calibration from Apple"
fetch -r "$data_entry_offset-$((data_entry_offset + data_entry_length - 1))" "$data_url" -o "$work/entry.zip" ||
  fail "could not download AppleCamera64.exe from Boot Camp 5.1"
range_matches "$work/entry.zip" "$data_entry_length" "$data_entry_sha256" || mismatch "the Boot Camp 5.1 range is not the one expected"
python3 -I - "$work/entry.zip" "$work/AppleCamera64.exe" <<'PY' || fail "could not unpack AppleCamera64.exe"
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
sig, method, crc, size, name_len, extra_len = struct.unpack("<I4xH4xIIxxxxHH", data[:30])
if sig != 0x04034B50 or method != 8:
    sys.exit("not a deflated zip entry")
start = 30 + name_len + extra_len
out = zlib.decompressobj(-15).decompress(data[start:start + size])
if zlib.crc32(out) != crc:
    sys.exit("CRC mismatch")
open(sys.argv[2], "wb").write(out)
PY
matches "$work/AppleCamera64.exe" "$installer_sha256" || mismatch "AppleCamera64.exe is not the installer expected"
7z x -y -o"$work/installer" "$work/AppleCamera64.exe" >/dev/null || fail "could not unpack AppleCamera.sys"

for entry in "${calibration[@]}"; do
  read -r name offset size sha <<<"$entry"
  slice "$work/installer/AppleCamera.sys" "$offset" "$size" >"$work/$name"
  matches "$work/$name" "$sha" || mismatch "$name is not the calibration expected"
done

# Only what was missing is written and recorded, so removal leaves a copy put there by hand.
for name in "${missing[@]}"; do
  install -Dm644 "$work/$name" "$dest/$name"
  grep -qxF "$name" "$state/installed-files" 2>/dev/null || echo "$name" >>"$state/installed-files"
done
echo "FaceTime HD firmware and calibration are installed in $dest"

# A driver that probed before the firmware existed stays unbound until it loads again.
if [[ ${1:-} == --reload && -d /sys/module/facetimehd ]]; then
  modprobe -r facetimehd && modprobe facetimehd || echo "facetimehd-firmware-fetcher: reboot to load the camera driver" >&2
fi
