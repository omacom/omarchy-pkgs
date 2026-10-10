#!/bin/bash
# Advisory files sit beside the package archive and travel with it.
set -euo pipefail

ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=../helpers/advisory-helpers.sh
source "$ROOT/helpers/advisory-helpers.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

got=$(advisory_path_for_package_file "$T" "mise-bin-1.0.0-1-x86_64.pkg.tar.zst")
[[ "$got" == "$T/mise-bin-1.0.0-1-x86_64.advisory.json" ]] || {
  echo "advisory path should sit beside the package, got $got" >&2
  exit 1
}
[[ "$(advisory_artifact_name mise-bin 1.0.0 1 x86_64)" == "mise-bin-1.0.0-1-x86_64.advisory.json" ]] || {
  echo "advisory filename must name the artifact and say advisory" >&2
  exit 1
}

export OMARCHY_REPO_ROOT="$T/repo"
export OMARCHY_BUILD_OUTPUT_DIR="$T/build-output"
mkdir -p "$OMARCHY_BUILD_OUTPUT_DIR" "$OMARCHY_REPO_ROOT/edge/x86_64"
pkg="demo-1.0.0-1-x86_64.pkg.tar.zst"
printf 'package\n' >"$OMARCHY_BUILD_OUTPUT_DIR/$pkg"
printf 'sig\n' >"$OMARCHY_BUILD_OUTPUT_DIR/$pkg.sig"
printf 'advisory-v1\n' >"$OMARCHY_BUILD_OUTPUT_DIR/${pkg%.pkg.tar.zst}.advisory.json"
printf 'advisory-sig\n' >"$OMARCHY_BUILD_OUTPUT_DIR/${pkg%.pkg.tar.zst}.advisory.json.sig"

"$ROOT/bin/promote-build" --mirror edge --arch x86_64 >/dev/null
repo_pkg="$OMARCHY_REPO_ROOT/edge/x86_64/$pkg"
[[ -f "$repo_pkg" ]] || {
  echo "promote did not move the package" >&2
  exit 1
}
[[ -f "${repo_pkg%.pkg.tar.zst}.advisory.json" ]] || {
  echo "promote did not move the advisory beside the package" >&2
  exit 1
}
[[ -f "${repo_pkg%.pkg.tar.zst}.advisory.json.sig" ]] || {
  echo "promote did not move the advisory signature" >&2
  exit 1
}
[[ ! -e "$OMARCHY_BUILD_OUTPUT_DIR/${pkg%.pkg.tar.zst}.advisory.json" ]] || {
  echo "promote left the advisory in build output" >&2
  exit 1
}

# A second promote of the same package bytes still replaces the advisory.
printf 'package\n' >"$OMARCHY_BUILD_OUTPUT_DIR/$pkg"
printf 'sig\n' >"$OMARCHY_BUILD_OUTPUT_DIR/$pkg.sig"
printf 'advisory-v2\n' >"$OMARCHY_BUILD_OUTPUT_DIR/${pkg%.pkg.tar.zst}.advisory.json"
"$ROOT/bin/promote-build" --mirror edge --arch x86_64 >/dev/null
[[ "$(cat "${repo_pkg%.pkg.tar.zst}.advisory.json")" == "advisory-v2" ]] || {
  echo "promote kept a stale advisory for an identical package" >&2
  exit 1
}

# Channel advance copies the advisory with the package.
edge="$OMARCHY_REPO_ROOT/edge/x86_64"
mkdir -p "$edge/demo"
cat >"$edge/demo/desc" <<EOF
%FILENAME%
$pkg
%NAME%
demo
%BASE%
demo
%VERSION%
1.0.0-1
EOF
tar -C "$edge" -cf "$edge/omarchy.db.tar.zst" demo
out=$("$ROOT/bin/advance-channel" --from edge --to rc --arch x86_64 --dry-run)
grep -q "would copy advisory: ${pkg%.pkg.tar.zst}.advisory.json" <<<"$out" || {
  echo "advance did not offer to copy the advisory" >&2
  echo "$out" >&2
  exit 1
}

# Cleaning an old package version removes its advisory and leaves the new one.
mkdir -p "$edge"
old="demo-1.0.0-1-x86_64.pkg.tar.zst"
new="demo-2.0.0-1-x86_64.pkg.tar.zst"
printf 'old\n' >"$edge/$old"
printf 'new\n' >"$edge/$new"
printf 'old-adv\n' >"$edge/${old%.pkg.tar.zst}.advisory.json"
printf 'new-adv\n' >"$edge/${new%.pkg.tar.zst}.advisory.json"
touch -d '2020-01-01' "$edge/$old" "$edge/${old%.pkg.tar.zst}.advisory.json"
touch -d '2026-01-01' "$edge/$new" "$edge/${new%.pkg.tar.zst}.advisory.json"
"$ROOT/bin/clean-repo" --mirror edge --arch x86_64 --keep 1 >/dev/null
[[ ! -e "$edge/$old" && ! -e "$edge/${old%.pkg.tar.zst}.advisory.json" ]] || {
  echo "clean left an old package or its advisory" >&2
  exit 1
}
[[ -f "$edge/$new" && -f "$edge/${new%.pkg.tar.zst}.advisory.json" ]] || {
  echo "clean removed the kept package or its advisory" >&2
  exit 1
}

# A refresh upload overwrites advisory files. The package upload does not.
stub="$T/bin"
mkdir -p "$stub"
cat >"$stub/rclone" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${RCLONE_LOG:?}"
[[ "$1" == "lsf" ]] && exit 3
exit 0
EOF
chmod +x "$stub/rclone"
export RCLONE_LOG="$T/rclone.log"
export PATH="$stub:$PATH"
printf 'pkg\n' >"$edge/demo-3.0.0-1-x86_64.pkg.tar.zst"
printf 'adv\n' >"$edge/demo-3.0.0-1-x86_64.advisory.json"
"$ROOT/bin/sync-repo" --mirror edge --arch x86_64 --remote "$T/remote" --skip-prod-check >/dev/null
pkg_copy=$(grep -n 'exclude \*\.advisory\.json' "$RCLONE_LOG" | head -1 || true)
adv_copy=$(grep -n 'include \*\.advisory\.json' "$RCLONE_LOG" | head -1 || true)
[[ -n "$pkg_copy" && -n "$adv_copy" ]] || {
  echo "sync-repo did not split the package upload from the advisory upload" >&2
  cat "$RCLONE_LOG" >&2
  exit 1
}
pkg_line=${pkg_copy%%:*}
adv_line=${adv_copy%%:*}
[[ "$adv_line" -gt "$pkg_line" ]] || {
  echo "advisory upload must follow the package upload" >&2
  exit 1
}
adv_args=$(sed -n "${adv_line}p" "$RCLONE_LOG")
grep -q -- '--checksum' <<<"$adv_args" || {
  echo "advisory upload must overwrite with --checksum" >&2
  echo "$adv_args" >&2
  exit 1
}
grep -q -- '--ignore-existing' <<<"$adv_args" && {
  echo "advisory upload must not use --ignore-existing" >&2
  exit 1
}

echo "PASS: advisory sidecars sit beside packages and follow promote, advance, clean, and sync"
