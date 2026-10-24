#!/bin/bash
# omarchy-settings.install: an upgrade restores Omarchy's plymouthd.conf but
# keeps an unlock screen chosen in Style > Unlock, which Omarchy publishes as
# the unowned omarchy-custom theme (omacom/omarchy#16473).
set -euo pipefail

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "not ok - $1" >&2
  exit 1
}
pass() {
  echo "ok - $1"
}

# Omarchy's shipped file, with a setting beyond Theme= so the test can tell a
# restored file from a kept one.
shipped=$'[Daemon]\nTheme=omarchy\nShowDelay=0'

# Run the recipe's real _etc_overrides_apply against a fresh fake root that
# starts with the given live Theme=, and print the plymouthd.conf it leaves.
apply() {
  local recipe=$1 live_theme=$2 custom_installed=$3 root

  root=$(mktemp -d "$TEST_ROOT/root.XXXXXXXX")
  mkdir -p "$root/etc/plymouth" "$root/usr/share/omarchy/etc-overrides" "$root/usr/share/plymouth/themes"
  printf '%s\n' "$shipped" >"$root/usr/share/omarchy/etc-overrides/plymouth-plymouthd.conf"
  for override in os-release security-faillock.conf nsswitch.conf dot.bashrc; do
    printf 'shipped %s\n' "$override" >"$root/usr/share/omarchy/etc-overrides/$override"
  done
  printf '[Daemon]\nTheme=%s\nShowDelay=5\n' "$live_theme" >"$root/etc/plymouth/plymouthd.conf"
  if [[ $custom_installed == "yes" ]]; then
    mkdir -p "$root/usr/share/plymouth/themes/omarchy-custom"
    printf '[Plymouth Theme]\n' >"$root/usr/share/plymouth/themes/omarchy-custom/omarchy-custom.plymouth"
  fi

  (
    # shellcheck source=/dev/null
    source "$REPO_ROOT/pkgbuilds/$recipe/$recipe.install"

    # The scriptlet writes fixed system paths; move every one into the fake root.
    ROOT=$root
    eval "$(declare -f _etc_overrides_apply | sed -e 's|/etc/|${ROOT}/etc/|g' -e 's|/usr/share/|${ROOT}/usr/share/|g')"
    if declare -f _etc_overrides_apply | grep -E '(^|[^}])/(etc|usr/share)/' >&2; then
      fail "$recipe: a system path in _etc_overrides_apply escaped the fake root"
    fi

    _apple_silicon() { false; }
    systemd-sysusers() { :; }
    _etc_overrides_apply >/dev/null
  )
  cat "$root/etc/plymouth/plymouthd.conf"
}

expect() {
  local recipe=$1 live_theme=$2 custom_installed=$3 expected=$4 description=$5 got

  got=$(apply "$recipe" "$live_theme" "$custom_installed")
  [[ $got == "$expected" ]] || fail "$recipe: $description"$'\n'"$got"
  pass "$recipe: $description"
}

for recipe in omarchy-settings omarchy-settings-dev; do
  expect "$recipe" omarchy-custom yes "${shipped/Theme=omarchy/Theme=omarchy-custom}" \
    "an installed omarchy-custom theme stays selected while the rest of plymouthd.conf is restored"
  expect "$recipe" omarchy-custom no "$shipped" \
    "a selected omarchy-custom theme that is no longer installed falls back to omarchy"
  expect "$recipe" omarchy no "$shipped" \
    "the default theme is restored as before"
  expect "$recipe" omarchy yes "$shipped" \
    "a leftover omarchy-custom theme does not select itself"
  expect "$recipe" spinner no "$shipped" \
    "any other theme is reset to omarchy as before"
done
