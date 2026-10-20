# Shared by prepare() and the configuration-only CI check.
# The caller supplies _make with its toolchain flags.
resolve_kernel_config() {
  local config_dir=$1 output_dir=$2 snapshot=${3:-}
  shift 3
  # Explicit fragments are for baseline diff evidence. Production uses the
  # defaults owned by the pinned kernel, not a package-maintained driver list.
  local fragments=("$@")
  if (( ${#fragments[@]} == 0 )); then
    fragments=(arch/arm64/configs/asahi.config)
  fi
  mkdir -p "$output_dir" || return
  cp "$config_dir/config" "$output_dir/.config" || return
  scripts/kconfig/merge_config.sh -m -O "$output_dir" "$output_dir/.config" \
    "${fragments[@]}" || return
  scripts/config --file "$output_dir/.config" --disable LOCALVERSION_AUTO || return
  if [[ -n $snapshot ]]; then
    cp "$output_dir/.config" "$snapshot" || return
  fi
  _make O="$output_dir" olddefconfig || return
}

configure_kernel() {
  local config_dir=$1 output_dir=$2
  resolve_kernel_config "$config_dir" "$output_dir" "${3:-}" || return
  python3 "$config_dir/validate-config.py" arch/arm64/configs/asahi.config "$output_dir/.config" || return
  grep -qx 'CONFIG_RUST=y' "$output_dir/.config" || {
    echo 'linux-aurora requires Rust drivers; toolchain/configuration disabled CONFIG_RUST' >&2
    return 1
  }
}
