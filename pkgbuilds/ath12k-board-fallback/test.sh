#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

export ATH12K_BOARD_SYSFS="$scratch/sys"
export ATH12K_BOARD_FIRMWARE="$scratch/fw"
export ATH12K_BOARD_CARDS="$scratch/cards"
export ATH12K_BOARD_STATE="$scratch/state/installed"
tool="$package_dir/ath12k-board-fallback"
qcc="$scratch/fw/ath12k/QCC2072/hw1.0"
copy="$scratch/fw/updates/ath12k/QCC2072/hw1.0/board.bin"

cat >"$ATH12K_BOARD_CARDS" <<'CARDS'
record ncm820a bus=pci,vendor=17cb,device=1112,subsystem-vendor=105b,subsystem-device=e15a,qmi-chip-id=33,qmi-board-id=24
card 17cb:1112 105b:e14f ncm820a
card 17cb:1112 105b:e15a ncm820a
CARDS

# A Wi-Fi card on the PCI bus, by its IDs.
card() {
  local dev="$scratch/sys/0004:01:00.0"
  mkdir -p "$dev"
  printf '0x%s\n' "$1" >"$dev/vendor"
  printf '0x%s\n' "$2" >"$dev/device"
  printf '0x%s\n' "$3" >"$dev/subsystem_vendor"
  printf '0x%s\n' "$4" >"$dev/subsystem_device"
}

# A board-2.bin with one record per name=data argument.
board2() {
  python3 - "$@" <<'PY'
import struct, sys
out = bytearray(b"QCA-ATH12K-BOARD\0" + b"\0" * 3)
def ie(kind, payload):
    return struct.pack("<II", kind, len(payload)) + payload + b"\0" * (-len(payload) % 4)
path, records = sys.argv[1], sys.argv[2:]
for record in records:
    name, data = record.rsplit("=", 1)
    name = "bus=pci," + name
    out += ie(0, ie(0, name.encode()) + ie(1, data.encode()))
open(path, "wb").write(out)
PY
}

e15a="vendor=17cb,device=1112,subsystem-vendor=105b,subsystem-device=e15a,qmi-chip-id=33,qmi-board-id=24"
e14f="vendor=17cb,device=1112,subsystem-vendor=105b,subsystem-device=e14f,qmi-chip-id=33,qmi-board-id=24"
mkdir -p "$qcc"

# A card linux-firmware does not list gets its family's record.
card 17cb 1112 105b e14f
board2 "$qcc/board-2.bin" "$e15a=NCM820A-DATA"
out=$("$tool")
[[ $(<"$copy") == NCM820A-DATA ]] || fail "installs the family's record as board.bin for a card linux-firmware does not list"
[[ $out == *"105b:e14f"* ]] || fail "says which card it installed board data for"
grep -q "^ath12k/QCC2072/hw1.0/board.bin " "$ATH12K_BOARD_STATE" || fail "records the copy it installed"
echo "ok - a card linux-firmware does not list gets its family's record"

[[ -z $("$tool") ]] || fail "a second run changes nothing"
echo "ok - a second run changes nothing"

# A compressed board-2.bin works too.
rm "$copy" "$ATH12K_BOARD_STATE"
zstd -q --rm "$qcc/board-2.bin"
"$tool" >/dev/null
[[ $(<"$copy") == NCM820A-DATA ]] || fail "reads a zstd-compressed board-2.bin"
rm "$qcc/board-2.bin.zst"
board2 "$qcc/board-2.bin" "$e15a=NCM820A-DATA"
echo "ok - reads a compressed board-2.bin"

# A newer record for the family replaces the copy.
board2 "$qcc/board-2.bin" "$e15a=NCM820A-NEWER"
"$tool" >/dev/null
[[ $(<"$copy") == NCM820A-NEWER ]] || fail "follows linux-firmware's record when it changes"
echo "ok - follows linux-firmware's record when it changes"

# Once linux-firmware lists the card, the copy goes.
board2 "$qcc/board-2.bin" "$e15a=NCM820A-NEWER" "$e14f=E14F-DATA"
"$tool" >/dev/null
[[ ! -e $copy ]] || fail "removes its copy once linux-firmware lists the card"
[[ ! -s $ATH12K_BOARD_STATE ]] || fail "forgets the copy it removed"
echo "ok - removes its copy once linux-firmware lists the card"

# A card linux-firmware lists never gets a copy.
card 17cb 1112 105b e15a
board2 "$qcc/board-2.bin" "$e15a=NCM820A-DATA"
"$tool" >/dev/null
[[ ! -e $copy ]] || fail "leaves a card linux-firmware lists alone"
echo "ok - leaves a card linux-firmware lists alone"

# A card of unknown family gets nothing.
card 17cb 1112 1234 5678
out=$("$tool")
[[ ! -e $copy && $out == *"family is not known"* ]] || fail "installs nothing for a card of unknown family, and says so"
echo "ok - installs nothing for a card of unknown family"

# A package's own board.bin wins, and the tool's copy goes.
card 17cb 1112 105b e14f
"$tool" >/dev/null
[[ -e $copy ]] || fail "installs a copy before the package arrives"
printf 'PACKAGE' >"$qcc/board.bin"
"$tool" >/dev/null
[[ ! -e $copy ]] || fail "removes its copy when a package installs board.bin for the chip"
rm "$qcc/board.bin"
echo "ok - steps aside for a package's own board.bin"

# A file it did not install is never touched.
mkdir -p "$(dirname "$copy")"
printf 'SOMEONE-ELSE' >"$copy"
"$tool" >/dev/null
[[ $(<"$copy") == SOMEONE-ELSE ]] || fail "leaves a board.bin it did not install"
board2 "$qcc/board-2.bin" "$e15a=NCM820A-DATA" "$e14f=E14F-DATA"
"$tool" >/dev/null
[[ $(<"$copy") == SOMEONE-ELSE ]] || fail "does not remove a board.bin it did not install"
rm "$copy"
# Not even one that holds the same record.
board2 "$qcc/board-2.bin" "$e15a=NCM820A-DATA"
printf 'NCM820A-DATA' >"$copy"
"$tool" >/dev/null
"$tool" --remove >/dev/null
[[ $(<"$copy") == NCM820A-DATA ]] || fail "does not take over a board.bin it did not install that holds the same record"
rm "$copy"
echo "ok - never touches a board.bin it did not install"

# --check changes nothing, and --remove removes every copy.
board2 "$qcc/board-2.bin" "$e15a=NCM820A-DATA"
"$tool" --check >/dev/null
[[ ! -e $copy ]] || fail "--check changes nothing"
"$tool" >/dev/null
"$tool" --remove >/dev/null
[[ ! -e $copy ]] || fail "--remove removes its copies"
echo "ok - --check changes nothing and --remove removes its copies"

# The card list it ships reads, and names a record for every card.
ATH12K_BOARD_CARDS="$package_dir/cards" ATH12K_BOARD_SYSFS="$scratch/none" "$tool" --check >/dev/null ||
  fail "reads the card list it ships"
echo "ok - reads the card list it ships"
