#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

source "$package_dir/PKGBUILD"
[[ " ${arch[*]} " == " aarch64 " && " ${groups[*]} " == *" omarchy-platform-qualcomm "* ]] ||
  fail "the package is tagged Qualcomm-only for aarch64"

# Bluetooth: the controller gets the firmware address variable minus one.
efivars="$scratch/efivars"
bin="$scratch/bin"
mkdir -p "$efivars" "$bin"
cat >"$bin/btmgmt" <<'STUB'
#!/bin/bash
state="$BTMGMT_STATE"
case "$*" in
  info) [[ -f $state ]] && printf 'hci0:\tPrimary controller\n\taddr %s version 13\n' "$(<"$state")" ;;
  config) printf 'hci0:\tUnconfigured controller\n' ;;
  "--index hci0 public-addr "*) printf '%s\n' "${*: -1}" >"$state" ;;
esac
STUB
chmod +x "$bin/btmgmt"
bluetooth_address() {
  printf '\x07\x00\x00\x00'"$1" >"$efivars/MacAddressEmulationAddress-test"
  rm -f "$scratch/btmgmt.state"
  PATH="$bin:$PATH" BTMGMT_STATE="$scratch/btmgmt.state" SURFACE_BLUETOOTH_EFIVARS="$efivars" \
    bash "$package_dir/surface-bluetooth-address" hci0 >/dev/null
  cat "$scratch/btmgmt.state"
}
[[ $(bluetooth_address '\xc4\xcb\x76\xa1\xab\x85') == "C4:CB:76:A1:AB:84" ]] ||
  fail "the Bluetooth address is the firmware address variable minus one"
[[ $(bluetooth_address '\xc4\xcb\x76\xa1\xac\x00') == "C4:CB:76:A1:AB:FF" ]] ||
  fail "the Bluetooth address borrows across octets"

service="$package_dir/surface-bluetooth-address@.service"
grep -qx 'ConditionFirmware=smbios-field(sys_vendor = "Microsoft Corporation")' "$service" ||
  fail "the Bluetooth address service runs only on Microsoft machines"
grep -qx 'ConditionPathExistsGlob=/sys/firmware/efi/efivars/MacAddressEmulationAddress-\*' "$service" ||
  fail "the Bluetooth address service needs the firmware address variable"
! grep -q 'device-tree-compatible' "$service" ||
  fail "the Bluetooth address service does not depend on a device tree compatible"
grep -q 'DRIVERS=="hci_uart_qca".*SYSTEMD_WANTS}+="surface-bluetooth-address@%k.service"' \
  <(tr -d '\\\n' <"$package_dir/60-surface-bluetooth-address.rules") ||
  fail "each Qualcomm UART Bluetooth controller gets its own address service"

# Wi-Fi: the interface takes the firmware address variable minus two while it
# is still down.
cat >"$bin/ip" <<'STUB'
#!/bin/bash
[[ -z ${IP_FAIL:-} ]] || exit 1
printf '%s\n' "$*" >"$IP_STATE"
STUB
chmod +x "$bin/ip"
netdir="$scratch/net"
mkdir -p "$scratch/dmi-microsoft" "$scratch/dmi-lenovo" "$scratch/dmi-none"
printf 'Microsoft Corporation\n' >"$scratch/dmi-microsoft/sys_vendor"
printf 'LENOVO\n' >"$scratch/dmi-lenovo/sys_vendor"
wifi_address() {
  local override=$1 current=$2 flags=$3 dmi=${4:-$scratch/dmi-microsoft} config=${5:-$scratch/none}
  mkdir -p "$netdir/wlan0"
  printf '%s\n' "$current" >"$netdir/wlan0/address"
  printf '%s\n' "$flags" >"$netdir/wlan0/flags"
  rm -f "$scratch/ip.state"
  env PATH="$bin:$PATH" IP_STATE="$scratch/ip.state" SURFACE_WIFI_EFIVARS="$efivars" \
    SURFACE_WIFI_SYSFS="$netdir" SURFACE_WIFI_DMI="$dmi" SURFACE_WIFI_CONFIG="$config" \
    ${override:+SURFACE_WIFI_ADDRESS="$override"} \
    bash "$package_dir/surface-wifi-address" wlan0 >/dev/null || return
  cat "$scratch/ip.state" 2>/dev/null || :
}
printf '\x07\x00\x00\x00\xc4\xcb\x76\xa1\xab\x85' >"$efivars/MacAddressEmulationAddress-test"
[[ $(wifi_address '' 00:03:7f:12:7f:94 0x1002) == "link set dev wlan0 address C4:CB:76:A1:AB:83" ]] ||
  fail "a down Wi-Fi interface takes the firmware address variable minus two"
[[ -z $(wifi_address '' c4:cb:76:a1:ab:83 0x1002) ]] ||
  fail "an interface that already has the address is left alone"
[[ -z $(wifi_address '' 00:03:7f:12:7f:94 0x1003) ]] ||
  fail "an interface that is already up keeps its connection"
[[ -z $(wifi_address '' 00:03:7f:12:7f:94 0x1002 "$scratch/dmi-lenovo") ]] ||
  fail "other vendors' ath12k machines keep their Wi-Fi address"
[[ -z $(wifi_address '' 00:03:7f:12:7f:94 0x1002 "$scratch/dmi-none") ]] ||
  fail "a machine without DMI data keeps its Wi-Fi address"
[[ $(wifi_address 02:11:22:33:44:55 00:03:7f:12:7f:94 0x1002) == "link set dev wlan0 address 02:11:22:33:44:55" ]] ||
  fail "a configured Wi-Fi address overrides the firmware one"
printf '# local override\nSURFACE_WIFI_ADDRESS="02:aa:bb:cc:dd:ee"\n' >"$scratch/wifi.conf"
[[ $(wifi_address '' 00:03:7f:12:7f:94 0x1002 "" "$scratch/wifi.conf") == "link set dev wlan0 address 02:AA:BB:CC:DD:EE" ]] ||
  fail "the override is read from the configuration file udev cannot pass"
if IP_FAIL=1 wifi_address '' 00:03:7f:12:7f:94 0x1002 2>/dev/null; then
  fail "a failed address change is reported as a failure"
fi
rm "$efivars/MacAddressEmulationAddress-test"
[[ -z $(wifi_address '' 00:03:7f:12:7f:94 0x1002) ]] ||
  fail "a Microsoft machine without the firmware address variable is left alone"
[[ -z $(efivars="$scratch/no-efivars" wifi_address '' 00:03:7f:12:7f:94 0x1002) ]] ||
  fail "a machine without efivarfs is left alone"

grep -q 'ACTION=="add".*DEVTYPE}=="wlan".*DRIVERS=="ath12k_pci|ath12k_wifi7_pci".*RUN+="/usr/lib/surface-snapdragon-addresses/surface-wifi-address $name"' \
  <(tr -d '\\\n' <"$package_dir/81-surface-wifi-address.rules") ||
  fail "udev sets each ath12k Wi-Fi address under its name after renaming, while adding the interface"

echo "ok - surface-snapdragon-addresses derives addresses only on Microsoft machines with the variable"
