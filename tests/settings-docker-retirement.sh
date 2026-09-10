#!/bin/bash
# Real pacman transactions in a disposable Arch container; never run on a host.
set -euo pipefail
[[ -e /run/.containerenv || -e /.dockerenv ]] || { echo 'Requires a disposable container' >&2; exit 1; }
(( EUID == 0 )) || exit 1
for package in docker podman-docker omarchy-settings omarchy-settings-dev; do
  if pacman -Q "$package" >/dev/null 2>&1; then
    echo "Fixture requires an empty package baseline: $package" >&2
    exit 1
  fi
done
# Match the settings recipe's runtime dependency, including a minimal image.
if ! pacman -Q diffutils >/dev/null 2>&1; then
  pacman -Sy --noconfirm diffutils
fi
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
paths=(etc/docker/daemon.json etc/systemd/resolved.conf.d/20-docker-dns.conf etc/systemd/system/docker.service.d/no-block-boot.conf)

package_fixture() {
  local name=$1 version=$2 podman_source=${3:-false} stage="$work/$1-$2" path
  mkdir -p "$stage"
  cat >"$stage/.PKGINFO" <<EOF
pkgname = $name
pkgver = $version-1
pkgdesc = Disposable settings retirement fixture
arch = any
EOF
  case "$name" in
    podman-docker)
      printf 'provides = docker\nconflict = docker\n' >>"$stage/.PKGINFO" ;;
    omarchy-settings|omarchy-settings-dev)
      printf 'depend = diffutils\n' >>"$stage/.PKGINFO"
      if [[ $name == omarchy-settings-dev ]]; then
        printf 'provides = omarchy-settings\nconflict = omarchy-settings\n' >>"$stage/.PKGINFO"
      fi
      for path in "${paths[@]}"; do
        mkdir -p "$stage/$(dirname "$path")"
        printf 'stock %s\n' "$path" >"$stage/$path"
        printf 'backup = %s\n' "$path" >>"$stage/.PKGINFO"
        if [[ $podman_source == true ]]; then
          install -Dm644 "$stage/$path" "$stage/usr/share/omarchy/retired-docker/$path"
        fi
      done
      if [[ $podman_source == true ]]; then
        install -Dm755 /dev/null "$stage/usr/lib/systemd/user-environment-generators/60-omarchy-podman"
      fi
      cp "$ROOT/pkgbuilds/$name/$name.install" "$stage/.INSTALL"
      # Exercise the actual entry points and retirement function. The unrelated
      # os-release/CUPS/skel defaults have no payload in these small fixtures.
      printf '\n_etc_overrides_apply() { :; }\n' >>"$stage/.INSTALL"
      ;;
  esac
  local entries=(.PKGINFO)
  [[ ! -f $stage/.INSTALL ]] || entries+=(.INSTALL)
  for path in "$stage"/*; do
    [[ ! -e $path ]] || entries+=("${path##*/}")
  done
  bsdtar --zstd -cf "$work/$name-$version.pkg.tar.zst" -C "$stage" "${entries[@]}"
}
install_fixture() {
  pacman -U --noconfirm --ask 4 "$work/$1-$2.pkg.tar.zst"
}
assert_pending() {
  [[ $(cat /etc/docker/daemon.json) == 'custom Docker settings' ]]
  [[ $(stat -c %a /etc/docker/daemon.json) == 600 ]]
  for path in "${paths[@]:1}"; do
    [[ $(cat "/$path") == "stock $path" ]]
  done
}
assert_retired() {
  for path in "${paths[@]}"; do [[ ! -e /$path ]]; done
  [[ $(cat /etc/docker/daemon.json.before-podman) == 'custom Docker settings' ]]
  [[ $(stat -c %a /etc/docker/daemon.json.before-podman) == 600 ]]
  [[ ! -e /etc/docker/daemon.json.before-podman.~1~ ]]
}

package_fixture docker 1
package_fixture podman-docker 1
for variant in omarchy-settings omarchy-settings-dev; do
  package_fixture "$variant" 1 false
  package_fixture "$variant" 2 true
  package_fixture "$variant" 3 true
  package_fixture "$variant" 4 false
  install_fixture docker 1
  install_fixture "$variant" 1
  printf 'custom Docker settings\n' >/etc/docker/daemon.json
  chmod 600 /etc/docker/daemon.json
  install_fixture "$variant" 2
  assert_pending
  printf 'ok - %s upgrade preserves custom and stock Docker config while migration is pending\n' "$variant"
  install_fixture podman-docker 1
  [[ $(pacman -Qq docker) == podman-docker ]]
  install_fixture "$variant" 3
  assert_retired
  install_fixture "$variant" 3
  assert_retired
  printf 'ok - %s post-migration upgrade/reinstall retires defaults without overwriting or duplicating custom backups\n' "$variant"
  pacman -R --noconfirm "$variant"
  rm -f /etc/docker/daemon.json.before-podman
  install_fixture "$variant" 3
  for path in "${paths[@]}"; do [[ ! -e /$path && ! -e /$path.before-podman ]]; done
  printf 'ok - fresh %s Podman settings leave no active Docker defaults\n' "$variant"
  install_fixture "$variant" 4
  for path in "${paths[@]}"; do [[ $(cat "/$path") == "stock $path" ]]; done
  printf 'ok - %s older source without the Podman generator retains its Docker defaults\n' "$variant"
  pacman -R --noconfirm "$variant"
done
