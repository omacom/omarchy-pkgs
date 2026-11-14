#!/bin/bash
# Self-test for bin/promote-channel against a local directory as the remote.
# Needs repo-add, gpg, rclone, bsdtar, vercmp (run in the Arch test container).
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
T=$(mktemp -d); chmod 755 "$T"; trap 'rm -rf "$T"' EXIT
REMOTE="$T/r2"; mkdir -p "$REMOTE"
# The rc snapshot of Arch the checks resolve against; empty until the cases
# that need it, so promote-channel never fetches the real one.
export OMARCHY_ARCH_SNAPSHOT="$T/arch"; mkdir -p "$OMARCHY_ARCH_SNAPSHOT"

# throwaway signing key
export GNUPGHOME="$T/g"; mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Test <t@t>' ed25519 sign 0 2>/dev/null
export GPG_PRIVATE_KEY=$(gpg --batch --armor --export-secret-keys 'Test <t@t>') GPG_PASSPHRASE=''
unset GNUPGHOME

# The tooling reads recipes from its own checkout (helpers/paths.sh), so run
# a copy of it whose pkgbuilds/ holds the fixtures.
BIN="$T/root/bin"
mkdir -p "$BIN"
cp -r "$ROOT/helpers" "$T/root/"
cp -r "$ROOT/release" "$T/root/"
cp "$ROOT/bin/promote-channel" "$ROOT/bin/publish-artifact" "$ROOT/bin/check-mac-set" "$ROOT/bin/check-channel-deps" "$BIN/"
PKGBUILDS_DIR="$T/root/pkgbuilds"
recipe() { # recipe <dir> <metadata json> [pkgbase] [arch]
  mkdir -p "$PKGBUILDS_DIR/$1/.omarchy"
  echo "${3:+pkgbase=$3 }pkgname=$1 arch=(${4:-x86_64})" > "$PKGBUILDS_DIR/$1/PKGBUILD"
  echo "$2" > "$PKGBUILDS_DIR/$1/.omarchy/package.json"
}
recipe alpha '{"source": "local"}'
# A directory need not be named after the pkgbase it builds.
recipe split-recipe '{"source": "local"}' split
recipe fast '{"source": "local", "release_ring": "fast"}'
recipe pinned '{"source": "local", "pinned": true}'
recipe ahead '{"source": "local"}'
recipe big '{"source": "local"}'
# Built for x86_64 once; the recipe has since dropped it.
recipe dropped '{"source": "local"}' "" aarch64

# minimal real packages via makepkg; a second name makes a split package, and
# DEPENDS and PROVIDES give a single package its depends and provides
mkpkg() { # [DEPENDS=...] [PROVIDES=...] mkpkg <base> <pkgrel> [second pkgname]
  local d="$T/src/$1-$2"; mkdir -p "$d"; cd "$d"
  {
    if [[ -n ${3:-} ]]; then
      printf 'pkgbase=%s\npkgname=(%s %s)\n' "$1" "$1" "$3"
      printf 'package_%s(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s"; }\n' "$1" "$1"
      printf 'package_%s(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s"; }\n' "$3" "$3"
    else
      printf 'pkgname=%s\npackage(){ install -Dm644 /dev/null "$pkgdir/usr/share/%s-%s"; }\n' "$1" "$1" "$2"
      # Quoted: a bare > in a version constraint would be a redirection.
      printf 'depends=('; for dep in ${DEPENDS:-}; do printf "'%s' " "$dep"; done; printf ')\n'
      printf 'provides=('; for prov in ${PROVIDES:-}; do printf "'%s' " "$prov"; done; printf ')\n'
    fi
    printf 'pkgver=1.0\npkgrel=%s\narch=(x86_64)\n' "$2"
  } > PKGBUILD
  if (( EUID == 0 )); then
    id -u fixture >/dev/null 2>&1 || useradd -m fixture
    chmod 755 "$T/src"; chown -R fixture "$d"
    runuser -u fixture -- env CARCH=x86_64 PKGEXT=.pkg.tar.zst makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  else
    CARCH=x86_64 PKGEXT=.pkg.tar.zst makepkg -f --nodeps --ignorearch >/dev/null 2>&1
  fi
  ls "$d"/*.pkg.tar.zst
}

pub() { # pub <mirror> <files...>
  local mirror=$1; shift
  "$BIN/publish-artifact" --remote "$REMOTE" --mirror "$mirror" --arch x86_64 "$@" >"$T/out" 2>&1 || { cat "$T/out"; exit 1; }
}
promote() { "$BIN/promote-channel" --remote "$REMOTE" --from edge --to rc --arch x86_64 --record "$T/record" "$@" >"$T/out" 2>&1; }
entries() { tar -tf "$REMOTE/$1/x86_64/omarchy.db.tar.zst" | grep '/$' | tr -d / | sort | tr '\n' ' '; }
plan_action() { jq -r --arg n "$1" 'select(.type=="plan" and .name==$n) | .action' "$T/record" | tail -1; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; cat "$T/out"; exit 1; }

# rc: what stable users have now. edge: newer builds of most of it.
pub rc $(mkpkg alpha 1) $(mkpkg fast 1) $(mkpkg pinned 1) $(mkpkg ahead 3)
pub edge $(mkpkg alpha 2) $(mkpkg split 1 split-extra) $(mkpkg fast 2) $(mkpkg pinned 2) \
  $(mkpkg ahead 2) $(mkpkg big 1) $(mkpkg dropped 1)
rc_before=$(entries rc)

: > "$T/record"
promote --dry-run && [[ "$(entries rc)" == "$rc_before" ]] \
  && [[ $(plan_action alpha) == promote && $(plan_action split-extra) == promote ]] \
  && pass "dry run plans the promotion and publishes nothing" || fail "dry run"

: > "$T/record"
promote || fail "promotion failed"
[[ "$(entries rc)" == "ahead-1.0-3 alpha-1.0-2 big-1.0-1 fast-1.0-1 pinned-1.0-1 split-1.0-1 split-extra-1.0-1 " ]] \
  && pass "newer and missing packages reach rc; nothing else changes" || fail "rc entries: $(entries rc)"

[[ $(plan_action fast) == hold && $(plan_action pinned) == hold && $(plan_action ahead) == hold ]] \
  && jq -e 'select(.name=="pinned") | .reason | test("pinned")' "$T/record" >/dev/null \
  && jq -e 'select(.name=="ahead") | .reason | test("rc is ahead")' "$T/record" >/dev/null \
  && jq -e 'select(.name=="dropped") | .reason | test("no longer builds for x86_64")' "$T/record" >/dev/null \
  && pass "fast ring, pinned, rc-ahead and dropped-arch packages are held back, each with its reason" || fail "hold reasons"

cmp -s "$REMOTE/edge/x86_64/alpha-1.0-2-x86_64.pkg.tar.zst" "$REMOTE/rc/x86_64/alpha-1.0-2-x86_64.pkg.tar.zst" \
  && [[ -f "$REMOTE/rc/x86_64/alpha-1.0-2-x86_64.pkg.tar.zst.sig" ]] \
  && pass "rc serves the same bytes edge does, signed" || fail "promoted bytes differ"

jq -e -s '[.[] | select(.type=="slot")] | length == 1 and .[0].status == "published" and (.[0].packages | index("split-extra-1.0-1-x86_64"))' "$T/record" >/dev/null \
  && pass "the record names every published package in its slot" || fail "slot record: $(cat "$T/record")"

: > "$T/record"
promote && grep -q 'already up to date' "$T/out" && [[ $(plan_action alpha) == current ]] \
  && pass "a second run finds nothing to do" || fail "rerun"

# Batches split between pkgbases, never inside one; each batch is a slot.
pub edge $(mkpkg alpha 3) $(mkpkg split 2 split-extra) $(mkpkg big 2)
: > "$T/record"
promote --batch-bytes 1 || fail "batched promotion failed"
jq -e -s '[.[] | select(.type=="slot")] | length == 3 and all(.status == "published")' "$T/record" >/dev/null \
  && jq -e -s '[.[] | select(.type=="slot") | .packages | select(index("split-1.0-2-x86_64"))] | length == 1 and (.[0] | index("split-extra-1.0-2-x86_64"))' "$T/record" >/dev/null \
  && [[ "$(entries rc)" == "ahead-1.0-3 alpha-1.0-3 big-1.0-2 fast-1.0-1 pinned-1.0-1 split-1.0-2 split-extra-1.0-2 " ]] \
  && pass "small batches publish base by base and keep split packages together" || fail "batches: $(cat "$T/record")"

# A named pkgbase limits the run to it.
pub edge $(mkpkg alpha 4) $(mkpkg big 3)
: > "$T/record"
promote alpha && [[ "$(entries rc)" == "ahead-1.0-3 alpha-1.0-4 big-1.0-2 fast-1.0-1 pinned-1.0-1 split-1.0-2 split-extra-1.0-2 " ]] \
  && pass "naming a pkgbase promotes only that one" || fail "named promotion: $(entries rc)"
if promote nosuch; then fail "an unknown pkgbase should refuse"; else grep -q 'not a pkgbase in edge/x86_64 or a recipe' "$T/out" && pass "an unknown pkgbase is refused" || fail "unknown pkgbase reason"; fi
recipe elsewhere '{"source": "local"}'
promote elsewhere && grep -q 'not in edge/x86_64; skipping' "$T/out" \
  && pass "a recipe this architecture has not published is skipped, not refused" || fail "other-arch recipe"

# A source file that does not match its database entry is never published.
f="$REMOTE/edge/x86_64/big-1.0-3-x86_64.pkg.tar.zst"
cp "$f" "$T/good"; echo tampered >> "$f"
: > "$T/record"
if promote big; then fail "a corrupt source file should refuse"; else
  grep -q 'does not match its database entry' "$T/out" && [[ "$(entries rc)" == *"big-1.0-2 "* ]] \
    && jq -e -s '[.[] | select(.type=="slot")] | .[0].status == "failed"' "$T/record" >/dev/null \
    && pass "a corrupt source file fails its slot and leaves rc alone" || fail "corrupt source"
fi
cp "$T/good" "$f"

if "$BIN/promote-channel" --remote "$REMOTE" --from edge --to stable --arch x86_64 >"$T/out" 2>&1; then
  fail "edge -> stable should refuse"
else grep -q 'refusing edge -> stable' "$T/out" && pass "channels only move one step forward" || fail "direction reason"; fi

# rc -> stable: pinned packages move there (stable gets the release pair by
# promotion); fast-ring ones are published at merge.
: > "$T/record"
"$BIN/promote-channel" --remote "$REMOTE" --from rc --to stable --arch x86_64 --record "$T/record" >"$T/out" 2>&1 || fail "rc -> stable"
[[ $(plan_action pinned) == promote && $(plan_action fast) == hold ]] && [[ "$(entries stable)" == *"pinned-1.0-1 "* ]] \
  && pass "rc -> stable carries the pinned pair and holds the fast ring" || fail "stable promotion: $(entries stable)"

# --fast-ring: rc and stable catch up with edge for fast-ring packages only,
# from edge directly.
fastring() { "$BIN/promote-channel" --remote "$REMOTE" --fast-ring --from edge --arch x86_64 --record "$T/record" "$@" >"$T/out" 2>&1; }
: > "$T/record"
fastring --to rc || fail "fast-ring sync to rc"
[[ $(plan_action fast) == promote && $(plan_action alpha) == hold ]] && [[ "$(entries rc)" == *"fast-1.0-2 "* ]] \
  && jq -e 'select(.name=="alpha") | .reason == "not on the fast ring"' "$T/record" >/dev/null \
  && cmp -s "$REMOTE/edge/x86_64/fast-1.0-2-x86_64.pkg.tar.zst" "$REMOTE/rc/x86_64/fast-1.0-2-x86_64.pkg.tar.zst" \
  && pass "--fast-ring brings rc in line with edge, fast-ring packages only" || fail "fast-ring rc: $(entries rc)"
: > "$T/record"
fastring --to stable && [[ "$(entries stable)" == *"fast-1.0-2 "* ]] && [[ $(plan_action alpha) == hold ]] \
  && pass "--fast-ring goes from edge straight to stable" || fail "fast-ring stable: $(entries stable)"
: > "$T/record"
fastring --to rc && [[ $(plan_action fast) == current ]] && pass "--fast-ring is a no-op once the channels agree" || fail "fast-ring rerun"
if "$BIN/promote-channel" --remote "$REMOTE" --fast-ring --from rc --to stable --arch x86_64 >"$T/out" 2>&1; then
  fail "--fast-ring from rc should refuse"
else grep -q 'fast ring follows edge' "$T/out" && pass "--fast-ring only follows edge" || fail "fast-ring direction reason"; fi

# A package whose new version needs one the promotion leaves behind is
# refused, and so is one that moves away from a version a package staying
# behind needs; pacman says why.
recipe kern '{"source": "local"}'
recipe trees '{"source": "local"}'
recipe mods '{"source": "local"}'
pub rc $(mkpkg kern 1) $(DEPENDS=kern=1.0-1 mkpkg mods 1)
pub edge $(DEPENDS=trees mkpkg kern 2) $(mkpkg trees 1) $(DEPENDS=kern=1.0-2 mkpkg mods 2)
rc_before=$(entries rc)
: > "$T/record"
if promote kern; then fail "kern without trees should refuse"; else
  grep -q "kern: unable to satisfy dependency 'trees' required by kern" "$T/out" \
    && grep -q "mods: unable to satisfy dependency 'kern=1.0-1' required by mods" "$T/out" \
    && grep -q 'nothing published' "$T/out" && [[ "$(entries rc)" == "$rc_before" ]] \
    && jq -e -s '[.[] | select(.type=="deps")] | length == 1 and .[0].result == "refused" and ([.[0].problems[].package] | sort == ["kern", "mods"])' "$T/record" >/dev/null \
    && pass "a package does not move without one it newly depends on, or away from one that needs its old version" || fail "unmet dependency refusal"
fi
: > "$T/record"
if promote kern trees --dry-run; then fail "kern without mods should refuse, dry run included"; else
  grep -q "mods: unable to satisfy dependency 'kern=1.0-1'" "$T/out" && ! grep -q "required by kern" "$T/out" \
    && pass "the dry run refuses the same way and names only what is still missing" || fail "dry-run refusal"
fi
# Small batches still publish them in one database update: kern needs trees,
# and mods needs kern.
: > "$T/record"
promote --batch-bytes 1 kern trees mods && [[ "$(entries rc)" == *"kern-1.0-2 mods-1.0-2 "*"trees-1.0-1 "* ]] \
  && jq -e -s '[.[] | select(.type=="deps")] | .[0].result == "pass"' "$T/record" >/dev/null \
  && jq -e -s '[.[] | select(.type=="slot")] | length == 1 and (.[0].packages | sort == ["kern-1.0-2-x86_64", "mods-1.0-2-x86_64", "trees-1.0-1-x86_64"])' "$T/record" >/dev/null \
  && pass "named together, they move together, in one database update however small the batches" || fail "kern with trees and mods: $(entries rc) $(jq -c 'select(.type=="slot")' "$T/record")"
# A package with no depends of its own still links what it provides:
# vapp needs the vapi that vlib provides, so they share a batch.
recipe vlib '{"source": "local"}'
recipe vapp '{"source": "local"}'
pub edge $(PROVIDES=vapi mkpkg vlib 1) $(DEPENDS=vapi mkpkg vapp 1)
: > "$T/record"
promote --batch-bytes 1 vlib vapp \
  && jq -e -s '[.[] | select(.type=="slot")] | length == 1 and (.[0].packages | sort == ["vapp-1.0-1-x86_64", "vlib-1.0-1-x86_64"])' "$T/record" >/dev/null \
  && pass "a package with no depends keeps its provides, so what needs them shares its batch" || fail "provides without depends: $(jq -c 'select(.type=="slot")' "$T/record")"

# A package already not installable in rc does not block a promotion it
# depends on; it is reported and recorded as existing.
recipe stale '{"source": "local"}'
pub rc $(DEPENDS="gone alpha" mkpkg stale 1)
pub edge $(mkpkg gone 1) $(mkpkg alpha 5)
: > "$T/record"
promote alpha && [[ "$(entries rc)" == *"alpha-1.0-5 "* ]] && grep -q "stale: unable to satisfy dependency 'gone' required by stale" "$T/out" \
  && grep -q 'resolves the 2 package(s)' "$T/out" \
  && jq -e -s '[.[] | select(.type=="deps")] | .[0].result == "pass" and .[0].existing[0].package == "stale"' "$T/record" >/dev/null \
  && pass "a package rc already could not install is reported, not held against the promotion, and only alpha and stale are checked" || fail "existing breakage: $(cat "$T/out")"

# A package already broken is excused only for the reasons it already had:
# old2 lacked gone2 before, and promoting beta also takes away the beta it
# pins, so the promotion is refused and names only the new reason.
recipe beta '{"source": "local"}'
recipe old2 '{"source": "local"}'
pub rc $(mkpkg beta 1) $(DEPENDS="gone2 beta=1.0-1" mkpkg old2 1)
pub edge $(mkpkg beta 2)
rc_before=$(entries rc)
: > "$T/record"
if promote beta; then fail "a package that gains a reason to fail should refuse"; else
  grep -q "old2: unable to satisfy dependency 'beta=1.0-1' required by old2" "$T/out" && [[ "$(entries rc)" == "$rc_before" ]] \
    && jq -e -s '[.[] | select(.type=="deps")] | .[0].result == "refused" and .[0].problems == [{"package": "old2", "problem": "unable to satisfy dependency '"'"'beta=1.0-1'"'"' required by old2"}]' "$T/record" >/dev/null \
    && pass "a package already broken is excused only for the reasons it already had" || fail "gained reason: $(cat "$T/out")"
fi

# A pacman that fails for another reason than a dependency refuses: it must
# not count every target as already broken and pass. That holds when the
# failure comes with pacman's dependency or not-found message too, and
# however long its output is.
mkdir -p "$T/broken-pacman"
printf '#!/bin/sh\ncat "$BROKEN_PACMAN_OUT"\nexit 1\n' > "$T/broken-pacman/pacman"
chmod +x "$T/broken-pacman/pacman"
printf '%s\n' 'error: failed to initialize alpm library:' '(could not find or read directory)' > "$T/broken-init"
printf '%s\n' 'error: core database is inconsistent: filename of package dep is illegal' \
  'error: failed to prepare transaction (could not satisfy dependencies)' ":: unable to satisfy dependency 'dep' required by alpha" > "$T/broken-db"
for i in $(seq 3000); do echo "error: extra database is inconsistent: filename of package p$i is illegal"; done > "$T/broken-many"
echo 'error: target not found: alpha' >> "$T/broken-many"
pub edge $(mkpkg alpha 6)
rc_before=$(entries rc)
for broken in init db many; do
  : > "$T/record"
  if BROKEN_PACMAN_OUT="$T/broken-$broken" PATH="$T/broken-pacman:$PATH" promote alpha; then fail "a pacman that fails ($broken) should refuse"; fi
  grep -q "pacman could not check alpha against rc/x86_64 (after this promotion): error: " "$T/out" \
    && grep -q 'nothing published' "$T/out" && [[ "$(entries rc)" == "$rc_before" ]] || fail "broken pacman ($broken): $(cat "$T/out")"
done
pass "a pacman that cannot run, or reports a broken database, refuses the promotion instead of passing it"

# Reasons are compared one by one, not as joined text: a version may hold a
# semicolon, and split on "; " the new reason 'foo=1;4' would look like
# pieces of the two old ones.
mkdir -p "$T/twoview-pacman"
cat > "$T/twoview-pacman/pacman" <<'PACMAN'
#!/bin/sh
echo 'error: failed to prepare transaction (could not satisfy dependencies)'
echo ":: unable to satisfy dependency 'foo=1;2' required by p"
echo ":: unable to satisfy dependency 'bar=3;4' required by p"
case "$*" in *db-after*) echo ":: unable to satisfy dependency 'foo=1;4' required by p" ;; esac
exit 1
PACMAN
chmod +x "$T/twoview-pacman/pacman"
: > "$T/record"
if PATH="$T/twoview-pacman:$PATH" promote alpha; then fail "a reason gained after the promotion should refuse, semicolons and all"; fi
grep -q "alpha: unable to satisfy dependency 'foo=1;4' required by p" "$T/out" && [[ "$(entries rc)" == "$rc_before" ]] \
  && pass "a gained reason is found even when versions hold semicolons" || fail "semicolon reasons: $(cat "$T/out")"

# With the channel's Arch snapshot, pacman resolves as on a machine on the
# channel: a name Omarchy serves takes over from Arch's.
recipe hyprwm '{"source": "local"}'
recipe tool '{"source": "local"}'
recipe aqua '{"source": "local"}'
repo-add -q "$OMARCHY_ARCH_SNAPSHOT/extra.db.tar.gz" $(mkpkg hyprwm 1) $(mkpkg archlib 1) \
  $(PROVIDES="libaq.so=14" mkpkg aqua 1) $(DEPENDS="libaq.so=14" mkpkg toolkit 1) >/dev/null 2>&1
pub rc $(DEPENDS="hyprwm=1.0-1 archlib" mkpkg plug 1)
pub edge $(mkpkg hyprwm 2) $(DEPENDS="archlib>=1.0-2" mkpkg tool 1) $(PROVIDES="libaq.so=15" mkpkg aqua 2)
rc_before=$(entries rc)
: > "$T/record"
if promote hyprwm; then fail "Omarchy's hyprwm taking over under a plugin pinned to Arch's should refuse"; else
  grep -q "plug: unable to satisfy dependency 'hyprwm=1.0-1' required by plug" "$T/out" \
    && [[ "$(entries rc)" == "$rc_before" ]] && ! grep -q "'archlib' required" "$T/out" \
    && pass "what Arch's snapshot satisfies passes, and Omarchy's build taking over from Arch's under a pin is refused" || fail "Arch snapshot: $(cat "$T/out")"
fi
: > "$T/record"
if promote tool; then fail "a package needing a newer Arch package than the snapshot has should refuse"; else
  grep -q "tool: unable to satisfy dependency 'archlib>=1.0-2' required by tool" "$T/out" \
    && pass "a package needing a newer Arch package than the channel's snapshot is refused" || fail "Arch too old: $(cat "$T/out")"
fi
: > "$T/record"
if promote aqua; then fail "Omarchy's aqua dropping a library an Arch package links should refuse"; else
  grep -q "toolkit: unable to satisfy dependency 'libaq.so=14' required by toolkit" "$T/out" \
    && pass "an Arch package that links what Omarchy's build of a library drops is refused" || fail "Arch dependent: $(cat "$T/out")"
fi

# Into an empty destination every package is new, and is checked.
recipe plug '{"source": "local"}'
repo-add -q "$OMARCHY_ARCH_SNAPSHOT/extra.db.tar.gz" $(DEPENDS="plug nothere" mkpkg plugext 1) >/dev/null 2>&1
rm -rf "$REMOTE/stable"
stable() { "$BIN/promote-channel" --remote "$REMOTE" --from rc --to stable --arch x86_64 --record "$T/record" "$@" >"$T/out" 2>&1; }
: > "$T/record"
if stable stale; then fail "stale into an empty stable should refuse"; else
  grep -q "stale: unable to satisfy dependency 'gone' required by stale" "$T/out" \
    && pass "a package promoted into an empty channel is checked like any other" || fail "empty destination: $(cat "$T/out")"
fi
: > "$T/record"
stable plug && [[ "$(entries stable)" == "plug-1.0-1 " ]] && grep -q "plugext: unable to satisfy dependency 'nothere'" "$T/out" \
  && jq -e -s '[.[] | select(.type=="deps")] | .[0].result == "pass" and .[0].existing[0].package == "plugext"' "$T/record" >/dev/null \
  && pass "the empty channel still has its Arch snapshot: plug resolves from it, and an Arch package already broken there is not held against it" || fail "empty destination with Arch: $(cat "$T/out")"

# The check sorts the files of a database to read each package's desc and
# depends together. A locale's sort ignores punctuation, so on a builder with
# LANG=en_US.UTF-8 another entry can fall between one package's two files, as
# xdep-1.0-1depz does between xdep-1.0-1/depends and xdep-1.0-1/desc, and the
# depends were lost. Arch Linux ARM's databases keep depends in that separate
# file, so this snapshot does too.
if ! locale -a 2>/dev/null | grep -qx 'en_US.utf8' && (( EUID == 0 )); then
  localedef -i en_US -f UTF-8 en_US.UTF-8 >/dev/null 2>&1 || true
fi
if locale -a 2>/dev/null | grep -qx 'en_US.utf8'; then
  recipe xlib '{"source": "local"}'
  pub rc $(PROVIDES="libx.so=1" mkpkg xlib 1)
  pub edge $(PROVIDES="libx.so=2" mkpkg xlib 2)
  rm -f "$OMARCHY_ARCH_SNAPSHOT"/extra.*
  repo-add -q "$OMARCHY_ARCH_SNAPSHOT/extra.db.tar.gz" $(DEPENDS="libx.so=1" mkpkg xdep 1) $(mkpkg xdep-1.0-1depz 1) >/dev/null 2>&1
  alarm="$T/alarm"; mkdir -p "$alarm"; tar -xf "$OMARCHY_ARCH_SNAPSHOT/extra.db.tar.gz" -C "$alarm"
  for desc in "$alarm"/*/desc; do
    awk '/^%(DEPENDS|PROVIDES)%$/ { s = 1 } s { print } /^$/ { s = 0 }' "$desc" > "${desc%/desc}/depends"
    awk '/^%(DEPENDS|PROVIDES)%$/ { s = 1 } /^$/ { if (s) { s = 0; next } } !s' "$desc" > "$desc.new" && mv "$desc.new" "$desc"
  done
  rm -f "$OMARCHY_ARCH_SNAPSHOT"/extra.*
  (cd "$alarm" && tar -czf "$OMARCHY_ARCH_SNAPSHOT/extra.db.tar.gz" -- */) && ln -s extra.db.tar.gz "$OMARCHY_ARCH_SNAPSHOT/extra.db"
  rc_before=$(entries rc)
  : > "$T/record"
  if LANG=en_US.UTF-8 LC_ALL='' promote xlib; then fail "xlib dropping libx.so=1 under Arch's xdep should refuse in any locale"; else
    grep -q "xdep: unable to satisfy dependency 'libx.so=1' required by xdep" "$T/out" && [[ "$(entries rc)" == "$rc_before" ]] \
      && pass "a builder's locale does not split a package's desc from its depends file" || fail "locale: $(cat "$T/out")"
  fi
else
  echo "SKIP: no en_US.UTF-8 locale to sort in"
fi
