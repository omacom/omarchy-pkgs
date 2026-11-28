#!/bin/bash
# Notion ships its desktop app as a Flatpak from its own OSTree repository.
# Each architecture's ref names the current commit, and an OSTree commit id is
# the SHA-256 of its commit object, so the commit ids are the PKGBUILD's
# checksums. The version appears only in the commit body, which names the
# Flatpak bundle it was exported from ("Notion-7.41.1.flatpak"), so an update
# costs two small requests per architecture instead of a 150 MB pull.
#
# Upstream occasionally republishes signed OSTree commits at the same app
# version and prunes the previous commit object. When commits change at the
# checked-in pkgver, verify the new commit timestamp is strictly newer (or the
# pinned commit has been pruned) and emit the next pkgrel so sync-upstream
# advances off dead commits without silently accepting rollbacks.
set -euo pipefail

REMOTE="https://app.linux-packages.notion.com"
APP_ID="com.notion.app.desktop.notion"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Parse the big-endian uint64 timestamp from an OSTree commit GVariant
# (a{sv}aya(say)sstayay). Framing offsets at the end are stored in reverse
# order for variable-sized non-final members (indices 0,1,2,3,4,6); index 4
# is the body string, and the fixed 8-byte timestamp sits immediately after it,
# aligned to an 8-byte boundary.
ostree_commit_timestamp() {
  python3 - "$1" << 'PY'
import pathlib, struct, sys
b = pathlib.Path(sys.argv[1]).read_bytes()
n = len(b)
if n < 32:
    raise SystemExit("commit object too short")
w = 1 if n <= 0xFF else (2 if n <= 0xFFFF else 4)
fmt = {1: "<B", 2: "<H", 4: "<I"}[w]
# Last 6 framing offsets (reverse order): [off_6, off_4, off_3, off_2, off_1, off_0]
table_start = n - 6 * w
if table_start < 16:
    raise SystemExit("commit object too short for framing table")
off_6, off_4, off_3, off_2, off_1, off_0 = struct.unpack_from("<" + fmt[1] * 6, b, table_start)
if not (0 <= off_0 <= off_1 <= off_2 <= off_3 <= off_4 <= table_start):
    raise SystemExit("invalid GVariant framing offsets")
ts_off = (off_4 + 7) & ~7
if ts_off + 8 > off_6 or off_6 > table_start:
    raise SystemExit("commit timestamp out of bounds")
ts = struct.unpack_from(">Q", b, ts_off)[0]
if not (1500000000 <= ts < (1 << 62)):
    raise SystemExit(f"implausible commit timestamp: {ts}")
print(ts)
PY
}

versions=()
declare -A commits=()
declare -A timestamps=()

for arch in x86_64 aarch64; do
  commit=$(curl -fsSL "$REMOTE/refs/heads/app/$APP_ID/$arch/stable" | tr -d '[:space:]')
  if [[ ! "$commit" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Unexpected $arch ref in the upstream repository: $commit" >&2
    exit 1
  fi

  curl -fsSL -o "$tmp/$arch.commit" "$REMOTE/objects/${commit:0:2}/${commit:2}.commit"
  if [[ "$(sha256sum "$tmp/$arch.commit" | cut -d' ' -f1)" != "$commit" ]]; then
    echo "The $arch commit object does not hash to its id $commit" >&2
    exit 1
  fi

  # The bundle name is the only version upstream records; a new layout has to
  # stop the sync rather than guess.
  version=$(grep -aoE "/Notion-(arm64-)?[0-9]+(\.[0-9]+)+\.flatpak" "$tmp/$arch.commit" |
    sed -E 's|^/Notion-(arm64-)?||; s|\.flatpak$||' | sort -u)
  if [[ -z "$version" || "$version" == *$'\n'* ]]; then
    echo "Could not read one version from the $arch commit body" >&2
    exit 1
  fi

  versions+=("$version")
  commits[$arch]="$commit"
  timestamps[$arch]=$(ostree_commit_timestamp "$tmp/$arch.commit")
done

# A release lands one architecture at a time, and a single pkgver has to cover
# both. Report no update until they agree; the next run picks it up.
if [[ "${versions[0]}" != "${versions[1]}" ]]; then
  echo "Upstream architectures are mid-release (${versions[*]}); skipping" >&2
  echo '{}'
  exit 0
fi

current_pkgver=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2- | tr -d "\"'")
current_pkgrel=$(grep -m1 '^pkgrel=' PKGBUILD | cut -d= -f2- | tr -d "\"'")

if [[ "${versions[0]}" == "$current_pkgver" ]]; then
  read -r current_x86_64 current_aarch64 < <(
    bash -c 'source "$1" >/dev/null 2>&1 && printf "%s %s\n" "${sha256sums_x86_64[0]:-}" "${sha256sums_aarch64[0]:-}"' _ ./PKGBUILD
  )
  declare -A current_commits=(
    [x86_64]="$current_x86_64"
    [aarch64]="$current_aarch64"
  )

  if [[ "${commits[x86_64]}" == "${current_commits[x86_64]}" && "${commits[aarch64]}" == "${current_commits[aarch64]}" ]]; then
    echo '{}'
    exit 0
  fi

  for arch in x86_64 aarch64; do
    old="${current_commits[$arch]}"
    new="${commits[$arch]}"
    [[ "$old" != "$new" ]] || continue
    [[ "$old" =~ ^[0-9a-f]{64}$ ]] || continue

    old_code=$(curl -sSL -o "$tmp/old-$arch.commit" -w '%{http_code}' \
      "$REMOTE/objects/${old:0:2}/${old:2}.commit")
    if [[ "$old_code" == "200" ]]; then
      if [[ "$(sha256sum "$tmp/old-$arch.commit" | cut -d' ' -f1)" != "$old" ]]; then
        echo "Pinned $arch commit object does not hash to its id $old" >&2
        exit 1
      fi
      old_ts=$(ostree_commit_timestamp "$tmp/old-$arch.commit")
      if (( timestamps[$arch] <= old_ts )); then
        echo "Upstream $arch commit $new (ts=${timestamps[$arch]}) is not newer than checked-in $old (ts=$old_ts); skipping" >&2
        echo '{}'
        exit 0
      fi
    elif [[ "$old_code" != "403" && "$old_code" != "404" ]]; then
      echo "Could not check pinned $arch commit $old (HTTP $old_code)" >&2
      exit 1
    fi
  done

  next_pkgrel=$(( ${current_pkgrel%%.*} + 1 ))
  jq -n \
    --arg pkgver "${versions[0]}" \
    --arg pkgrel "$next_pkgrel" \
    --arg x86_64 "${commits[x86_64]}" \
    --arg aarch64 "${commits[aarch64]}" \
    '{pkgver: $pkgver, pkgrel: $pkgrel, sha256sums: {x86_64: [$x86_64], aarch64: [$aarch64]}}'
  exit 0
fi

jq -n \
  --arg pkgver "${versions[0]}" \
  --arg x86_64 "${commits[x86_64]}" \
  --arg aarch64 "${commits[aarch64]}" \
  '{pkgver: $pkgver, sha256sums: {x86_64: [$x86_64], aarch64: [$aarch64]}}'
