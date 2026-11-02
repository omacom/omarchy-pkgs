#!/bin/bash
# Self-test for bin/check-mac-set, driven the way promotions drive it: through
# bin/promote-channel (OPR -> RC, whole-channel and fast-ring promotions)
# and through check-mac-set --remote --add (the fast-ring publish at merge),
# on small fixture channels in a local directory standing in for the remote.
# Needs repo-add, gpg, rclone, bsdtar, vercmp (run in the Arch test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf "$T"' EXIT
REMOTE="$T/r2"; mkdir -p "$REMOTE"

export GNUPGHOME="$T/g"; mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Test <t@t>' ed25519 sign 0 2>/dev/null
export GPG_PRIVATE_KEY=$(gpg --batch --armor --export-secret-keys 'Test <t@t>') GPG_PASSPHRASE=''
unset GNUPGHOME

# A copy of the tooling whose pkgbuilds/ and release/ hold the fixtures.
BIN="$T/root/bin"
mkdir -p "$BIN" "$T/root/release"
cp -r "$ROOT/helpers" "$T/root/"
cp "$ROOT/bin/promote-channel" "$ROOT/bin/publish-artifact" "$ROOT/bin/check-mac-set" "$BIN/"
PKGBUILDS_DIR="$T/root/pkgbuilds"
recipe() { # recipe <dir> <metadata json> <arch...>
  local dir=$1 meta=$2; shift 2
  mkdir -p "$PKGBUILDS_DIR/$dir/.omarchy"
  echo "pkgname=$dir arch=($*)" > "$PKGBUILDS_DIR/$dir/PKGBUILD"
  echo "$meta" > "$PKGBUILDS_DIR/$dir/.omarchy/package.json"
}
recipe mac-kernel '{"source": "local"}' aarch64
recipe mac-boot '{"source": "local"}' aarch64
recipe mac-audio '{"source": "local"}' any
recipe mac-new '{"source": "local"}' aarch64
recipe shared-lib '{"source": "local"}' x86_64 aarch64
recipe fast-tool '{"source": "local", "release_ring": "fast"}' x86_64 aarch64
recipe alpha '{"source": "local"}' x86_64 aarch64
cat > "$T/root/release/mac-inventory.txt" <<'EOF'
# fixture
mac-kernel 1.0-1
mac-boot 1.0-1
mac-audio 1.0-1
mac-new none
EOF

# minimal real packages via makepkg; +name is a provides, anything else a
# depends; <name>@<pkgbase> builds it under another pkgbase
mkpkg() { # mkpkg <name>[@pkgbase] <pkgrel> <arch> [dep|+provide...]
  local name=${1%@*} base="" rel=$2 arch=$3 d="$T/src/$1-$2-$3" item deps="" provs=""
  [[ $1 == *@* ]] && base=${1#*@}
  shift 3
  for item in "$@"; do
    if [[ $item == +* ]]; then provs+=" '${item#+}'"; else deps+=" '$item'"; fi
  done
  mkdir -p "$d"; cd "$d"
  { [[ -z $base ]] || printf 'pkgbase=%s\n' "$base"
  printf 'pkgname=%s\npkgver=1.0\npkgrel=%s\narch=(%s)\ndepends=(%s)\nprovides=(%s)\npackage(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s-%s"; }\n' \
    "$name" "$rel" "$arch" "$deps" "$provs" "$name" "$rel"; } > PKGBUILD
  local carch=$arch; [[ $carch == any ]] && carch=x86_64
  if (( EUID == 0 )); then
    id -u fixture >/dev/null 2>&1 || useradd -m fixture
    chmod 755 "$T/src"; chown -R fixture "$d"
    runuser -u fixture -- env CARCH=$carch PKGEXT=.pkg.tar.zst makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  else
    CARCH=$carch PKGEXT=.pkg.tar.zst makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  fi
  cd "$ROOT"
  ls "$d"/*.pkg.tar.zst
}

pub() { # pub <mirror> <arch> <files...>
  local mirror=$1 arch=$2; shift 2
  "$BIN/publish-artifact" --remote "$REMOTE" --mirror "$mirror" --arch "$arch" "$@" >"$T/out" 2>&1 || { cat "$T/out"; exit 1; }
}
promote() { # promote <from> <to> <arch> [flags and pkgbases...]
  local from=$1 to=$2 arch=$3; shift 3
  : > "$T/record"
  "$BIN/promote-channel" --remote "$REMOTE" --from "$from" --to "$to" --arch "$arch" --record "$T/record" "$@" >"$T/out" 2>&1
}
entries() { tar -tf "$REMOTE/$1/$2/omarchy.db.tar.zst" | grep '/$' | tr -d / | sort | tr '\n' ' '; }
mac_result() { jq -r 'select(.type=="mac-set") | .result' "$T/record" | tail -1; }
names() { jq -r 'select(.type=="mac-set") | .problems[].package' "$T/record" | sort -u | tr '\n' ' '; }
says() { jq -e --arg re "$1" 'select(.type=="mac-set") | any(.problems[]; .problem | test($re))' "$T/record" >/dev/null; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; cat "$T/record" 2>/dev/null; exit 1; }

# rc before the candidate: a shared library the Mac set links, a shared
# fast-ring tool it uses, and one x86 package.
pub rc aarch64 $(mkpkg alpha 1 aarch64) $(mkpkg shared-lib 1 aarch64 +libshared.so=1) $(mkpkg fast-tool 1 aarch64 +tool-api=1)
# edge carries the candidate, which matches the inventory.
AUDIO1=$(mkpkg mac-audio 1 any)
pub edge aarch64 $(mkpkg mac-kernel 1 aarch64 'mac-boot>=1.0') $(mkpkg mac-boot 1 aarch64 'shared-lib>=1.0' libshared.so=1 tool-api=1 bash) \
  "$AUDIO1" $(mkpkg alpha 2 aarch64)
pub edge x86_64 "$AUDIO1"

# --- a matching set ----------------------------------------------------------
promote edge rc aarch64 || fail "a whole-channel promotion of the qualified set failed"
[[ $(mac_result) == pass && "$(entries rc aarch64)" == "alpha-1.0-2 fast-tool-1.0-1 mac-audio-1.0-1 mac-boot-1.0-1 mac-kernel-1.0-1 shared-lib-1.0-1 " ]] \
  && jq -e 'select(.type=="mac-set") | .moved == ["mac-audio","mac-boot","mac-kernel"]' "$T/record" >/dev/null \
  && pass "a whole-channel promotion carrying the qualified Mac set passes and publishes" || fail "matching set: $(entries rc aarch64)"

promote edge rc x86_64 || fail "x86_64 promotion of the qualified arch=any package failed"
[[ $(mac_result) == pass && "$(entries rc x86_64)" == "mac-audio-1.0-1 " ]] \
  && pass "the same rule passes the qualified arch=any Mac package on x86_64" || fail "x86_64 matching set: $(entries rc x86_64)"

# --- no Mac change -------------------------------------------------------------
# edge moves on past the candidate; a promotion that leaves the Mac set and
# its dependencies alone behaves as it always has.
pub edge aarch64 $(mkpkg mac-kernel 2 aarch64 'mac-boot>=1.0') $(mkpkg alpha 3 aarch64)
rc_before=$(entries rc aarch64)
promote edge rc aarch64 alpha || fail "a promotion with no Mac change failed"
[[ $(mac_result) == untouched && "$(entries rc aarch64)" == "${rc_before/alpha-1.0-2/alpha-1.0-3}" ]] \
  && ! grep -qi 'refus' "$T/out" \
  && pass "a promotion that touches no Mac package or Mac dependency is unaffected" || fail "no Mac change: $(entries rc aarch64)"

# --- a version mismatch --------------------------------------------------------
rc_before=$(entries rc aarch64)
promote edge rc aarch64 --dry-run || true
[[ $(mac_result) == refused && "$(names)" == "mac-kernel " ]] && says 'mac-kernel would be 1.0-2 in rc; the qualified Mac set has mac-kernel 1.0-1' \
  && grep -q 'mac-kernel would be 1.0-2' "$T/out" \
  && pass "a whole-channel promotion carrying an unqualified Mac version is refused, naming it" || fail "version mismatch"
promote edge rc aarch64 --dry-run mac-kernel || true
[[ $(mac_result) == refused && "$(names)" == "mac-kernel " ]] \
  && pass "an OPR -> RC promotion of the unqualified version alone is refused too" || fail "named version mismatch"

pub edge x86_64 $(mkpkg mac-audio 2 any)
promote edge rc x86_64 --dry-run || true
[[ $(mac_result) == refused && "$(names)" == "mac-audio " ]] \
  && pass "the same rule refuses an unqualified arch=any Mac package on x86_64" || fail "x86_64 mismatch"

# --- a pkgbase mismatch --------------------------------------------------------
pub edge aarch64 $(mkpkg mac-new 1 aarch64)
promote edge rc aarch64 --dry-run mac-new || true
[[ $(mac_result) == refused && "$(names)" == "mac-new " ]] && says 'no qualified version' \
  && pass "a Mac pkgbase the inventory lists as none is refused" || fail "none pkgbase"
# stable gets one Mac pkgbase of the set without the rest.
promote rc stable aarch64 --dry-run mac-kernel || true
[[ $(mac_result) == refused && "$(names)" == "mac-audio mac-boot " ]] && says 'stable/aarch64 would not have it' \
  && pass "moving part of the Mac set is refused, naming the pkgbases the channel would lack" || fail "partial set: $(names)"
promote rc stable aarch64 --dry-run
[[ $(mac_result) == pass ]] && pass "rc -> stable carrying the whole qualified set passes" || fail "rc -> stable"

# --- a dependency-closure break -----------------------------------------------
# A shared package the Mac set depends on moves to a version that no longer
# provides what a Mac package needs. No Mac package moves.
pub edge aarch64 $(mkpkg shared-lib 2 aarch64 +libshared.so=2)
promote edge rc aarch64 --dry-run shared-lib || true
[[ $(mac_result) == refused && "$(names)" == "mac-boot " ]] \
  && says 'mac-boot needs libshared.so=1; rc would offer only libshared.so=2 \(from shared-lib\)' \
  && jq -e 'select(.type=="mac-set") | .moved == []' "$T/record" >/dev/null \
  && pass "a shared package that breaks the Mac set's dependency closure is refused, naming the Mac package" || fail "closure break"

# --- fast-ring publication -----------------------------------------------------
FAST2=$(mkpkg fast-tool 2 aarch64 +tool-api=2)
pub edge aarch64 "$FAST2"
promote edge rc aarch64 --fast-ring --dry-run || true
[[ $(mac_result) == refused && "$(names)" == "mac-boot " ]] && says 'needs tool-api=1' \
  && pass "a fast-ring promotion that breaks the closure is refused" || fail "fast-ring promotion"

: > "$T/record"
if "$BIN/check-mac-set" --remote "$REMOTE" --channel rc --arch aarch64 --record "$T/record" --add "$FAST2" >"$T/out" 2>&1; then
  fail "a fast-ring publish breaking the closure should refuse"
fi
[[ $(mac_result) == refused && "$(names)" == "mac-boot " ]] \
  && pass "the fast-ring publish at merge refuses the same break" || fail "fast-ring publish"
: > "$T/record"
"$BIN/check-mac-set" --remote "$REMOTE" --channel rc --arch aarch64 --record "$T/record" --add $(mkpkg alpha 4 aarch64) >"$T/out" 2>&1 \
  && [[ $(mac_result) == untouched ]] && pass "a fast-ring publish with no Mac change passes untouched" || fail "fast-ring untouched"
: > "$T/record"
"$BIN/check-mac-set" --remote "$REMOTE" --channel rc --arch aarch64 --record "$T/record" --add $(mkpkg fast-tool 3 aarch64 +tool-api=1) >"$T/out" 2>&1 \
  && [[ $(mac_result) == pass ]] && pass "a fast-ring publish that keeps the closure resolving passes" || fail "fast-ring pass"

# The merge publish checks every rc and stable slot before any publishes, as
# publish.yml does: an aarch64 refusal leaves x86_64 as it was too.
X86_ALPHA=$(mkpkg alpha 7 x86_64)
printf 'rc x86_64 %s\nrc aarch64 %s\n' "$X86_ALPHA" "$FAST2" > "$T/slots"
x86_before=$(entries rc x86_64) arm_before=$(entries rc aarch64)
: > "$T/record"
if "$BIN/check-mac-set" --remote "$REMOTE" --slots "$T/slots" --record "$T/record" >"$T/out" 2>&1; then
  pub rc x86_64 "$X86_ALPHA"; pub rc aarch64 "$FAST2"
  fail "a publish with one refused slot should refuse"
fi
[[ "$(jq -r 'select(.type=="mac-set") | .arch + ":" + .result' "$T/record" | tr '\n' ' ')" == "x86_64:untouched aarch64:refused " ]] \
  && [[ "$(entries rc x86_64)" == "$x86_before" && "$(entries rc aarch64)" == "$arm_before" ]] \
  && pass "a merge publish is checked slot by slot before anything publishes; one refusal publishes nothing" || fail "slots: $(cat "$T/record")"
printf 'rc x86_64 %s\n' "$X86_ALPHA" > "$T/slots"
"$BIN/check-mac-set" --remote "$REMOTE" --slots "$T/slots" >"$T/out" 2>&1 \
  && pass "a merge publish whose slots all pass is cleared" || fail "slots pass"

# --- a pkgbase renamed away from the Mac set ------------------------------------
# mac-audio rebuilt under a pkgbase the inventory does not list is still a
# Mac package: the old pkgbase classifies it.
: > "$T/record"
if "$BIN/check-mac-set" --remote "$REMOTE" --channel rc --arch aarch64 --record "$T/record" \
  --add $(mkpkg mac-audio@audio-renamed 2 aarch64) >"$T/out" 2>&1; then
  fail "a Mac package moving to an unlisted pkgbase should refuse"
fi
[[ $(mac_result) == refused && "$(names)" == "mac-audio " ]] \
  && says 'mac-audio would move from Mac pkgbase mac-audio to audio-renamed' \
  && jq -e 'select(.type=="mac-set") | .moved == ["mac-audio"]' "$T/record" >/dev/null \
  && pass "a Mac package rebuilt under an unlisted pkgbase is still checked, and refused" || fail "renamed pkgbase: $(cat "$T/record")"

# --- the inventory itself ------------------------------------------------------
cp "$T/root/release/mac-inventory.txt" "$T/inventory"
echo "mac-kernel 1.0-1" >> "$T/root/release/mac-inventory.txt"
if "$BIN/check-mac-set" --channel rc --arch aarch64 --before "$REMOTE/rc/aarch64/omarchy.db.tar.zst" \
  --after "$REMOTE/rc/aarch64/omarchy.db.tar.zst" >"$T/out" 2>&1; then
  fail "an inventory listing a pkgbase twice should be refused"
else
  [[ $? == 2 ]] && grep -q 'lists mac-kernel twice' "$T/out" && pass "a malformed inventory is a usage error" || fail "duplicate inventory"
fi
cp "$T/inventory" "$T/root/release/mac-inventory.txt"
echo "mac-ghost 1.0-1" >> "$T/root/release/mac-inventory.txt"
: > "$T/record"
if "$BIN/check-mac-set" --remote "$REMOTE" --channel rc --arch aarch64 --record "$T/record" \
  --add $(mkpkg mac-kernel 3 aarch64 'mac-boot>=1.0') >"$T/out" 2>&1; then
  fail "an inventory pkgbase no recipe builds should refuse"
fi
[[ $(mac_result) == refused ]] && says 'the inventory lists mac-ghost, but no recipe on this checkout builds that pkgbase' \
  && pass "an inventory pkgbase no recipe builds is named, with a verdict recorded" || fail "missing recipe"
cp "$T/inventory" "$T/root/release/mac-inventory.txt"
if "$BIN/check-mac-set" --remote "$T/nowhere" --channel rc --arch aarch64 --add "$FAST2" >"$T/out" 2>&1; then
  fail "an unreadable channel should not pass"
else
  [[ $? == 2 ]] && grep -q 'Cannot list' "$T/out" && pass "an unreadable channel fails closed instead of reading as empty" || fail "unreadable remote"
fi

# --- refusing ----------------------------------------------------------------
# A refused check stops the promotion before anything publishes, dry run
# included; the destination stays as it was.
rc_before=$(entries rc aarch64)
if promote edge rc aarch64 mac-kernel; then fail "a mismatched promotion should refuse"; fi
[[ $(mac_result) == refused && "$(entries rc aarch64)" == "$rc_before" ]] \
  && grep -q 'Refusing to promote edge/aarch64 into rc/aarch64: nothing published' "$T/out" \
  && ! jq -e 'select(.type == "slot")' "$T/record" >/dev/null \
  && pass "a promotion the check refuses publishes nothing" || fail "refusal: $(entries rc aarch64)"
if promote edge rc aarch64 --dry-run shared-lib; then fail "a dry run of a refused plan should fail"; fi
pass "a dry run of a refused plan fails, so the workflow can check every architecture first"
if promote edge rc aarch64 --fast-ring; then fail "a refused fast-ring promotion should fail"; fi
[[ "$(entries rc aarch64)" == "$rc_before" ]] && pass "a refused fast-ring promotion publishes nothing" || fail "fast-ring refusal"

# A failure of the check itself refuses too: building the view the plan
# would leave, or running check-mac-set.
pub edge aarch64 $(mkpkg alpha 5 aarch64)
db="$REMOTE/edge/aarch64/omarchy.db.tar.zst"
cp "$db" "$T/edge.db"
mkdir "$T/edge.d" && bsdtar -xf "$db" -C "$T/edge.d"
mv "$T/edge.d/alpha-1.0-5" "$T/edge.d/alpha-entry"
(cd "$T/edge.d" && bsdtar --zstd -cf "$db" *)
rc_before=$(entries rc aarch64)
if promote edge rc aarch64 alpha; then fail "a failure building the Mac view should refuse"; fi
grep -q 'Could not build rc/aarch64 as this plan would leave it; refusing' "$T/out" && [[ "$(entries rc aarch64)" == "$rc_before" ]] \
  && pass "a failure building the view the plan would leave refuses and publishes nothing" || fail "view failure: $(entries rc aarch64)"
cp "$T/edge.db" "$db"

cp "$BIN/check-mac-set" "$T/check-mac-set"
printf '#!/bin/bash\nexit 7\n' > "$BIN/check-mac-set"
if promote edge rc aarch64 alpha; then fail "a crashing check should refuse"; fi
grep -q 'Refusing to promote edge/aarch64 into rc/aarch64: nothing published' "$T/out" && [[ "$(entries rc aarch64)" == "$rc_before" ]] \
  && pass "a check that cannot run refuses and publishes nothing" || fail "check crash: $(entries rc aarch64)"
cp "$T/check-mac-set" "$BIN/check-mac-set"
