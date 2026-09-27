#!/bin/bash

set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
extractor="$package_dir/surface-pro-11-sensors-extract"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}

store="$scratch/FileRepository"
config="$store/surfacepro_snscfgcrd8380.inf_arm64_f5d7e051fecc22c3"
mkdir -p "$config" "$scratch/soc0"
for file in json.lst 8380_crd_tcs3430_0.json sns_surface_color.json other_sensor.json golden_color_calibration.bin ov08x_2.pb; do
  printf '%s\n' "$file" >"$config/$file"
done
printf 'config line\r\n' >"$config/sns_reg_config"
printf 'CRD\r\n' >"$config/hw_platform"
printf 'Unknown\r\n' >"$config/platform_subtype"
printf '0\r\n' >"$config/platform_subtype_id"
printf '65536\r\n' >"$config/platform_version"
printf '615\r\n' >"$config/soc_id"
printf '3.1\r\n' >"$config/revision"
printf 'x\n' >"$config/surfacepro_SnsCfgCRD8380.inf"
printf '555\n' >"$scratch/soc0/soc_id"
printf '2.1\n' >"$scratch/soc0/revision"
printf 'microsoft,denali-oled\0microsoft,denali\0qcom,x1e80100\0' >"$scratch/compatible"

run() {
  SP11_SENSORS_ROOT="$scratch/root" SP11_SENSORS_SOC="$scratch/soc0" \
    SP11_SENSORS_COMPATIBLE="$scratch/compatible" bash "$extractor" "$@"
}

run -d "$store" >/dev/null 2>&1 || fail "the extractor accepts a driver store"
root="$scratch/root"
[[ -f $root/sensors/config/json.lst && -f $root/sensors/config/other_sensor.json && -f $root/sensors/config/ov08x_2.pb ]] ||
  fail "every sensor configuration file is copied"
[[ ! -e $root/sensors/config/surfacepro_SnsCfgCRD8380.inf && ! -e $root/sensors/config/sns_reg_config ]] ||
  fail "driver metadata stays out of the configuration directory"
[[ $(<"$root/sensors/sns_reg.conf") == "config line" ]] ||
  fail "sns_reg.conf is written without carriage returns"
[[ $(<"$root/socinfo/hw_platform") == CRD && $(<"$root/socinfo/platform_version") == 65536 ]] ||
  fail "platform identifiers come from the Windows configuration"
[[ $(<"$root/socinfo/soc_id") == 555 && $(<"$root/socinfo/revision") == 2.1 ]] ||
  fail "the SoC ID and revision come from the running system, not Windows"
[[ $(od -An -c "$root/socinfo/soc_id" | tr -d ' ') == '555\n' ]] ||
  fail "identifiers are written as single lines, like sysfs"
[[ -d $root/sensors/persist/registry && -f $root/manifest ]] ||
  fail "an empty registry and a manifest are created"

printf 'generated\n' >"$root/sensors/persist/registry/sns_record"
: >"$root/sensors/persist/registry/color_calibration.bin"
run -d "$config" >/dev/null 2>&1 || fail "the extractor accepts the configuration directory itself"
[[ -f $root/sensors/persist/registry/sns_record ]] ||
  fail "the registry the DSP generated survives a rerun"
[[ ! -e $root/sensors/persist/registry/color_calibration.bin ]] ||
  fail "an empty calibration record, which crashes the sensor process, is removed"

rm "$config/sns_surface_color.json"
if run -d "$store" >/dev/null 2>&1; then
  fail "incomplete configuration is rejected"
fi
[[ -f $root/sensors/config/sns_surface_color.json ]] ||
  fail "a rejected run leaves the installed configuration untouched"

printf '%s\n' sns_surface_color.json >"$config/sns_surface_color.json"
mkdir -p "$root.old/stale"
run -d "$store" >/dev/null 2>&1 || fail "a leftover backup from an interrupted run does not block extraction"
[[ ! -e $root.old && ! -e $root/root.old && -f $root/sensors/config/json.lst ]] ||
  fail "a leftover backup is cleared, not nested into the new configuration"

if (( EUID != 0 )); then
  if SP11_SENSORS_SOC="$scratch/soc0" SP11_SENSORS_COMPATIBLE="$scratch/compatible" \
    bash "$extractor" -d "$store" >/dev/null 2>&1; then
    fail "an unprivileged run on the real configuration root stops with an error"
  fi
fi

printf 'microsoft,denali\0qcom,x1p64100\0' >"$scratch/compatible"
rm -rf "$root"
run -d "$store" >/dev/null 2>&1 || fail "other machines exit cleanly"
[[ ! -e $root ]] || fail "other machines get no sensor configuration"

echo "ok - surface-pro-11-sensors-extract builds the sensor root from a Windows driver store"
