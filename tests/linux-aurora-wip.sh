#!/bin/bash
# linux-aurora-wip installs next to linux-aurora on an Apple Silicon Mac. The
# recipe keeps linux-aurora's config and Rust toolchain, never provides or
# conflicts with what linux-aurora does, and names its kernel release so that
# update-m1n1 (its DTBS default is the newest /lib/modules/*-ARCH) keeps
# building m1n1 stage 2 from linux-aurora's device trees. prepare() runs here
# over a fake source tree whose make reports what Kbuild would.
set -euo pipefail

REPO_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
RECIPE=$REPO_ROOT/pkgbuilds/linux-aurora-wip
DEFAULT=$REPO_ROOT/pkgbuilds/linux-aurora
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "not ok - $1" >&2
  [[ $# -lt 2 ]] || printf '%s\n' "$2" >&2
  exit 1
}
pass() {
  echo "ok - $1"
}

for file in config rust-toolchain.toml; do
  cmp -s "$RECIPE/$file" "$DEFAULT/$file" || fail "$file is linux-aurora's" "$(diff "$DEFAULT/$file" "$RECIPE/$file" | head -n 20)"
done
pass "the kernel config and Rust toolchain are linux-aurora's"

recipe() {
  (cd "$1" && CARCH=aarch64 bash -c 'source PKGBUILD >/dev/null 2>&1; '"$2")
}

[[ $(recipe "$RECIPE" 'printf "%s\n" "$pkgbase" "${arch[*]}" "${groups[*]}" "${pkgname[*]}"') == \
  $'linux-aurora-wip\naarch64\nomarchy-platform-apple-silicon\nlinux-aurora-wip linux-aurora-wip-headers' ]] ||
  fail "the recipe is the Apple-only linux-aurora-wip and its headers"
commit=$(recipe "$RECIPE" 'printf %s "$_commit"')
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "_commit is a full commit: $commit"
[[ $(recipe "$RECIPE" 'printf %s "${source[0]}"') == "https://github.com/aurora-silicon/linux/archive/$commit.tar.gz" ]] ||
  fail "the source is the archive of the pinned commit"
version=$(recipe "$RECIPE" 'printf %s "$pkgver"')
prefix=$(recipe "$RECIPE" 'printf %s "$_auroraver.aurora$_aurorarel"')
[[ $version =~ ^${prefix//./\\.}\.r[0-9]+\.g${commit:0:7}$ ]] || fail "pkgver $version names the pinned commit after $prefix"
pass "the recipe pins one commit and names it in pkgver"

metadata=$RECIPE/.omarchy/package.json
jq -e --arg version "$prefix.r{count}.g{commit:.7}" '
  .channels == ["edge"] and
  .upstream.watch.git_branch == "https://github.com/aurora-silicon/linux.git" and
  .upstream.watch.branch == "aurora-wip" and
  .upstream.watch.version == $version and
  .upstream.watch.variables == {"_commit": "{commit}"}' "$metadata" >/dev/null ||
  fail "the watch follows aurora-wip on edge with the recipe's version prefix" "$(cat "$metadata")"
pass "the upstream watch follows aurora-wip and versions pins after the recipe's prefix"

# package()'s metadata, read the way makepkg reads a split package's.
kernel_fields=$(recipe "$RECIPE" '
  install() { :; }; make() { :; }; rm() { :; }; echo() { :; }
  O=/dev/null pkgdir=/nonexistent _package_kernel "$pkgbase" 2>/dev/null
  printf "%s\n" "depends=${depends[*]}" "provides=${provides[*]}" "conflicts=${conflicts[*]:-}" "replaces=${replaces[*]:-}" "install=$install"')
headers_fields=$(recipe "$RECIPE" 'declare -f _package-headers')
grep -Eq '^depends=.* linux-aurora( |$)' <<<"$kernel_fields" || fail "the kernel depends on linux-aurora" "$kernel_fields"
grep -Fxq 'install=linux-aurora-wip.install' <<<"$kernel_fields" || fail "the kernel package runs its scriptlet" "$kernel_fields"
[[ -f $RECIPE/linux-aurora-wip.install ]] && bash -n "$RECIPE/linux-aurora-wip.install" || fail "the scriptlet parses"
! grep -Eq 'linux-asahi|linux-aurora([^-]|$)' <<<"$(grep -E '^(provides|conflicts|replaces)=' <<<"$kernel_fields")" ||
  fail "the kernel neither provides nor conflicts with what linux-aurora does" "$kernel_fields"
! grep -Eq '(provides|conflicts|replaces)=' <<<"$headers_fields" || fail "the headers neither provide nor conflict with anything"
pass "the packages install beside linux-aurora and its headers, and need linux-aurora"

# A source tree whose make answers like Kbuild: kernelversion from the
# recipe's version, kernelrelease from the localversion files and the
# configured CONFIG_LOCALVERSION.
fake_tree() {
  local kernelversion=$1
  rm -rf "$TEST_ROOT/src" "$TEST_ROOT/bin"
  mkdir -p "$TEST_ROOT/src/linux-$commit" "$TEST_ROOT/bin"
  cp "$RECIPE/config" "$RECIPE/rust-toolchain.toml" "$TEST_ROOT/src/"
  cat >"$TEST_ROOT/bin/make" <<SH
#!/bin/bash
out=
for arg; do [[ \$arg == O=* ]] && out=\${arg#O=}; done
case "\$*" in
  "-s kernelversion") echo $kernelversion ;;
  "-s kernelrelease "*)
    local_config=\$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "\$out/.config")
    printf '%s%s%s\n' $kernelversion "\$(cat localversion.* 2>/dev/null | tr -d '\n')" "\$local_config" ;;
  olddefconfig*) ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$TEST_ROOT/bin/make"
}

run_prepare() {
  (cd "$RECIPE" && PATH="$TEST_ROOT/bin:$PATH" CARCH=aarch64 bash -c '
    source PKGBUILD >/dev/null 2>&1
    srcdir=$1
    cd "$srcdir"
    prepare' _ "$TEST_ROOT/src") >"$TEST_ROOT/out" 2>&1
}

fake_tree "$(recipe "$RECIPE" 'printf %s "$_auroraver"')"
run_prepare || fail "prepare() accepts the pinned kernel version" "$(cat "$TEST_ROOT/out")"
release=$(<"$TEST_ROOT/src/linux-$commit/build/base/version")
pkgrel=$(recipe "$RECIPE" 'printf %s "$pkgrel"')
auroraver=$(recipe "$RECIPE" 'printf %s "$_auroraver"')
[[ $release == "$auroraver-${version#"$auroraver.aurora"}-$pkgrel-aurora-wip" ]] ||
  fail "the kernel release names the commit and the package" "$release"
[[ $release != *-ARCH ]] || fail "the kernel release does not end in -ARCH" "$release"
default_release=7.1.12-2-11-ARCH
newest=$(printf '%s\n' "$default_release" "$release" | grep -- '-ARCH$' | sort -rV | head -n 1)
[[ $newest == "$default_release" ]] || fail "update-m1n1's DTBS default keeps taking linux-aurora's device trees" "$newest"
pass "the kernel release ($release) keeps update-m1n1 on linux-aurora's device trees"

fake_tree 7.1.13
! run_prepare || fail "prepare() refuses a branch that moved to another kernel version"
grep -Fq 'aurora-wip is at 7.1.13, but this recipe is versioned' "$TEST_ROOT/out" || fail "the refusal says what to bump" "$(cat "$TEST_ROOT/out")"
pass "a rebase onto another kernel version fails the build until the recipe's version is bumped"
