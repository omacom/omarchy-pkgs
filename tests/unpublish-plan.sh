#!/bin/bash
# bin/unpublish-plan retires an entry only from a channel and architecture no
# recipe publishes it to, and refuses a package a recipe still publishes
# everywhere it was asked for.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

recipe() { # recipe <dir> <arches> [package.json] [pkgbase]
  mkdir -p "$T/pkgbuilds/$1/.omarchy"
  printf '%spkgname=%s\npkgver=1\npkgrel=1\narch=(%s)\n' "${4:+pkgbase=$4$'\n'}" "$1" "$2" > "$T/pkgbuilds/$1/PKGBUILD"
  echo "${3:-"{\"source\": \"local\"}"}" > "$T/pkgbuilds/$1/.omarchy/package.json"
}
recipe everywhere "x86_64 aarch64"
recipe arm-only "aarch64"
recipe icon-theme "any"
sed -i 's/^pkgname=icon-theme$/pkgbase=icons\npkgname=(icons-light icons-dark)/' "$T/pkgbuilds/icon-theme/PKGBUILD"

plan() { OMARCHY_PKGBUILDS="$T/pkgbuilds" "$ROOT/bin/unpublish-plan" "$@" 2>"$T/err"; }
line() { grep "^$1=" <<<"$out" | cut -d= -f2-; }
expect_abort() { # expect_abort <desc> <err_pattern> [plan args...]
  local desc=$1 pat=$2 out=""
  shift 2
  out=$(plan "$@") && fail "$desc should fail closed"
  [[ -z $out ]] && grep -qE "$pat" "$T/err" && pass "$desc" || fail "$desc: out=$out err=$(cat "$T/err")"
}

out=$(plan --channels "stable" arm-only gone) || fail "arm-only refused: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == "arm-only gone" && $(line RETIRE_STABLE_AARCH64) == gone ]] &&
  pass "a dropped architecture and a removed recipe are retired, the rest kept" || fail "arch plan: $out"
[[ -z $(line RETIRE_RC_X86_64) ]] && pass "a channel not asked for is left alone" || fail "rc touched: $out"

plan --channels "edge rc stable" everywhere >/dev/null && fail "a package published everywhere was not refused"
grep -q "still published to every channel" "$T/err" && pass "a package still published everywhere asked for is refused" || fail "message: $(cat "$T/err")"
plan --channels "edge rc stable" icons >/dev/null && fail "a pkgbase built under another directory name was retired: $(cat "$T/err")"
pass "a pkgbase is matched to the recipe that builds it, whatever its directory is called"
out=$(plan --channels "stable" icon-theme) || fail "old pkgbase icon-theme should retire when icon-theme builds icons: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == icon-theme && $(line RETIRE_STABLE_AARCH64) == icon-theme ]] &&
  pass "renamed pkgbase allows retiring the old directory name on both architectures" || fail "icon-theme retire: $out"
plan --channels "rc" everywhere >/dev/null && fail "a package was retired from rc although its recipe publishes it there by promotion"
pass "a package with a recipe is refused for rc too, which promotion fills from edge"
plan --channels "stable beta" gone >/dev/null && fail "an unknown channel was accepted"
pass "an unknown channel is refused"
plan --channels "stable" 'bad name' >/dev/null && fail "a bad package name was accepted"
pass "a bad package name is refused"
plan --channels >/dev/null && fail "a bare --channels was accepted"
pass "a bare --channels is refused"

# Disjoint-arch recipes sharing a pkgbase must not clobber each other in RECIPE,
# regardless of directory sort order.
recipe dual-a "x86_64" "" dual
recipe dual-z "aarch64" "" dual
plan --channels "stable" dual >/dev/null && fail "disjoint-arch pkgbase was retired on x86_64"
grep -q "still published to every channel" "$T/err" && pass "disjoint-arch recipes sharing a pkgbase keep both architectures (x86_64 before aarch64)" || fail "disjoint dual: $(cat "$T/err")"

recipe dual2-a "aarch64" "" dual2
recipe dual2-z "x86_64" "" dual2
plan --channels "stable" dual2 >/dev/null && fail "disjoint-arch pkgbase was retired on aarch64"
grep -q "still published to every channel" "$T/err" && pass "disjoint-arch recipes sharing a pkgbase keep both architectures (aarch64 before x86_64)" || fail "disjoint dual2: $(cat "$T/err")"

rm -rf "$T/pkgbuilds/dual-a"
out=$(plan --channels "stable" dual) || fail "retiring dropped arch of disjoint pkgbase failed: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == dual && -z $(line RETIRE_STABLE_AARCH64) ]] &&
  pass "removing one disjoint-arch recipe retires only its architecture" || fail "partial disjoint retire: $out"

# Hidden scratch dirs (e.g. bin/import-aur's .import-aur.XXXXXX) are ignored.
mkdir -p "$T/pkgbuilds/.import-aur.tmp"
plan --channels "stable" everywhere >/dev/null && fail "hidden scratch dir broke live check"
grep -q "still published to every channel" "$T/err" && pass "hidden dot-directories in pkgbuilds/ are ignored" || fail "dot-dir: $(cat "$T/err")"
rm -rf "$T/pkgbuilds/.import-aur.tmp"

# arch=(any) with a CARCH-dependent pkgbase uses the first CI arch (matching build-matrix).
mkdir -p "$T/pkgbuilds/any-carch/.omarchy"
printf 'pkgbase=any-%s\npkgname=("$pkgbase")\npkgver=1\npkgrel=1\narch=(any)\n' '${CARCH}' > "$T/pkgbuilds/any-carch/PKGBUILD"
echo '{"source": "local"}' > "$T/pkgbuilds/any-carch/.omarchy/package.json"
plan --channels "stable" any-x86_64 >/dev/null && fail "arch=(any) pkgbase built on x86_64 was retired on aarch64"
grep -q "still published to every channel" "$T/err" && pass "arch=(any) with CARCH-dependent pkgbase resolves to build-matrix's x86_64 pkgbase on both arches" || fail "any-carch: $(cat "$T/err")"
rm -rf "$T/pkgbuilds/any-carch"

# If x86_64 does NOT declare any, aarch64 declaring arch=(any) builds natively on
# aarch64 with its own pkgbase (matching build-matrix), not x86_64's pkgbase.
mkdir -p "$T/pkgbuilds/arm-any-only/.omarchy"
cat > "$T/pkgbuilds/arm-any-only/PKGBUILD" <<'EOF'
if [[ $CARCH == x86_64 ]]; then
  pkgbase=tool-x86
  arch=(x86_64)
else
  pkgbase=tool-arm
  arch=(any)
fi
pkgname=("$pkgbase")
pkgver=1
pkgrel=1
EOF
echo '{"source": "local"}' > "$T/pkgbuilds/arm-any-only/.omarchy/package.json"
out=$(plan --channels "stable" tool-arm) || fail "arm-any-only tool-arm failed: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == "tool-arm" && -z $(line RETIRE_STABLE_AARCH64) ]] \
  && pass "CARCH-conditional arch=(any) on aarch64 keeps aarch64's own pkgbase" || fail "arm-any-only tool-arm: $out"
out=$(plan --channels "stable" tool-x86) || fail "arm-any-only tool-x86 failed: $(cat "$T/err")"
[[ -z $(line RETIRE_STABLE_X86_64) && $(line RETIRE_STABLE_AARCH64) == "tool-x86" ]] \
  && pass "CARCH-conditional arch=(x86_64) on x86_64 keeps x86_64's own pkgbase" || fail "arm-any-only tool-x86: $out"
rm -rf "$T/pkgbuilds/arm-any-only"

# Batched CARCH/source scan must detect ||source forms and keep the live ARM pkgbase.
mkdir -p "$T/pkgbuilds/or-source/.omarchy"
cat > "$T/pkgbuilds/or-source/arch.sh" <<'EOF'
pkgbase="or-src-$CARCH"
pkgname=("$pkgbase")
arch=("$CARCH")
EOF
cat > "$T/pkgbuilds/or-source/PKGBUILD" <<'EOF'
false||source ./arch.sh
pkgver=1
pkgrel=1
EOF
echo '{"source": "local"}' > "$T/pkgbuilds/or-source/.omarchy/package.json"
out=$(plan --channels "stable" or-src-aarch64) || fail "or-source aarch64 failed: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == "or-src-aarch64" && -z $(line RETIRE_STABLE_AARCH64) ]] \
  && pass "||source PKGBUILD keeps live arch-specific pkgbase on aarch64" || fail "or-source: $out"
mkdir -p "$T/bm-root/bin" && cp -r "$ROOT/helpers" "$T/bm-root/" && cp "$ROOT/bin/build-matrix" "$T/bm-root/bin/" && ln -sfn "$T/pkgbuilds" "$T/bm-root/pkgbuilds"
bm_arches=$("$T/bm-root/bin/build-matrix" or-source | jq -r '[.include[].arch] | sort | join(" ")')
[[ $bm_arches == "aarch64 x86_64" ]] \
  && pass "build-matrix matches ||source PKGBUILD on both architectures" || fail "or-source build-matrix: $bm_arches"
rm -rf "$T/pkgbuilds/or-source"

# A PKGBUILD that declares arch=("$CARCH") and then fails on aarch64 MUST fail
# closed rather than treating aarch64 as unsupported and retiring a live package.
mkdir -p "$T/pkgbuilds/broken-arm-include/.omarchy"
cat > "$T/pkgbuilds/broken-arm-include/PKGBUILD" <<'EOF'
pkgname="live-$CARCH"
pkgver=1
pkgrel=1
arch=("$CARCH")
if [[ $CARCH == aarch64 ]]; then source ./missing-arm.sh; fi
EOF
echo '{"source": "local"}' > "$T/pkgbuilds/broken-arm-include/.omarchy/package.json"
expect_abort 'failure after declaring arch=("$CARCH") stops the plan instead of retiring aarch64' "Cannot read pkgbuilds/broken-arm-include/PKGBUILD for aarch64" --channels "stable" live-aarch64
rm -rf "$T/pkgbuilds/broken-arm-include"

# Even if arch=(x86_64) was declared before a failed aarch64 include (which might
# have added aarch64), a non-zero source status MUST fail closed, never retire ARM.
mkdir -p "$T/pkgbuilds/broken-partial-arch/.omarchy"
cat > "$T/pkgbuilds/broken-partial-arch/PKGBUILD" <<'EOF'
pkgname=partial-arch
pkgver=1
pkgrel=1
arch=(x86_64)
if [[ $CARCH == aarch64 ]]; then source ./missing-arm.sh; fi
EOF
echo '{"source": "local"}' > "$T/pkgbuilds/broken-partial-arch/.omarchy/package.json"
expect_abort "failed include after partial arch=(x86_64) stops the plan instead of retiring aarch64" "Cannot read pkgbuilds/broken-partial-arch/PKGBUILD for aarch64" --channels "stable" partial-arch
rm -rf "$T/pkgbuilds/broken-partial-arch"

# A CARCH-independent recipe declaring arch=(aarch64) followed by return 1 MUST
# fail closed rather than caching a failed x86_64 probe as a valid ARM recipe.
mkdir -p "$T/pkgbuilds/broken-arm-return/.omarchy"
cat > "$T/pkgbuilds/broken-arm-return/PKGBUILD" <<'EOF'
pkgname=broken-arm-return
pkgver=1
pkgrel=1
arch=(aarch64)
return 1
EOF
echo '{"source": "local"}' > "$T/pkgbuilds/broken-arm-return/.omarchy/package.json"
expect_abort "arch=(aarch64) with unconditional return 1 fails closed instead of caching" "Cannot read pkgbuilds/broken-arm-return/PKGBUILD for x86_64" --channels "stable" broken-arm-return
rm -rf "$T/pkgbuilds/broken-arm-return"

# Valid Bash/PKGBUILD semantics: closed stdin, nonfatal ((counter++)), optional include,
# declare in sourced file, default release_ring forms, readonly base=, uppercase pkgbase,
# CARCH/positional-arg safety, and symlinks.
recipe 00-stdin-reader "x86_64 aarch64"
sed -i '1i if read -r _leaked; then return 1; fi' "$T/pkgbuilds/00-stdin-reader/PKGBUILD"
recipe 01-after-reader "x86_64 aarch64" "" after-reader
printf "leaked\n" | plan --channels "stable" after-reader >/dev/null && fail "non-empty stdin reached PKGBUILD"
grep -q "still published to every channel" "$T/err" && pass "recipe sourcing closes stdin even when caller stdin is non-empty" || fail "stdin reader: $(cat "$T/err")"
rm -rf "$T/pkgbuilds/00-stdin-reader" "$T/pkgbuilds/01-after-reader"

mkdir -p "$T/pkgbuilds/sourcing-ok/.omarchy"
printf 'declare pkgbase=from-inc\n' > "$T/pkgbuilds/sourcing-ok/inc.sh"
cat << 'SRC_EOF' > "$T/pkgbuilds/sourcing-ok/PKGBUILD"
counter=0; ((counter++))
readonly base=ignored
source ./missing-optional.sh 2>/dev/null || true
source ./inc.sh
pkgname=("$pkgbase")
pkgver=1
pkgrel=1
arch=(x86_64 aarch64)
SRC_EOF
echo '{"source": "local", "release_ring": ""}' > "$T/pkgbuilds/sourcing-ok/.omarchy/package.json"
recipe ring-null "x86_64 aarch64" '{"source": "local", "release_ring": null}'
recipe ring-false "x86_64 aarch64" '{"source": "local", "release_ring": false}'
pkgbase=wrong-env plan --channels "stable" from-inc >/dev/null && fail "valid sourcing/declare/optional-include recipe was retired"
grep -q "still published to every channel" "$T/err" && pass "builtin sourcing preserves declare scope, optional includes, ((counter++)), default rings, and env isolation" || fail "sourcing-ok: $(cat "$T/err")"
rm -rf "$T/pkgbuilds/sourcing-ok" "$T/pkgbuilds/ring-null" "$T/pkgbuilds/ring-false"

recipe upper-dir "x86_64 aarch64" "" MyApp
plan --channels "stable" MyApp >/dev/null && fail "live uppercase pkgbase MyApp was retired"
grep -q "still published to every channel" "$T/err" && pass "uppercase pkgbase is accepted and kept when live" || fail "uppercase MyApp: $(cat "$T/err")"
rm -rf "$T/pkgbuilds/upper-dir"

recipe carch-mut "aarch64"
sed -i '1i CARCH=aarch64; set -- aarch64' "$T/pkgbuilds/carch-mut/PKGBUILD"
out=$(plan --channels "stable" carch-mut) || fail "carch-mut should retire on x86_64: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == carch-mut && -z $(line RETIRE_STABLE_AARCH64) ]] &&
  pass "PKGBUILD mutating CARCH or positional args does not bypass target architecture matching" || fail "carch-mut: $out"
rm -rf "$T/pkgbuilds/carch-mut"

mkdir -p "$T/pkgbuilds/carch-branch/.omarchy"
cat << 'CARCH_EOF' > "$T/pkgbuilds/carch-branch/PKGBUILD"
if [[ $CARCH == x86_64 ]]; then pkgbase=carch-x86; arch=(x86_64); else pkgbase=carch-arm; arch=(aarch64); fi
pkgname=("$pkgbase"); pkgver=1; pkgrel=1
CARCH_EOF
echo '{"source": "local"}' > "$T/pkgbuilds/carch-branch/.omarchy/package.json"
out=$(plan --channels "stable" carch-x86 carch-arm) || fail "carch-branch plan failed: $(cat "$T/err")"
[[ $(line RETIRE_STABLE_X86_64) == carch-arm && $(line RETIRE_STABLE_AARCH64) == carch-x86 ]] &&
  pass "CARCH-dependent recipe keeps each pkgbase only on its matching architecture" || fail "carch-branch: $out"
rm -rf "$T/pkgbuilds/carch-branch"

ln -s "$T/pkgbuilds" "$T/pkgbuilds-link"
OMARCHY_PKGBUILDS="$T/pkgbuilds-link" "$ROOT/bin/unpublish-plan" --channels "stable" everywhere >/dev/null 2>"$T/err" && fail "symlinked root retired live package"
grep -q "still published to every channel" "$T/err" && pass "symlinked recipe root scans live recipes" || fail "symlink root: $(cat "$T/err")"

ln -s "$T/pkgbuilds/everywhere" "$T/pkgbuilds/everywhere-alias"
plan --channels "stable" everywhere >/dev/null && fail "sibling alias triggered false error"
grep -q "still published to every channel" "$T/err" && pass "sibling alias symlink does not trigger false ambiguity" || fail "alias: $(cat "$T/err")"
rm -f "$T/pkgbuilds/everywhere-alias"

# Table-driven shared-loader fail-closed cases (all must exit non-zero with ZERO RETIRE_* output).
bad_pkgbuilds=(
  "return 1 in PKGBUILD|return 1\npkgname=bad\npkgver=1\npkgrel=1\narch=(x86_64)\n|Cannot read pkgbuilds/bad-case/PKGBUILD"
  "set +e then return 1|pkgname=bad\npkgver=1\npkgrel=1\narch=(x86_64)\nset +e\nreturn 1\n|Cannot read pkgbuilds/bad-case/PKGBUILD"
  "exit 0 in PKGBUILD|pkgname=bad\npkgver=1\npkgrel=1\narch=(x86_64)\nexit 0\n|Cannot read pkgbuilds/bad-case/PKGBUILD"
  "missing arch=()|pkgname=bad\npkgver=1\npkgrel=1\n|Cannot read pkgbuilds/bad-case/PKGBUILD"
  "malformed arch entry|pkgname=bad\npkgver=1\npkgrel=1\narch=(\"x86_64 aarch64\")\n|Cannot read pkgbuilds/bad-case/PKGBUILD"
)
for spec in "${bad_pkgbuilds[@]}"; do
  IFS='|' read -r desc body pat <<<"$spec"
  mkdir -p "$T/pkgbuilds/bad-case/.omarchy"
  # shellcheck disable=SC2059
  printf "$body" > "$T/pkgbuilds/bad-case/PKGBUILD"
  echo '{"source": "local"}' > "$T/pkgbuilds/bad-case/.omarchy/package.json"
  expect_abort "$desc stops the plan with no RETIRE_* output" "$pat" --channels "stable" gone
  rm -rf "$T/pkgbuilds/bad-case"
done

recipe ambig-a "any" "" ambig
recipe ambig-z "x86_64" "" ambig
expect_abort "ambiguous recipes sharing pkgbase and arch stop the plan" "Ambiguous recipes for ambig on x86_64" --channels "stable" gone
rm -rf "$T/pkgbuilds/ambig-a" "$T/pkgbuilds/ambig-z"

for spec in \
  "malformed package.json|{not valid json|bad-json/.omarchy/package.json|invalid or empty metadata" \
  "non-boolean pinned|{\"source\": \"local\", \"pinned\": \"true\"}|bad-json/.omarchy/package.json|invalid pinned" \
  "whitespace-only package.json|   |bad-json/.omarchy/package.json|empty or missing JSON document"; do
  IFS='|' read -r desc body path_pat kind_pat <<<"$spec"
  recipe bad-json "x86_64" "$body"
  out=$(plan --channels "stable" everywhere) && fail "$desc should fail closed"
  [[ -z $out ]] && grep -qE "$path_pat" "$T/err" && grep -qE "$kind_pat" "$T/err" \
    && pass "$desc reports offending path and kind" || fail "$desc: out=$out err=$(cat "$T/err")"
  rm -rf "$T/pkgbuilds/bad-json"
done

ln -s "$T/does-not-exist" "$T/pkgbuilds/dangling"
expect_abort "dangling child symlink stops the plan" "dangling symlink" --channels "stable" everywhere
rm -f "$T/pkgbuilds/dangling"

mkdir -p "$T/pkgbuilds/no-meta" && printf 'pkgname=no-meta\npkgver=1\npkgrel=1\narch=(x86_64)\n' > "$T/pkgbuilds/no-meta/PKGBUILD"
expect_abort "missing .omarchy/package.json stops the plan" "incomplete or unreadable metadata" --channels "stable" everywhere
rm -rf "$T/pkgbuilds/no-meta"

mkdir -p "$T/pkgbuilds/support-only" && echo "# patch" > "$T/pkgbuilds/support-only/fix.patch"
expect_abort "support-files-only directory stops the plan" "missing PKGBUILD" --channels "stable" everywhere
rm -rf "$T/pkgbuilds/support-only"

mkdir -p "$T/failbin" && printf '#!/bin/bash\nexit 42\n' > "$T/failbin/find" && chmod +x "$T/failbin/find"
out=$(PATH="$T/failbin:$PATH" plan --channels "stable" everywhere) && fail "failed scan should fail closed"
[[ -z $out ]] && grep -q "Failed to scan" "$T/err" && pass "failed recipe scan stops the plan with no RETIRE_* output" || fail "failed scan: $out"

out=$(OMARCHY_PKGBUILDS="$T/no-such-pkgbuilds" "$ROOT/bin/unpublish-plan" --channels "stable" everywhere 2>"$T/err") && fail "missing root should fail closed"
[[ -z $out ]] && grep -q "Failed to scan" "$T/err" && pass "missing recipe root stops the plan with no RETIRE_* output" || fail "missing root: $out"

mkdir -p "$T/empty-pkgbuilds"
out=$(OMARCHY_PKGBUILDS="$T/empty-pkgbuilds" "$ROOT/bin/unpublish-plan" --channels "stable" everywhere 2>"$T/err") && fail "empty root should fail closed"
[[ -z $out ]] && grep -q "No recipes found" "$T/err" && pass "empty recipe root stops the plan with no RETIRE_* output" || fail "empty root: $out"
