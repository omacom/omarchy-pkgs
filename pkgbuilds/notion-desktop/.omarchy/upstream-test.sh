#!/bin/bash
# Offline hook fixtures for notion-desktop, run by bin/sync-upstream self-test.
set -euo pipefail
hook="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/upstream.sh"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

failures=0
check() {
  if [[ "$2" == "$3" ]]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    failures=$((failures + 1))
  fi
}

# Build a synthetic OSTree commit GVariant (a{sv}aya(say)sstayay) containing a
# Notion flatpak path and a big-endian uint64 timestamp, then return its sha256.
make_commit() {
  python3 - "$1" "$2" "$3" << 'PY'
import hashlib, pathlib, struct, sys
out, flatpak, ts = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
# Minimal valid members: 0=a{sv} (empty), 1=ay (empty), 2=a(say) (empty),
# 3=s (subject "\0"), 4=s (body "...\0"), 5=t (8-byte BE aligned to 8),
# 6=ay (32-byte root contents), 7=ay (32-byte root metadata).
buf = bytearray()
off_0 = len(buf)
off_1 = len(buf)
off_2 = len(buf)
buf += b"notion\x00"
off_3 = len(buf)
buf += (flatpak + "\x00").encode()
off_4 = len(buf)
while len(buf) % 8:
    buf += b"\x00"
buf += struct.pack(">Q", ts)
buf += b"\x11" * 32
off_6 = len(buf)
buf += b"\x22" * 32
# 1-byte framing offsets (total size < 256) in reverse order: [off_6, off_4, off_3, off_2, off_1, off_0]
buf += struct.pack("<6B", off_6, off_4, off_3, off_2, off_1, off_0)
assert len(buf) <= 255
out.write_bytes(buf)
print(hashlib.sha256(buf).hexdigest())
PY
}

objs="$fixture_dir/objects"
mkdir -p "$objs"
old_x64=$(make_commit "$objs/old_x64.commit" "/Notion-7.45.2.flatpak" 1795555031)
old_a64=$(make_commit "$objs/old_a64.commit" "/Notion-arm64-7.45.2.flatpak" 1795555031)
new_x64=$(make_commit "$objs/new_x64.commit" "/Notion-7.45.2.flatpak" 1795620557)
new_a64=$(make_commit "$objs/new_a64.commit" "/Notion-arm64-7.45.2.flatpak" 1795620611)
older_x64=$(make_commit "$objs/older_x64.commit" "/Notion-7.45.2.flatpak" 1795500000)
older_a64=$(make_commit "$objs/older_a64.commit" "/Notion-arm64-7.45.2.flatpak" 1795500000)
# Malformed commit with out-of-order framing offsets pointing into the framing table
python3 - "$objs/bad.commit" << 'PY'
import pathlib, struct, sys
body = b"x" * 20 + b"/Notion-7.45.2.flatpak\x00" + b"\x00" * 64 + struct.pack("<6B", 200, 190, 50, 40, 30, 20)
pathlib.Path(sys.argv[1]).write_bytes(body)
PY
bad_sum=$(sha256sum "$objs/bad.commit" | cut -d" " -f1)

mv "$objs/old_x64.commit" "$objs/$old_x64.commit"
mv "$objs/old_a64.commit" "$objs/$old_a64.commit"
mv "$objs/new_x64.commit" "$objs/$new_x64.commit"
mv "$objs/new_a64.commit" "$objs/$new_a64.commit"
mv "$objs/older_x64.commit" "$objs/$older_x64.commit"
mv "$objs/older_a64.commit" "$objs/$older_a64.commit"
mv "$objs/bad.commit" "$objs/$bad_sum.commit"

write_pkgbuild() {
  cat > "$fixture_dir/PKGBUILD" <<PB
pkgver=7.45.2
pkgrel=1
sha256sums_x86_64=('$1')
sha256sums_aarch64=('$2')
PB
}

curl() {
  local out_file="" write_code=0 url=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o) out_file="$2"; shift 2 ;;
      -w) write_code=1; shift 2 ;;
      -*) shift ;;
      *) url="$1"; shift ;;
    esac
  done
  case "$url" in
    *"/refs/heads/app/com.notion.app.desktop.notion/x86_64/stable") printf "%s\n" "$REF_X64" ;;
    *"/refs/heads/app/com.notion.app.desktop.notion/aarch64/stable") printf "%s\n" "$REF_A64" ;;
    *"/objects/"*".commit")
      local id
      id=$(sed -E 's|.*/objects/([0-9a-f]{2})/([0-9a-f]{62})\.commit$|\1\2|' <<<"$url")
      if [[ "$id" == "${PRUNED_ID:-}" ]]; then
        [[ -n "$out_file" ]] && : > "$out_file"
        if (( write_code == 1 )); then printf "403"; fi
        return 0
      fi
      if [[ "$id" == "${TAMPER_ID:-}" ]]; then
        printf "tampered" > "$out_file"
        if (( write_code == 1 )); then printf "200"; fi
        return 0
      fi
      cp "$FIXTURE_OBJS/$id.commit" "$out_file"
      if (( write_code == 1 )); then printf "200"; fi
      ;;
    *) echo "unexpected fixture URL: $url" >&2; return 1 ;;
  esac
}
export -f curl
export FIXTURE_OBJS="$objs" REF_X64 REF_A64 PRUNED_ID TAMPER_ID
PRUNED_ID="" TAMPER_ID=""

cd "$fixture_dir"
echo "Notion Desktop release hook:"

# 1. Unchanged pin -> {}
write_pkgbuild "$old_x64" "$old_a64"
REF_X64="$old_x64" REF_A64="$old_a64"
out=$(bash "$hook")
check "unchanged pin emits empty JSON" "{}" "$out"

# 2. Newer republish at same pkgver -> pkgrel=2
REF_X64="$new_x64" REF_A64="$new_a64"
out=$(bash "$hook")
check "newer republish bumps pkgrel" "2" "$(jq -r .pkgrel <<<"$out")"
check "newer republish updates x86_64 commit" "$new_x64" "$(jq -r .sha256sums.x86_64[0] <<<"$out")"
check "newer republish updates aarch64 commit" "$new_a64" "$(jq -r .sha256sums.aarch64[0] <<<"$out")"

# 3. Older timestamp rollback -> skipped ({})
REF_X64="$older_x64" REF_A64="$older_a64"
out=$(bash "$hook" 2>/dev/null)
check "older timestamp rollback is skipped" "{}" "$out"

# 4. Pruned pinned aarch64 commit (HTTP 403) -> allowed to advance to live commit
REF_X64="$new_x64" REF_A64="$new_a64" PRUNED_ID="$old_a64"
out=$(bash "$hook")
check "pruned pin advances pkgrel" "2" "$(jq -r .pkgrel <<<"$out")"
PRUNED_ID=""

# 5. Tampered old commit object on HTTP 200 -> fails closed
REF_X64="$new_x64" REF_A64="$new_a64" TAMPER_ID="$old_x64"
st=0; bash "$hook" >/dev/null 2>&1 || st=$?
check "tampered pinned commit fails closed" "1" "$([[ $st != 0 ]] && echo 1 || echo 0)"
TAMPER_ID=""

# 6. Malformed GVariant framing offsets -> fails closed
REF_X64="$bad_sum" REF_A64="$bad_sum"
st=0; bash "$hook" >/dev/null 2>&1 || st=$?
check "malformed GVariant framing fails closed" "1" "$([[ $st != 0 ]] && echo 1 || echo 0)"

[[ "$failures" == 0 ]]
