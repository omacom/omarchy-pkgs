#!/bin/bash
# Self-test for bin/check-dkms's plan: which packages of a channel are kernels
# and DKMS modules, which kernel/module pairs a check builds (only those that
# touch a changed package), and that every published DKMS package is in the
# registry. The build itself needs root and real packages; the DKMS check
# workflow runs it.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

entry() { # entry <db> <name> <version> <file>...: one package in a fixture database
  local dir="$tmp/$1/$2-$3" path
  mkdir -p "$dir"
  printf '%%FILENAME%%\n%s-%s-x86_64.pkg.tar.zst\n\n%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%SHA256SUM%%\n%s\n' \
    "$2" "$3" "$2" "$3" "$(printf '%s' "$2$3" | sha256sum | cut -d' ' -f1)" >"$dir/desc"
  {
    echo '%FILES%'
    for path in "${@:4}"; do echo "$path"; done
  } >"$dir/files"
}
channel() { # channel <db>: pack a fixture database
  bsdtar -czf "$tmp/$1.files" -C "$tmp/$1" .
}
for db in edge rc; do
  entry $db linux-omarchy-bore-headers 7.2.8-9 usr/share/doc/linux-omarchy-bore-headers/README
  entry $db intel-ipu7-camera 1.0.6-3 usr/src/ipu7-drivers-1.0.6/dkms.conf usr/src/vision-drivers-1.0.6/dkms.conf usr/bin/ipu7-tool
  entry $db hyprland 0.56.2-4 usr/bin/Hyprland
done
entry rc linux-omarchy-headers 7.2.8-8 usr/lib/modules/7.2.8-8-omarchy/build/Makefile
entry rc tuxedo-drivers-nocompatcheck-dkms 4.22.1-2 usr/src/tuxedo-drivers-v4.22.1/dkms.conf
entry edge linux-omarchy-headers 7.2.8-9 usr/lib/modules/7.2.8-9-omarchy/build/Makefile usr/lib/modules/7.2.8-9-omarchy/build/include/acpi/battery.h
entry edge tuxedo-drivers-nocompatcheck-dkms 4.22.1-2 usr/src/tuxedo-drivers-v4.22.1/dkms.conf usr/src/tuxedo-drivers-v4.22.1/Kbuild
channel edge
channel rc

printf '%s\n' '# test registry' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' 'xpadneo-dkms x86_64 aarch64' >"$tmp/registry"
export OMARCHY_DKMS_REGISTRY="$tmp/registry"
check() { "$ROOT/bin/check-dkms" plan --arch x86_64 --files-db "$tmp/edge.files" "$@" 2>"$tmp/stderr"; }

plan=$(check) || fail "a database whose DKMS packages are all listed plans cleanly: $(cat "$tmp/stderr")"
grep -qP '^kernel\tlinux-omarchy-headers\t7.2.8-9\t7.2.8-9-omarchy$' <<<"$plan" &&
  pass "a headers package with a build tree is a kernel, named by its module directory" || fail "kernel: $plan"
! grep -q bore <<<"$plan" && pass "a transitional headers package without a build tree is not a kernel" || fail "bore: $plan"
grep -qP '^dkms\tintel-ipu7-camera\t1.0.6-3\tipu7-drivers-1.0.6,vision-drivers-1.0.6$' <<<"$plan" &&
  pass "a package with dkms.conf trees under /usr/src is a DKMS package" || fail "dkms: $plan"
! grep -q hyprland <<<"$plan" && pass "other packages are left out" || fail "hyprland: $plan"
[[ $(grep -c '^pair' <<<"$plan") == 3 ]] && grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\tintel-ipu7-camera vision-drivers-1.0.6$' <<<"$plan" &&
  pass "with nothing to compare against, every kernel/module pair is checked" || fail "all pairs: $plan"
grep -q 'xpadneo-dkms is listed for x86_64 but not published here' "$tmp/stderr" &&
  pass "a listed package the channel does not publish is only noted" || fail "note: $(cat "$tmp/stderr")"

# A promotion checks the pairs that touch a version the target lacks.
plan=$(check --since-db "$tmp/rc.files")
[[ $(grep -c '^pair' <<<"$plan") == 3 ]] && grep -q 'linux-omarchy-headers 7.2.8-9-omarchy' <<<"$plan" &&
  pass "a new kernel is checked against every module" || fail "new kernel: $plan"
plan=$("$ROOT/bin/check-dkms" plan --arch x86_64 --files-db "$tmp/edge.files" --since-db "$tmp/edge.files" 2>/dev/null)
grep -qx 'nothing to check' <<<"$plan" && ! grep -q '^pair' <<<"$plan" &&
  pass "a promotion that moves no kernel or module checks nothing" || fail "unchanged: $plan"

printf '%s\n' 'intel-ipu7-camera x86_64' >"$tmp/registry"
if check >/dev/null; then
  fail "an unlisted DKMS package must fail the plan"
fi
grep -q 'tuxedo-drivers-nocompatcheck-dkms ships a DKMS module for x86_64 but is not in ci/dkms-packages' "$tmp/stderr" &&
  pass "a published DKMS package missing from the registry fails the plan" || fail "unlisted: $(cat "$tmp/stderr")"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' >"$tmp/registry"

# A pull request's fresh package replaces the published one and is what the
# check is about.
package() { # package <dir> <name> <version> <arch> <path>...
  local root="$tmp/pkgroot-$2"
  rm -rf "$root"
  mkdir -p "$root"
  printf 'pkgname = %s\npkgver = %s\narch = %s\n' "$2" "$3" "$4" >"$root/.PKGINFO"
  [[ -z ${PKGBASE:-} ]] || echo "pkgbase = $PKGBASE" >>"$root/.PKGINFO"
  for path in "${@:5}"; do mkdir -p "$root/${path%/*}"; touch "$root/$path"; done
  mkdir -p "$1"
  bsdtar -cf "$1/$2-$3-$4.pkg.tar.zst" --zstd -C "$root" .PKGINFO usr
}
package "$tmp/local" tuxedo-drivers-nocompatcheck-dkms 4.22.1-3 x86_64 usr/src/tuxedo-drivers-v4.22.1/dkms.conf
package "$tmp/local" yt6801-dkms 1.0.34-2 aarch64 usr/src/yt6801-1.0.34/dkms.conf
plan=$(check --local "$tmp/local") || fail "a local DKMS package plans: $(cat "$tmp/stderr")"
grep -qP '^dkms\ttuxedo-drivers-nocompatcheck-dkms\t4.22.1-3\t' <<<"$plan" && [[ $(grep -c $'^dkms\ttuxedo' <<<"$plan") == 1 ]] &&
  pass "a local package replaces the published one of the same name" || fail "replace: $plan"
[[ $(grep -c '^pair' <<<"$plan") == 1 ]] && grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\ttuxedo-drivers-nocompatcheck-dkms tuxedo-drivers-v4.22.1$' <<<"$plan" &&
  pass "a local DKMS package is checked against every kernel, and only it" || fail "local pairs: $plan"
! grep -q yt6801 <<<"$plan" && pass "a local package for another architecture is ignored" || fail "arch: $plan"

package "$tmp/local-kernel" linux-omarchy-headers 7.2.9-1 x86_64 usr/lib/modules/7.2.9-1-omarchy/build/Makefile
plan=$(check --local "$tmp/local-kernel")
[[ $(grep -c '^pair' <<<"$plan") == 3 ]] && grep -q 'linux-omarchy-headers 7.2.9-1-omarchy' <<<"$plan" &&
  pass "a local kernel is checked against every module" || fail "local kernel: $plan"

package "$tmp/local-lost" linux-omarchy-headers 7.2.9-1 x86_64 usr/share/doc/linux-omarchy-headers/README
if check --local "$tmp/local-lost" >/dev/null; then
  fail "a local kernel that lost its build tree must not let the published one stand in"
fi
grep -q "the local linux-omarchy-headers is a 'other' package, but the published one is 'kernel'" "$tmp/stderr" &&
  pass "a local package that lost its tree is an error, not the published one" || fail "lost: $(cat "$tmp/stderr")"

mkdir -p "$tmp/empty"
if check --local "$tmp/empty" >/dev/null; then fail "an empty --local must fail"; fi
grep -q 'holds no package for x86_64' "$tmp/stderr" && pass "an empty --local is an error" || fail "empty: $(cat "$tmp/stderr")"
if check --local "$tmp/missing" >/dev/null; then fail "a missing --local must fail"; fi
grep -q 'is not a directory' "$tmp/stderr" && pass "a missing --local is an error" || fail "missing: $(cat "$tmp/stderr")"
# A pull request's package names reach logs and markdown: makepkg's rules only.
package "$tmp/local-evil" 'xpadneo##[add-mask]x' 1-1 x86_64 usr/src/hid-xpadneo-1/dkms.conf
mv "$tmp/local-evil"/*.pkg.tar.zst "$tmp/local-evil/evil-1-1-x86_64.pkg.tar.zst"
if check --local "$tmp/local-evil" >/dev/null; then fail "a package name makepkg would not allow must fail"; fi
grep -q 'has a package name makepkg would not allow' "$tmp/stderr" || fail "evil name: $(cat "$tmp/stderr")"
package "$tmp/local-evil2" xpadneo-dkms '1-1 ##[x]' x86_64 usr/src/hid-xpadneo-1/dkms.conf
mv "$tmp/local-evil2"/*.pkg.tar.zst "$tmp/local-evil2/evil-1-1-x86_64.pkg.tar.zst"
if check --local "$tmp/local-evil2" >/dev/null; then fail "a version makepkg would not allow must fail"; fi
grep -q 'has a version makepkg would not allow' "$tmp/stderr" || fail "evil version: $(cat "$tmp/stderr")"
package "$tmp/local-evil3" xpadneo-dkms 1-1 x86_64 'usr/src/hid xpadneo [x]/dkms.conf'
if check --local "$tmp/local-evil3" >/dev/null; then fail "a DKMS tree name makepkg would not allow must fail"; fi
grep -q 'ships a kernel or DKMS tree with a name makepkg would not allow' "$tmp/stderr" ||
  fail "evil tree: $(cat "$tmp/stderr")"
mkdir -p "$tmp/local-evil4"
cp "$tmp/local/tuxedo-drivers-nocompatcheck-dkms-4.22.1-3-x86_64.pkg.tar.zst" "$tmp/local-evil4/tuxedo"$'\t'"x##[add-mask]y-1-1-x86_64.pkg.tar.zst"
if check --local "$tmp/local-evil4" >/dev/null; then fail "a package file name with a tab must fail"; fi
grep -q 'holds a package file whose name makepkg would not produce' "$tmp/stderr" && ! grep -qF '##[' "$tmp/stderr" &&
  pass "a pull request's package name, version, tree or file name outside makepkg's rules is an error, and not repeated" || fail "evil file: $(cat "$tmp/stderr")"

# kernels= limits a module to the kernels it is installed with.
entry scoped linux-aurora-headers 7.1.12-2 usr/lib/modules/7.1.12-2-ARCH/build/Makefile
entry scoped linux-omarchy-headers 7.2.8-13 usr/lib/modules/7.2.8-13-omarchy/build/Makefile
entry scoped omarchy-ane-dkms 0.4.9-1 usr/src/omarchy-ane-0.4.9/dkms.conf
entry scoped xpadneo-dkms 0.10.4-1 usr/src/hid-xpadneo-v0.10.4/dkms.conf
channel scoped
printf '%s\n' 'omarchy-ane-dkms aarch64 kernels=linux-aurora-headers' 'xpadneo-dkms x86_64 aarch64' >"$tmp/registry"
plan=$("$ROOT/bin/check-dkms" plan --arch aarch64 --files-db "$tmp/scoped.files" 2>/dev/null)
grep -qP '^pair\tlinux-aurora-headers 7.1.12-2-ARCH\tomarchy-ane-dkms ' <<<"$plan" &&
  ! grep -qP '^pair\tlinux-omarchy-headers \S+\tomarchy-ane-dkms ' <<<"$plan" &&
  [[ $(grep -c $'^pair\t.*xpadneo-dkms' <<<"$plan") == 2 ]] &&
  pass "a module limited to some kernels is only built against those" || fail "scope: $plan"

# kernels=!<headers> builds a module against every kernel but those.
entry scoped linux-n1x-headers 7.0.14-3 usr/lib/modules/7.0.14-3-n1x/build/Makefile
entry scoped nvidia-open-dkms 615.78.08-3 usr/src/nvidia-615.78.08/dkms.conf
entry scoped v4l2loopback-dkms 0.15.4-2 usr/src/v4l2loopback-0.15.4/dkms.conf
channel scoped
nvidia_kernels() { awk -F'\t' '$1 == "pair" && $3 ~ /^nvidia-open-dkms / { split($2, k, " "); print k[1] }' | sort | tr '\n' ' '; }
printf '%s\n' 'omarchy-ane-dkms aarch64 kernels=linux-aurora-headers' 'xpadneo-dkms x86_64 aarch64' \
  'nvidia-open-dkms aarch64 kernels=!linux-aurora-headers' 'v4l2loopback-dkms aarch64' >"$tmp/registry"
plan=$("$ROOT/bin/check-dkms" plan --arch aarch64 --files-db "$tmp/scoped.files" 2>"$tmp/stderr") || fail "exclude plan: $(cat "$tmp/stderr")"
nvidia=$(nvidia_kernels <<<"$plan")
[[ $nvidia == "linux-n1x-headers linux-omarchy-headers " ]] && [[ $(grep -c $'^pair\t.*xpadneo-dkms' <<<"$plan") == 3 ]] &&
  pass "a module that excludes a kernel builds against every other one" || fail "exclude: $nvidia / $plan"
# The registry itself: no Mac has an NVIDIA GPU. Its repo= packages come from
# a fixture extra repository.
mkdir -p "$tmp/extra-arm/v4l2loopback-dkms-0.15.4-2"
cp "$tmp/scoped/v4l2loopback-dkms-0.15.4-2"/* "$tmp/extra-arm/v4l2loopback-dkms-0.15.4-2/"
bsdtar -czf "$tmp/extra-arm.files" -C "$tmp/extra-arm" .
plan=$(OMARCHY_DKMS_REGISTRY="$ROOT/ci/dkms-packages" "$ROOT/bin/check-dkms" plan --arch aarch64 --files-db "$tmp/scoped.files" \
  --repo-files-db "extra=$tmp/extra-arm.files" 2>"$tmp/stderr") || fail "registry plan: $(cat "$tmp/stderr")"
nvidia=$(nvidia_kernels <<<"$plan")
[[ $nvidia == "linux-n1x-headers linux-omarchy-headers " ]] &&
  pass "ci/dkms-packages builds aarch64 nvidia-open-dkms against every kernel but linux-aurora" || fail "registry nvidia: $nvidia"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' >"$tmp/registry"

# repo= packages come from an Arch repository's files database. They pair
# whenever a kernel changes and never count as a change of their own.
entry extra v4l2loopback-dkms 0.15.4-2 usr/src/v4l2loopback-0.15.4/dkms.conf
entry extra hyprland-git 1-1 usr/bin/Hyprland
channel extra
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' 'v4l2loopback-dkms x86_64 repo=extra' >"$tmp/registry"
repo=(--repo-files-db "extra=$tmp/extra.files")
plan=$(check "${repo[@]}") || fail "a repo= package plans: $(cat "$tmp/stderr")"
grep -qP '^dkms\tv4l2loopback-dkms\t0.15.4-2\tv4l2loopback-0.15.4$' <<<"$plan" && ! grep -q hyprland-git <<<"$plan" &&
  grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\tv4l2loopback-dkms v4l2loopback-0.15.4$' <<<"$plan" &&
  pass "a repo= package is read from its repository and checked against every kernel" || fail "repo: $plan"
! grep -q 'v4l2loopback-dkms is listed for x86_64 but not published here' "$tmp/stderr" &&
  pass "a repo= package is not reported as missing from this repository" || fail "repo note: $(cat "$tmp/stderr")"
plan=$(check "${repo[@]}" --since-db "$tmp/edge.files")
grep -qx 'nothing to check' <<<"$plan" &&
  pass "a promotion that moves no kernel does not check repo= packages" || fail "repo unchanged: $plan"
plan=$(check "${repo[@]}" --since-db "$tmp/rc.files")
grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\tv4l2loopback-dkms ' <<<"$plan" &&
  pass "a promotion that moves a kernel checks it against repo= packages" || fail "repo kernel: $plan"
plan=$(check "${repo[@]}" --local "$tmp/local-kernel")
grep -qP '^pair\tlinux-omarchy-headers 7.2.9-1-omarchy\tv4l2loopback-dkms ' <<<"$plan" &&
  pass "a pull request's kernel is checked against repo= packages" || fail "repo local kernel: $plan"
plan=$(check --local "$tmp/local") || fail "a pull request without a kernel must not need repository databases: $(cat "$tmp/stderr")"
! grep -q v4l2loopback <<<"$plan" &&
  pass "a pull request without a kernel neither downloads nor checks repo= packages" || fail "repo not needed: $plan"
plan=$(check "${repo[@]}" --from-repos)
[[ $(grep -c '^pair' <<<"$plan") == 1 ]] && grep -q 'v4l2loopback-dkms' <<<"$plan" &&
  pass "--from-repos checks only repo= packages, against every kernel" || fail "from-repos: $plan"
if check >/dev/null; then fail "a whole-channel plan without the repository's files database must fail"; fi
grep -q "no files database given for v4l2loopback-dkms's repository, extra" "$tmp/stderr" &&
  pass "a missing repository database is an error" || fail "no repo db: $(cat "$tmp/stderr")"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' 'nosuch-dkms x86_64 repo=extra' >"$tmp/registry"
if check "${repo[@]}" >/dev/null; then fail "a repo= package its repository lacks must fail"; fi
grep -q 'nosuch-dkms is listed as coming from extra, but extra has no DKMS package of that name' "$tmp/stderr" &&
  pass "a repo= package missing from its repository is an error" || fail "repo missing: $(cat "$tmp/stderr")"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' 'v4l2loopback-dkms x86_64 repo=extra' >"$tmp/registry"
package "$tmp/local-own" v4l2loopback-dkms 0.15.5-1 x86_64 usr/src/v4l2loopback-0.15.5/dkms.conf
package "$tmp/local-own" linux-omarchy-headers 7.2.9-1 x86_64 usr/lib/modules/7.2.9-1-omarchy/build/Makefile
plan=$(check "${repo[@]}" --local "$tmp/local-own")
grep -qP '^dkms\tv4l2loopback-dkms\t0.15.5-1\t' <<<"$plan" && [[ $(grep -c $'^dkms\tv4l2loopback-dkms' <<<"$plan") == 1 ]] &&
  grep -q 'v4l2loopback-dkms is built here too' "$tmp/stderr" &&
  pass "this repository's own copy of a repo= package is the one checked" || fail "own copy: $plan $(cat "$tmp/stderr")"
plan=$(check "${repo[@]}" --since-db "$tmp/edge.files" --from-repos)
[[ $(grep -c '^pair' <<<"$plan") == 1 ]] && grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\tv4l2loopback-dkms ' <<<"$plan" &&
  pass "--from-repos checks repo= packages even alongside --since" || fail "from-repos since: $plan"

# This repository's own copy of a repo= name moves with promotions like any
# other package.
for db in own-old own-new; do
  entry $db linux-omarchy-headers 7.2.8-9 usr/lib/modules/7.2.8-9-omarchy/build/Makefile
done
entry own-old v4l2loopback-dkms 0.15.4-1 usr/src/v4l2loopback-0.15.4/dkms.conf
entry own-new v4l2loopback-dkms 0.15.5-1 usr/src/v4l2loopback-0.15.5/dkms.conf
channel own-old
channel own-new
plan=$("$ROOT/bin/check-dkms" plan --arch x86_64 --files-db "$tmp/own-new.files" --since-db "$tmp/own-old.files" "${repo[@]}" 2>/dev/null)
grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\tv4l2loopback-dkms v4l2loopback-0.15.5$' <<<"$plan" &&
  pass "a promotion that moves this repository's copy of a repo= name checks it" || fail "own copy promoted: $plan"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' >"$tmp/registry"

# A pull request that adds a DKMS recipe is checked before it publishes, even
# though master's registry does not list it yet.
package "$tmp/local-new" hid-nintendo2-dkms 0.1.0-1 x86_64 usr/src/hid-nintendo2-0.1.0/dkms.conf
plan=$(check --local "$tmp/local-new") || fail "an unlisted fresh DKMS package plans: $(cat "$tmp/stderr")"
[[ $(grep -c '^pair' <<<"$plan") == 1 ]] && grep -qP '^pair\tlinux-omarchy-headers 7.2.8-9-omarchy\thid-nintendo2-dkms hid-nintendo2-0.1.0$' <<<"$plan" &&
  grep -q 'hid-nintendo2-dkms is not in ci/dkms-packages yet' "$tmp/stderr" &&
  pass "an unlisted fresh DKMS package is checked against every kernel" || fail "new recipe: $plan $(cat "$tmp/stderr")"

# matrix: the legs a CI run fans out into, one per kernel and DKMS package,
# decided on the host before any container.
matrix() { "$ROOT/bin/check-dkms" matrix --arch "${ARCH:-x86_64}" --files-db "$tmp/edge.files" "$@" 2>"$tmp/stderr"; }
legs=$(matrix) || fail "a channel's matrix: $(cat "$tmp/stderr")"
jq -e 'length == 2 and (map(.module) | sort) == ["intel-ipu7-camera 1.0.6-3", "tuxedo-drivers-nocompatcheck-dkms 4.22.1-2"]
  and all(.arch == "x86_64" and .kernel == "linux-omarchy-headers 7.2.8-9")' <<<"$legs" >/dev/null &&
  pass "a channel's matrix has one leg per kernel and DKMS package, named with versions, however many trees it ships" || fail "legs: $legs"
package "$tmp/local-plain" hyprland 0.56.2-5 x86_64 usr/bin/Hyprland
[[ $(matrix --local "$tmp/local-plain") == '[]' ]] &&
  pass "a build without kernels or DKMS packages has no legs" || fail "plain: $(cat "$tmp/stderr")"
legs=$(matrix --local "$tmp/local")
jq -e '. == [{"arch": "x86_64", "kernel": "linux-omarchy-headers 7.2.8-9", "module": "tuxedo-drivers-nocompatcheck-dkms 4.22.1-3"}]' <<<"$legs" >/dev/null &&
  pass "a build with a DKMS package has a leg per kernel for it" || fail "dkms legs: $legs"
legs=$(matrix --local "$tmp/local-kernel")
jq -e 'length == 2 and all(.kernel == "linux-omarchy-headers 7.2.9-1")' <<<"$legs" >/dev/null &&
  pass "a build with a kernel has a leg per module for it" || fail "kernel legs: $legs"
# A package the matrix cannot read is an error, never an empty matrix.
mkdir -p "$tmp/local-unreadable"
echo "not an archive" >"$tmp/local-unreadable/xpadneo-dkms-1-1-x86_64.pkg.tar.zst"
if out=$(matrix --local "$tmp/local-unreadable"); then fail "an unreadable package must fail the matrix, not give: $out"; fi
grep -q 'cannot read' "$tmp/stderr" || fail "unreadable: $(cat "$tmp/stderr")"
if out=$(matrix --local "$tmp/local-evil"); then fail "a package with a bad name must fail the matrix, not give: $out"; fi
grep -q 'has a package name makepkg would not allow' "$tmp/stderr" &&
  pass "a package the matrix cannot read or trust fails it, it is not an empty matrix" || fail "evil matrix: $(cat "$tmp/stderr")"
[[ $(ARCH=aarch64 matrix --local "$tmp/local-kernel") == '[]' ]] &&
  pass "an architecture the build has nothing for has no legs, not an error" || fail "other arch: $(cat "$tmp/stderr")"
if matrix --local "$tmp/local-lost" >/dev/null; then fail "a kernel that lost its tree must fail the matrix"; fi
grep -q "the local linux-omarchy-headers is a 'other' package, but the published one is 'kernel'" "$tmp/stderr" &&
  pass "a package that lost its role fails the matrix, before any container" || fail "lost: $(cat "$tmp/stderr")"

# --save-local keeps what the legs install: kernels and DKMS packages.
package "$tmp/local-mixed" hyprland 0.56.2-5 x86_64 usr/bin/Hyprland
package "$tmp/local-mixed" linux-omarchy-headers 7.2.9-1 x86_64 usr/lib/modules/7.2.9-1-omarchy/build/Makefile
package "$tmp/local-mixed" yt6801-dkms 1.0.34-2 aarch64 usr/src/yt6801-1.0.34/dkms.conf
# The fixture channel stands in for both architectures here.
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64 aarch64' 'intel-ipu7-camera x86_64 aarch64' 'yt6801-dkms aarch64' >"$tmp/registry-both"
matrix --local "$tmp/local-mixed" --save-local "$tmp/saved" >/dev/null &&
  OMARCHY_DKMS_REGISTRY="$tmp/registry-both" ARCH=aarch64 matrix --local "$tmp/local-mixed" --save-local "$tmp/saved" >/dev/null ||
  fail "save-local: $(cat "$tmp/stderr")"
[[ $(ls "$tmp/saved" | tr '\n' ' ') == "linux-omarchy-headers-7.2.9-1-x86_64.pkg.tar.zst yt6801-dkms-1.0.34-2-aarch64.pkg.tar.zst " ]] &&
  pass "--save-local keeps each architecture's kernels and DKMS packages, nothing else" || fail "saved: $(ls "$tmp/saved")"

# --all: every pair of the channel, with a build's packages in place of the
# published ones; a build that ships nothing relevant still checks them all.
plan=$(check --local "$tmp/local" --all) || fail "all: $(cat "$tmp/stderr")"
[[ $(grep -c '^pair' <<<"$plan") == 3 ]] && grep -qP '^dkms\ttuxedo-drivers-nocompatcheck-dkms\t4.22.1-3\t' <<<"$plan" &&
  pass "--all checks every pair, the build's package in place of the published one" || fail "all: $plan"
legs=$(matrix --local "$tmp/local-plain" --all)
jq -e 'length == 2' <<<"$legs" >/dev/null &&
  pass "--all gives every leg even for a build without kernels or DKMS packages" || fail "all plain: $legs $(cat "$tmp/stderr")"

# One leg: --kernel (headers name or pkgbase) and --module keep its pairs only.
plan=$(check --kernel linux-omarchy-headers --module intel-ipu7-camera) || fail "leg: $(cat "$tmp/stderr")"
[[ $(grep -c '^pair' <<<"$plan") == 2 ]] && ! grep -q $'^pair\t.*tuxedo' <<<"$plan" &&
  pass "a leg keeps every tree of its module against its kernel, and nothing else" || fail "leg: $plan"
PKGBASE=linux-omarchy package "$tmp/local-base" linux-omarchy-headers 7.2.9-1 x86_64 usr/lib/modules/7.2.9-1-omarchy/build/Makefile
legs=$(matrix --local "$tmp/local-base")
jq -e 'all(.kernel == "linux-omarchy 7.2.9-1")' <<<"$legs" >/dev/null &&
  plan=$(check --local "$tmp/local-base" --kernel "linux-omarchy 7.2.9-1" --module "tuxedo-drivers-nocompatcheck-dkms 4.22.1-2") &&
  [[ $(grep -c '^pair' <<<"$plan") == 1 ]] &&
  pass "legs name a kernel by its pkgbase, and --kernel finds it by that" || fail "pkgbase: $legs $plan $(cat "$tmp/stderr")"
if check --kernel linux-gone >/dev/null; then fail "a leg the plan no longer has must fail"; fi
grep -q 'this plan has no pair for kernel linux-gone' "$tmp/stderr" &&
  pass "a leg whose pair left the plan fails, so the run is redone" || fail "gone: $(cat "$tmp/stderr")"
if check --kernel "linux-omarchy-headers 7.2.8-8" >/dev/null; then fail "a leg for a version the channel moved past must fail"; fi
grep -q 'this plan has no pair for kernel linux-omarchy-headers 7.2.8-8' "$tmp/stderr" &&
  pass "a leg for a version the channel no longer has fails, not checks the new one" || fail "moved: $(cat "$tmp/stderr")"

# known-broken="<why>": its failures are expected, and a pair that builds
# fails the check so the mark comes off. The reason may hold spaces and words
# like an architecture, which must not be read as fields.
printf '%s\n' 'macbook12-spi-driver-dkms x86_64 known-broken="no build since Linux 6.10 on x86_64 or aarch64"' \
  'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' >"$tmp/registry"
judge() { "$ROOT/bin/check-dkms" judge --arch "${ARCH:-x86_64}" 2>"$tmp/stderr"; }
raw() { printf 'linux-omarchy-headers\t7.2.8-9-omarchy\t%s\t%s\t%s\t-\n' "$@"; }
verdicts() { cut -f5 <<<"$1" | tr '\n' ' '; }
out=$(raw macbook12-spi-driver-dkms macbook12-spi-driver-0+git.315 failed tuxedo-drivers-nocompatcheck-dkms tuxedo-drivers-v4.22.1 built | judge) &&
  [[ $(verdicts "$out") == "known-broken built " ]] && grep -qF 'known broken: no build since Linux 6.10 on x86_64 or aarch64' <<<"$out" &&
  pass "a known-broken package that fails is reported as known broken, and passes" || fail "known broken: $out $(cat "$tmp/stderr")"
if out=$(raw macbook12-spi-driver-dkms macbook12-spi-driver-0+git.315 built | judge); then
  fail "a known-broken package that builds must fail the check: $out"
fi
[[ $(verdicts "$out") == "fixed " ]] && grep -qF 'builds now; remove its known-broken mark' <<<"$out" &&
  pass "a known-broken package that builds fails, so the mark is removed" || fail "fixed: $out"
out=$(raw macbook12-spi-driver-dkms macbook12-spi-driver-0+git.315 excluded | judge) && [[ $(verdicts "$out") == "excluded " ]] &&
  pass "a known-broken package that a kernel excludes is neither broken nor fixed" || fail "excluded: $out"
if out=$(raw tuxedo-drivers-nocompatcheck-dkms tuxedo-drivers-v4.22.1 failed | judge); then fail "an unmarked failure must fail: $out"; fi
[[ $(verdicts "$out") == "failed " ]] && pass "a package without the mark that fails, fails" || fail "failed: $out"
plan=$(ARCH=aarch64 "$ROOT/bin/check-dkms" plan --arch aarch64 --files-db "$tmp/edge.files" 2>&1 || true)
! grep -q 'macbook12-spi-driver-dkms is listed for aarch64' <<<"$plan" &&
  pass "an architecture named inside a reason does not list the package for it" || fail "reason fields: $plan"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64 known_broken="typo"' >"$tmp/registry"
if check >/dev/null; then fail "an unknown registry field must fail"; fi
grep -q 'unknown field known_broken="typo"' "$tmp/stderr" &&
  pass "a misspelt registry field is an error, not ignored" || fail "unknown field: $(cat "$tmp/stderr")"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64 known-broken=""' >"$tmp/registry"
if check >/dev/null; then fail "a known-broken mark without a reason must fail"; fi
grep -q 'known-broken needs a reason' "$tmp/stderr" &&
  pass "a known-broken mark needs a reason" || fail "no reason: $(cat "$tmp/stderr")"
# The registry itself: macbook12-spi-driver-dkms is marked.
out=$(raw macbook12-spi-driver-dkms macbook12-spi-driver-0+git.315 failed | OMARCHY_DKMS_REGISTRY="$ROOT/ci/dkms-packages" judge) &&
  [[ $(verdicts "$out") == "known-broken " ]] &&
  pass "ci/dkms-packages marks macbook12-spi-driver-dkms known broken" || fail "registry mark: $out $(cat "$tmp/stderr")"
printf '%s\n' 'tuxedo-drivers-nocompatcheck-dkms x86_64' 'intel-ipu7-camera x86_64' >"$tmp/registry"

# container: the leg's outcome is decided out here, from run's exit status
# and the verdicts it leaves in /results. docker is a stub that writes
# $FAKE_PAIRS there, prints a workflow command, and exits $FAKE_STATUS.
mkdir -p "$tmp/dockerbin"
cat >"$tmp/dockerbin/docker" <<'DOCKER'
#!/bin/bash
results=""
while (($#)); do
  if [[ $1 == -v && $2 == *:/results ]]; then results=${2%:/results}; fi
  shift
done
[[ -z ${FAKE_PAIRS:-} ]] || cp "$FAKE_PAIRS" "$results/pairs.tsv"
echo "::error::printed by the pull request's Makefile"
exit "$FAKE_STATUS"
DOCKER
chmod +x "$tmp/dockerbin/docker"
leg() { # leg <status> <verdict>...: run container with a stub run; sets $out and $leg_status
  local v
  : >"$tmp/pairs.tsv"
  for v in "${@:2}"; do
    printf 'linux-omarchy-headers\t7.2.8-9-omarchy\tintel-ipu7-camera\t%s-1.0.6\t%s\t%s\n' "${v%%:*}" "${v#*:}" \
      "$(case ${v#*:} in built) echo built ;; excluded) echo 'excluded (BUILD_EXCLUSIVE)' ;; known-broken) echo 'known broken: why' ;; *) echo FAILED ;; esac)" >>"$tmp/pairs.tsv"
  done
  leg_status=0
  out=$(PATH="$tmp/dockerbin:$PATH" FAKE_STATUS=$1 FAKE_PAIRS=$([[ $# -gt 1 ]] && echo "$tmp/pairs.tsv") GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="" \
    "$ROOT/bin/check-dkms" container --arch x86_64 --channel edge --kernel "linux-omarchy 7.2.8-9" --module "intel-ipu7-camera 1.0.6-3" \
    --result "$tmp/result.json" 2>&1) || leg_status=$?
}
outcome() { jq -r .outcome "$tmp/result.json"; }
leg 0 ipu7:built
((leg_status == 0)) && [[ $(outcome) == passed ]] && jq -e '.kernel == "linux-omarchy 7.2.8-9" and .module == "intel-ipu7-camera 1.0.6-3" and .detail == ""' "$tmp/result.json" >/dev/null &&
  pass "a leg whose pairs built passed, named as the matrix names it" || fail "passed: $out $(cat "$tmp/result.json")"
leg 0 ipu7:built vision:excluded
((leg_status == 0)) && [[ $(outcome) == passed ]] && jq -e '.detail == "ipu7-1.0.6: built; vision-1.0.6: excluded (BUILD_EXCLUSIVE)"' "$tmp/result.json" >/dev/null &&
  pass "a leg with several trees passes on its worst one and names each" || fail "trees: $(cat "$tmp/result.json")"
leg 0 ipu7:known-broken
((leg_status == 0)) && [[ $(outcome) == known-broken ]] &&
  pass "a known-broken leg passes, reported as known broken" || fail "known broken: $(cat "$tmp/result.json")"
leg 1 ipu7:fixed
((leg_status == 1)) && [[ $(outcome) == fixed ]] &&
  pass "a known-broken leg that builds fails" || fail "fixed: $(cat "$tmp/result.json")"
leg 1 ipu7:failed
((leg_status == 1)) && [[ $(outcome) == failed ]] && pass "a failed leg fails" || fail "failed: $(cat "$tmp/result.json")"
leg 2
((leg_status == 1)) && [[ $(outcome) == error ]] && grep -q 'exit status 2' "$tmp/result.json" &&
  pass "a run that stopped before any verdict is an error, not a pass" || fail "stopped: $(cat "$tmp/result.json")"
leg 0 ipu7:failed
((leg_status == 1)) && [[ $(outcome) == error ]] &&
  pass "an exit status that disagrees with the verdicts is an error" || fail "disagree: $(cat "$tmp/result.json")"
token=$(sed -n 's/^::stop-commands::\([0-9a-f]\{32\}\)$/\1/p' <<<"$out")
[[ -n $token ]] && sed -n "/^::stop-commands::$token$/,/^::$token::$/p" <<<"$out" | grep -q '^::error::printed by' &&
  sed -n "/^::stop-commands::$token$/,/^::$token::$/p" <<<"$out" | grep -q '^==> ' &&
  pass "nothing the container prints, nor the outcome made from it, acts as a workflow command" || fail "stop-commands: $out"
printf 'linux-omarchy-headers\t7.2.8-9-omarchy\tintel-ipu7-camera\tipu7-1.0.6\tbuilt\tbuilt\n' >"$tmp/pairs.tsv"
printf 'linux-omarchy-headers\t7.2.8-9-omarchy\tintel-ipu7-camera\tvision-1.0.6\tgarbage\tbuilt\n' >>"$tmp/pairs.tsv"
leg_status=0
PATH="$tmp/dockerbin:$PATH" FAKE_STATUS=0 FAKE_PAIRS="$tmp/pairs.tsv" "$ROOT/bin/check-dkms" container --arch x86_64 --channel edge \
  --kernel "linux-omarchy 7.2.8-9" --module "intel-ipu7-camera 1.0.6-3" --result "$tmp/result.json" >/dev/null 2>&1 || leg_status=$?
((leg_status == 1)) && [[ $(outcome) == error ]] && grep -q 'malformed' "$tmp/result.json" &&
  pass "a verdict row the check does not know is an error, never a pass" || fail "malformed: $(cat "$tmp/result.json")"
printf 'linux-omarchy-headers\t7.2.8-9-omarchy\tintel-ipu7-camera\tipu7-1.0.6\tbuilt\tbuilt ##[add-mask]x <b>\n' >"$tmp/pairs.tsv"
PATH="$tmp/dockerbin:$PATH" FAKE_STATUS=0 FAKE_PAIRS="$tmp/pairs.tsv" "$ROOT/bin/check-dkms" container --arch x86_64 --channel edge \
  --kernel "linux-omarchy 7.2.8-9" --module "intel-ipu7-camera 1.0.6-3" --result "$tmp/result.json" >/dev/null 2>&1 || true
jq -e '.detail | test("[\\[<>]") | not' "$tmp/result.json" >/dev/null &&
  pass "the container's text reaches the result as plain text" || fail "plain: $(cat "$tmp/result.json")"

# report: one verdict for a run, from its legs and their results.
mkdir -p "$tmp/report"
printf '%s\n' '[{"arch":"x86_64","kernel":"linux-omarchy 7.2.8-9","module":"tuxedo-drivers-nocompatcheck-dkms 4.22.1-3"},' \
  '{"arch":"x86_64","kernel":"linux-omarchy 7.2.8-9","module":"macbook12-spi-driver-dkms 0+git.315-2"},' \
  '{"arch":"aarch64","kernel":"linux-aurora 7.1.12.aurora7-2","module":"xpadneo-dkms 0.10.4-1.1"}]' >"$tmp/legs.json"
jq -n '{arch:"x86_64",kernel:"linux-omarchy 7.2.8-9",module:"tuxedo-drivers-nocompatcheck-dkms 4.22.1-3",outcome:"passed",detail:""}' >"$tmp/report/1.json"
jq -n '{arch:"x86_64",kernel:"linux-omarchy 7.2.8-9",module:"macbook12-spi-driver-dkms 0+git.315-2",outcome:"known-broken",detail:"known broken: why"}' >"$tmp/report/2.json"
report() { "$ROOT/bin/check-dkms" report --legs "$tmp/legs.json" --results "$tmp/report" --url https://example.invalid/run --channel edge "$@" 2>"$tmp/stderr"; }
out=$(report --plan success) || fail "report: $(cat "$tmp/stderr")"
jq -e '.conclusion == "failure" and .title == "1/3 passed, 1 known broken, 1 failed"' <<<"$out" >/dev/null &&
  jq -r .summary <<<"$out" | grep -qF '| no result | aarch64 | `linux-aurora 7.1.12.aurora7-2` | `xpadneo-dkms 0.10.4-1.1` | `the leg left no result` |' &&
  pass "a leg without a result fails the run, and the title counts passed, known broken and failed" || fail "report: $out"
jq -n '{arch:"aarch64",kernel:"linux-aurora 7.1.12.aurora7-2",module:"xpadneo-dkms 0.10.4-1.1",outcome:"passed",detail:""}' >"$tmp/report/3.json"
out=$(report --plan success)
jq -e '.conclusion == "success" and .title == "2/3 passed, 1 known broken"' <<<"$out" >/dev/null &&
  jq -r .summary <<<"$out" | sed -n '1p' | grep -qF '**2/3 passed, 1 known broken** on edge.' &&
  pass "known broken legs do not fail the run" || fail "known broken run: $out"
out=$(report --plan failure)
jq -e '.conclusion == "failure" and .title == "The DKMS plan did not finish"' <<<"$out" >/dev/null &&
  pass "a plan that failed fails the run" || fail "plan failed: $out"
echo '[]' >"$tmp/no-legs.json"
out=$("$ROOT/bin/check-dkms" report --legs "$tmp/no-legs.json" --results "$tmp/report" --plan success --note "This build ships no kernel or DKMS package")
jq -e '.conclusion == "success" and .title == "Nothing to check" and (.summary | startswith("This build ships no kernel or DKMS package."))' <<<"$out" >/dev/null &&
  pass "a run without legs has nothing to check, and says why" || fail "no legs: $out"
printf '%s\n' '[{"arch":"x86_64","kernel":"@omacom/core https://attacker.invalid","module":"evil|<img src=x>[a](https://x)`b`"}]' >"$tmp/evil.json"
out=$("$ROOT/bin/check-dkms" report --legs "$tmp/evil.json" --results "$tmp/report" --plan success)
row=$(jq -r .summary <<<"$out" | tail -n 1)
[[ $(tr -cd '|' <<<"$row" | wc -c) == 6 && $row != *'<'* && $row != *'['* ]] &&
  [[ $row == '| no result | x86_64 | `@omacom/core https://attacker.invalid` | `evil  img src=x  a (https://x) b ` | `the leg left no result` |' ]] &&
  pass "names from package metadata cannot add cells, HTML, links or mentions to the summary" || fail "escape: $row"

# A kernel built with clang (linux-aurora) needs clang, llvm and lld: DKMS
# builds its modules with LLVM=1. Read from the installed build tree.
mkdir -p "$tmp/clang-build" "$tmp/gcc-build"
printf '%s\n' 'CONFIG_CC_VERSION_TEXT="clang version 18.1.8"' 'CONFIG_CC_IS_CLANG=y' 'CONFIG_LD_IS_LLD=y' >"$tmp/clang-build/.config"
printf '%s\n' 'CONFIG_CC_IS_GCC=y' '# CONFIG_CC_IS_CLANG is not set' >"$tmp/gcc-build/.config"
[[ $("$ROOT/bin/check-dkms" toolchain "$tmp/clang-build" 2>&1) == "clang llvm lld" ]] &&
  pass "a kernel built with clang needs clang, llvm and lld" || fail "clang: $("$ROOT/bin/check-dkms" toolchain "$tmp/clang-build" 2>&1)"
[[ -z $("$ROOT/bin/check-dkms" toolchain "$tmp/gcc-build" "$tmp/missing-build" 2>&1) ]] &&
  pass "a kernel built with gcc, or one without a .config, needs nothing more" || fail "gcc: $("$ROOT/bin/check-dkms" toolchain "$tmp/gcc-build" 2>&1)"
[[ $("$ROOT/bin/check-dkms" toolchain "$tmp/gcc-build" "$tmp/clang-build" 2>&1) == "clang llvm lld" ]] &&
  pass "one kernel built with clang among several is enough" || fail "mixed"

# run installs packages, so it must refuse to start without root. Checked only
# when not root: as root it would really install them.
if ((EUID != 0)); then
  if "$ROOT/bin/check-dkms" run --arch x86_64 --channel edge >/dev/null 2>"$tmp/stderr"; then fail "run must refuse without root"; fi
  grep -q 'as root in a disposable system' "$tmp/stderr" && pass "run refuses to install packages without root" || fail "root: $(cat "$tmp/stderr")"
fi
