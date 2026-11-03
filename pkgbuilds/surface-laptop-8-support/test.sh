#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
extractor="$package_dir/extract-ath12k-board.py"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

# Build a board-2.bin container with two named records, in the ath12k layout.
python - "$scratch/board-2.bin" <<'EOF'
import struct, sys

def ie(kind, payload):
    return struct.pack("<II", kind, len(payload)) + payload + b"\0" * (-len(payload) % 4)

def board(name, data):
    return ie(0, ie(0, name.encode()) + ie(1, data))

content = b"QCA-ATH12K-BOARD\0mmm" + board("bus=pci,other", b"other-board-data") + board("bus=pci,wanted", b"wanted-board-data!")
open(sys.argv[1], "wb").write(content)
EOF

wanted_sha=$(printf 'wanted-board-data!' | sha256sum | cut -d' ' -f1)
python "$extractor" --expected-bytes 18 --expected-sha256 "$wanted_sha" \
  "$scratch/board-2.bin" "bus=pci,wanted" "$scratch/board.bin" ||
  fail "the named board record is extracted"
[[ $(<"$scratch/board.bin") == "wanted-board-data!" ]] ||
  fail "the extracted board record is unmodified"

if python "$extractor" --expected-bytes 18 --expected-sha256 "$(printf x | sha256sum | cut -d' ' -f1)" \
  "$scratch/board-2.bin" "bus=pci,wanted" "$scratch/wrong.bin" 2>/dev/null; then
  fail "a record with an unexpected checksum is rejected"
fi
[[ ! -e $scratch/wrong.bin ]] || fail "a rejected record leaves no output"

if python "$extractor" --expected-bytes 16 --expected-sha256 "$wanted_sha" \
  "$scratch/board-2.bin" "bus=pci,missing" "$scratch/missing.bin" 2>/dev/null; then
  fail "a missing record is rejected"
fi

source "$package_dir/PKGBUILD"
[[ $_board_record == *"subsystem-device=3378,qmi-chip-id=2,qmi-board-id=255" ]] ||
  fail "the package selects the reference board record tested on the laptop"
[[ " ${options[*]} " == *" !strip "* ]] ||
  fail "the ELF board data is packaged without stripping"
[[ " ${arch[*]} " == " aarch64 " && " ${groups[*]} " == *" omarchy-platform-qualcomm "* ]] ||
  fail "the package is tagged Qualcomm-only for aarch64"
grep -q "^_audioreach_commit=b4c1510fe6686ab8053715a02c34bec875ca5c6c$" "$package_dir/PKGBUILD" ||
  fail "the topology builds from pinned AudioReach source"
(( ${#source[@]} == ${#sha256sums[@]} )) || fail "every source has a checksum"

# Audio: the card profile points at the shipped verb, which uses the shipped
# speaker sequences.
grep -q 'File "/Qualcomm/surface-laptop8/HiFi.conf"' "$package_dir/GLYMUR-Microsoft-Surface-Laptop-8.conf" ||
  fail "the card profile points at the shipped HiFi verb"
for name in WSAInit.conf SpeakerSeq.conf; do
  grep -rq "/Qualcomm/surface-laptop8/$name" "$package_dir"/*.conf ||
    fail "the profile includes the shipped $name"
done

# The board list holds what the boot firmware starts and the router image this
# package copies itself, so the extractor still copies the ADSP and CDSP from
# Windows (Omarchy's DSP check looks for the ADSP in --list-missing).
listed=$(sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$package_dir/qcom-firmware-extract-provided.list")
[[ $listed == $'qcom/glymur/microsoft/surface-laptop8/soccp.mbn\nqcom/glymur/microsoft/surface-laptop8/soccp_dtb.mbn\nqcom/glymur/surface-laptop8/usb4-router-legacy.bin' ]] ||
  fail "the extractor's board list names the SOCCP pair and the router image"

# USB4 router image: found by its load records and pinned hash, never by
# position; anything else is left alone.
router="$package_dir/surface-laptop8-usb4-firmware"
python3 -I - "$router" <<'PY' || fail "the router image is found only with its pinned hash"
import hashlib, importlib.machinery, importlib.util, struct, sys
loader = importlib.machinery.SourceFileLoader('router', sys.argv[1])
router = importlib.util.module_from_spec(importlib.util.spec_from_loader('router', loader))
loader.exec_module(router)

def record(address, words):
    return struct.pack('<II', address, len(words)) + b''.join(struct.pack('<I', w) for w in words)

image = record(0, [1, 2, 3]) + record(0x8000, [4, 5])
sha = hashlib.sha256(image).hexdigest()
driver = b'MZ' + b'\xff' * 30 + image + b'\xff' * 12
assert router.find_image(driver, sha, len(image)) == image
# Shifted by four bytes: still found.
assert router.find_image(b'\xff' * 4 + driver, sha, len(image)) == image
# A different image of the same layout is refused.
other = record(0, [1, 2, 9]) + record(0x8000, [4, 5])
assert router.find_image(b'\xff' * 32 + other, sha, len(image)) is None
# Records must fill the image exactly and load from MCU address 0.
assert not router.records_fill(record(4, [1]), 0, 12)
assert not router.records_fill(record(0, [1]) + b'\0' * 4, 0, 16)
assert not router.records_fill(record(0, [1, 2]), 0, 12)
assert not router.records_fill(record(0, [1]) + record(0, [2]), 0, 24)
assert router.records_fill(image, 0, len(image))
assert router.FIRMWARE == 'qcom/glymur/surface-laptop8/usb4-router-legacy.bin'
PY
mkdir -p "$scratch/store/qcusb4filter8480.inf_arm64_test" "$scratch/root"
head -c 65536 /dev/zero >"$scratch/store/qcusb4filter8480.inf_arm64_test/QcUsb4Filter8480.sys"
status=0
SURFACE_LAPTOP8_ROOT="$scratch/root" python3 -I "$router" --no-rebuild -d "$scratch/store" 2>/dev/null || status=$?
(( status == 2 )) || fail "a driver without the tested image leaves USB4 off (exit 2, got $status)"
[[ ! -e $scratch/root/usr/lib/firmware/updates/qcom/glymur/surface-laptop8/usb4-router-legacy.bin ]] ||
  fail "nothing is installed without the tested image"
status=0
SURFACE_LAPTOP8_ROOT="$scratch/root" python3 -I "$router" --no-rebuild -d "$scratch/root" 2>/dev/null || status=$?
(( status == 2 )) || fail "no driver found exits 2 (got $status)"

# A driver holding the tested image (a stand-in with its hash pinned here):
# installed 0644 under firmware/updates, and a second run leaves it alone.
python3 -I - "$router" "$scratch/install" <<'PY' || fail "the tested image is installed once, readable, under firmware/updates"
import contextlib, hashlib, importlib.machinery, importlib.util, io, os, struct, sys
loader = importlib.machinery.SourceFileLoader('router', sys.argv[1])
router = importlib.util.module_from_spec(importlib.util.spec_from_loader('router', loader))
loader.exec_module(router)
root = sys.argv[2]
image = struct.pack('<II', 0, 2) + struct.pack('<II', 7, 8)
router.IMAGE_SHA256 = hashlib.sha256(image).hexdigest()
router.find_image.__defaults__ = (router.IMAGE_SHA256, len(image))
store = os.path.join(root, 'store', 'qcusb4filter8480.inf_arm64_test')
os.makedirs(store)
with open(os.path.join(store, 'QcUsb4Filter8480.sys'), 'wb') as driver:
    driver.write(b'MZ' + b'\xff' * 6 + image + b'\xff' * 8)
os.environ['SURFACE_LAPTOP8_ROOT'] = root
os.umask(0o077)
with contextlib.redirect_stderr(io.StringIO()):
    assert router.main(['--no-rebuild', '-d', os.path.join(root, 'store')]) == 0
target = os.path.join(root, 'usr/lib/firmware/updates', router.FIRMWARE)
assert open(target, 'rb').read() == image
assert os.stat(target).st_mode & 0o777 == 0o644
assert not os.path.exists(target + '.new')
log = io.StringIO()
with contextlib.redirect_stderr(log):
    assert router.main(['--no-rebuild', '-d', os.path.join(root, 'empty')]) == 0
assert 'already installed' in log.getvalue()
PY

# Partition discovery, with stand-ins for lsblk, mount, umount and the boot
# image rebuild: only internal NTFS partitions are mounted, read-only, and an
# internal BitLocker volume is named so it can be unlocked; every
# mount point is unmounted and removed, also when the image is not found; and
# a failed rebuild is an error that a rerun recovers from.
mkdir -p "$scratch/stubs"
cat >"$scratch/stubs/lsblk" <<'SH'
#!/bin/bash
printf '%s\n' '/dev/nvme0n1 0 0  nvme' '/dev/nvme0n1p3 0 0 ntfs ' '/dev/nvme0n1p4 0 0 ntfs ' \
  '/dev/nvme0n1p5 0 0 vfat ' '/dev/nvme0n1p6 0 0 BitLocker ' '/dev/sda1 1 1 ntfs ' '/dev/sdb1 0 1 ntfs ' \
  '/dev/sdc1 0 0 ntfs usb'
SH
cat >"$scratch/stubs/mount" <<'SH'
#!/bin/bash
printf 'mount %s\n' "$*" >>"$STUB_LOG"
[[ $5 == /dev/nvme0n1p3 ]] || exit 32
store="$6/Windows/System32/DriverStore/FileRepository/qcusb4filter8480.inf_arm64_test"
mkdir -p "$store" && cp "$STUB_DRIVER" "$store/QcUsb4Filter8480.sys"
SH
cat >"$scratch/stubs/umount" <<'SH'
#!/bin/bash
printf 'umount %s\n' "$1" >>"$STUB_LOG"
rm -rf "${1:?}"/*
SH
cat >"$scratch/stubs/limine-update" <<'SH'
#!/bin/bash
printf 'rebuild\n' >>"$STUB_LOG"
[[ ! -e $STUB_REBUILD_FAILS ]]
SH
chmod +x "$scratch/stubs"/*
python3 -I - "$router" "$scratch/discover" "$scratch/stubs" <<'PY' || fail "only internal NTFS is mounted, read-only, and always cleaned up; a failed rebuild is an error a rerun recovers from"
import contextlib, hashlib, importlib.machinery, importlib.util, io, os, struct, sys
loader = importlib.machinery.SourceFileLoader('router', sys.argv[1])
router = importlib.util.module_from_spec(importlib.util.spec_from_loader('router', loader))
loader.exec_module(router)
work, stubs = sys.argv[2], sys.argv[3]
image = struct.pack('<II', 0, 2) + struct.pack('<II', 7, 8)
router.IMAGE_SHA256 = hashlib.sha256(image).hexdigest()
router.find_image.__defaults__ = (router.IMAGE_SHA256, len(image))
os.environ['PATH'] = stubs + os.pathsep + os.environ['PATH']
log_path = os.path.join(work, 'log')
os.environ['STUB_LOG'] = log_path
os.environ['STUB_REBUILD_FAILS'] = os.path.join(work, 'rebuild-fails')

def run(name, driver, *args):
    root = os.path.join(work, name)
    os.makedirs(os.path.join(root, 'run'))
    with open(os.path.join(work, 'driver'), 'wb') as out:
        out.write(driver)
    os.environ['STUB_DRIVER'] = os.path.join(work, 'driver')
    os.environ['SURFACE_LAPTOP8_ROOT'] = root
    open(log_path, 'w').close()
    messages = io.StringIO()
    with contextlib.redirect_stderr(messages):
        status = router.main(list(args))
    assert 'BitLocker volume(s) skipped: /dev/nvme0n1p6; turn BitLocker off' in messages.getvalue()
    return root, status, open(log_path).read().splitlines()

def check_mounts(root, log):
    mounts = [line.split() for line in log if line.startswith('mount ')]
    assert [m[5] for m in mounts] == ['/dev/nvme0n1p3', '/dev/nvme0n1p4'], mounts
    assert all(m[1:5] == ['-t', 'ntfs3', '-o', 'ro,nosuid,nodev,noexec'] for m in mounts), mounts
    assert [line.split()[1] for line in log if line.startswith('umount ')] == [mounts[0][6]], log
    assert os.listdir(os.path.join(root, 'run')) == [], os.listdir(os.path.join(root, 'run'))

# No tested image on the partition: nothing installed, still cleaned up.
root, status, log = run('none', b'\xff' * 64, '--no-rebuild')
assert status == 2, status
check_mounts(root, log)
assert not os.path.exists(os.path.join(root, 'usr'))

# The tested image: installed, then a failed rebuild is an error.
open(os.environ['STUB_REBUILD_FAILS'], 'w').close()
root, status, log = run('found', b'MZ' + b'\xff' * 6 + image)
assert status == 1, status
check_mounts(root, log)
assert log[-1] == 'rebuild', log
assert open(os.path.join(root, 'usr/lib/firmware/updates', router.FIRMWARE), 'rb').read() == image

# Rerun once the rebuild works: no mounting, just the rebuild.
os.remove(os.environ['STUB_REBUILD_FAILS'])
open(log_path, 'w').close()
with contextlib.redirect_stderr(io.StringIO()):
    status = router.main([])
assert status == 0, status
assert open(log_path).read().splitlines() == ['rebuild']
PY

# Device tree and touchpad: only this model.
python - "$package_dir/glymur-microsoft-surface-laptop8.json" <<'PY' || fail "the hardware-ID file maps to the Surface Laptop 8 device tree"
import json, sys
data = json.load(open(sys.argv[1]))
assert data["type"] == "devicetree" and data["compatible"] == "microsoft,surface-laptop8", data
assert data["hwids"], data
PY
grep -q '^MatchDMIModalias=dmi:\*svnMicrosoftCorporation:pnSurfaceLaptop13.8in8thEdSnapdragon:\*$' \
  "$package_dir/99-surface-laptop8.quirks" || fail "the touchpad quirk matches only this model"
grep -q '^MemorySleepMode=s2idle$' "$package_dir/60-surface-laptop8-sleep.conf" || fail "sleep uses s2idle"

echo "ok - surface-laptop-8-support"
