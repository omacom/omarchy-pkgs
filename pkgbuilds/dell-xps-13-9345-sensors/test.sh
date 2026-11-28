#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
extractor="$package_dir/dell-xps-13-9345-sensors-extract"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

windows="$scratch/volume"
config="$windows/Windows/System32/DriverStore/FileRepository/qcsensorsconfigcrd8380.inf_arm64_0123456789abcdef"
registry="$windows/Windows/System32/drivers/DriverData/QUALCOMM/fastRPC/persist/sensors/registry"
mkdir -p "$config" "$registry/registry" "$scratch/soc0"
for file in json.lst 8380_tcs3530_0.json other_sensor.json ov02e_2.pb driver.inf; do
  printf '%s\n' "$file" >"$config/$file"
done
printf 'config line\r\n' >"$config/sns_reg_config"
printf 'CRD\r\n' >"$config/hw_platform"
printf 'Unknown\r\n' >"$config/platform_subtype"
printf '0\r\n' >"$config/platform_subtype_id"
printf '65536\r\n' >"$config/platform_version"
printf '3.1\r\n' >"$config/revision"
printf 'version=1\n' >"$registry/sns_reg_version"
printf 'parsed\n' >"$registry/registry/record"
ln -s /etc/passwd "$registry/registry/link"
printf '555\n' >"$scratch/soc0/soc_id"
printf '2.1\n' >"$scratch/soc0/revision"
printf 'dell,xps13-9345\0qcom,x1e80100\0' >"$scratch/compatible"
root="$scratch/root"

run() {
  XPS9345_SENSORS_ROOT="$root" XPS9345_SENSORS_SOC="$scratch/soc0" \
    XPS9345_SENSORS_COMPATIBLE="$scratch/compatible" bash "$extractor" "$@"
}

run -d "$windows" >/dev/null 2>&1 || fail "the extractor accepts a Windows volume"
[[ -f $root/sensors/config/other_sensor.json && -f $root/sensors/config/ov02e_2.pb ]] ||
  fail "every sensor configuration file is copied"
[[ ! -e $root/sensors/config/driver.inf && ! -e $root/sensors/config/sns_reg_config ]] ||
  fail "driver metadata stays out of the configuration directory"
[[ $(<"$root/sensors/sns_reg.conf") == "config line" ]] ||
  fail "sns_reg.conf is written without carriage returns"
[[ $(<"$root/socinfo/hw_platform") == "CRD" ]] ||
  fail "platform identifiers come from Windows"
[[ $(<"$root/socinfo/soc_id") == "555" && $(<"$root/socinfo/revision") == "2.1" ]] ||
  fail "the SoC ID and revision come from the running system"
[[ -f $root/windows-registry/sns_reg_version && -f $root/windows-registry/registry/record ]] ||
  fail "the registry Windows parsed is kept as a pristine copy"
[[ ! -e $root/windows-registry/registry/link ]] ||
  fail "links on the Windows volume are not followed"

printf 'generated\n' >"$root/sensors/persist/registry/generated"
rm -r "$registry"
run -d "$windows" >/dev/null 2>&1 || fail "a rerun without a Windows registry succeeds"
[[ -f $root/sensors/persist/registry/generated ]] || fail "the DSP's registry survives a rerun"
[[ -f $root/windows-registry/registry/record ]] || fail "an earlier pristine registry survives a rerun"

rm -r "$root"
run -d "$windows" >/dev/null 2>&1 || fail "extraction works when Windows saved no registry"
[[ ! -e $root/windows-registry ]] || fail "no pristine registry is invented"

saved="$scratch/saved"
mkdir -p "$saved/registry/registry"
cp -r "$config" "$saved/config"
printf 'saved\n' >"$saved/registry/registry/record"
run -d "$saved" >/dev/null 2>&1 || fail "the extractor accepts a saved copy"
[[ $(<"$root/windows-registry/registry/record") == "saved" ]] || fail "a saved registry is used"

rm "$config/8380_tcs3530_0.json"
if run -d "$windows" >/dev/null 2>&1; then
  fail "incomplete configuration is rejected"
fi
[[ -f $root/sensors/config/8380_tcs3530_0.json ]] ||
  fail "a rejected run leaves the installed configuration untouched"

printf 'microsoft,denali\0qcom,x1e80100\0' >"$scratch/compatible"
rm -r "$root"
run -d "$saved" >/dev/null 2>&1 || fail "other machines exit cleanly"
[[ ! -e $root ]] || fail "other machines get no sensor configuration"

echo "ok - dell-xps-13-9345-sensors-extract builds the sensor root from Windows"
