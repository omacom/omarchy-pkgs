#!/bin/bash
# Self-test for bin/build-artifacts: what a pull request build would publish,
# for the DKMS check, as the build's dkms-request artifact records it. A
# planned package with no artifact in the run built nothing (edge already
# holds it); a reused artifact must still exist; a download, extraction or
# copy that fails, an artifact with no package, or a missing or malformed
# request fails the collection. gh is a stub that answers from fixtures.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A head commit with three recipes.
git init -q "$tmp/repo"
for p in linux-omarchy xpadneo-dkms hyprland; do
  mkdir -p "$tmp/repo/pkgbuilds/$p"
  echo "pkgname=$p" >"$tmp/repo/pkgbuilds/$p/PKGBUILD"
done
git -C "$tmp/repo" add -A
git -C "$tmp/repo" -c user.name=t -c user.email=t@t commit -qm head
head=$(git -C "$tmp/repo" rev-parse HEAD)
tree() { git -C "$tmp/repo" rev-parse "$head:pkgbuilds/$1"; }

# gh api, answered from $FAKE_GH: runs/<id>.json (a run's artifacts),
# artifacts/<id>.zip, named/<label>.json, runinfo/<id>.json (a run),
# compare/<sha>.json and blob/<ref>.json (build-pr.yml at a commit; a 404 the
# way gh reports one when absent). --jq applies the expression the way gh does.
mkdir -p "$tmp/bin" "$tmp/gh/runs" "$tmp/gh/artifacts" "$tmp/gh/named" "$tmp/gh/runinfo" "$tmp/gh/compare" "$tmp/gh/blob"
cat >"$tmp/bin/gh" <<'GH'
#!/bin/bash
set -euo pipefail
path="" expr="" paginate=0
while (($#)); do
  case $1 in
    --jq) expr=$2; shift 2 ;;
    --paginate) paginate=1; shift ;;
    repos/*) path=$1; shift ;;
    *) shift ;;
  esac
done
case $path in
  */actions/runs/*/artifacts) file=$FAKE_GH/runs/$(cut -d/ -f6 <<<"$path").json ;;
  */actions/artifacts/*/zip) cat "$FAKE_GH/artifacts/$(cut -d/ -f6 <<<"$path").zip"; exit ;;
  */actions/artifacts\?name=*)
    # Pages the way GitHub does: per_page (default 30) at a time, every page
    # with --paginate, else the first.
    label=${path#*name=}; file=$FAKE_GH/named/${label%%&*}.json
    [[ -f $file ]] || { echo "gh stub: HTTP 404" >&2; exit 1; }
    per=30; [[ $path != *per_page=* ]] || per=${path##*per_page=}; per=${per%%&*}
    page=0
    while :; do
      chunk=$(jq -c --argjson p "$page" --argjson n "$per" '{artifacts: .artifacts[$p * $n:($p + 1) * $n]}' "$file")
      [[ $page == 0 || $(jq '.artifacts | length' <<<"$chunk") -gt 0 ]] || break
      if [[ -n $expr ]]; then jq -r "$expr" <<<"$chunk"; else echo "$chunk"; fi
      ((paginate)) || break
      page=$((page + 1))
    done
    exit ;;
  */actions/runs/*) file=$FAKE_GH/runinfo/$(cut -d/ -f6 <<<"$path").json ;;
  */compare/*...*) file=$FAKE_GH/compare/${path##*...}.json ;;
  */contents/.github/workflows/build-pr.yml\?ref=*)
    ref=${path#*ref=}
    [[ ! -f $FAKE_GH/blob/$ref.error ]] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    file=$FAKE_GH/blob/$ref.json
    [[ -f $file ]] || { echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *) echo "gh stub: unexpected $path" >&2; exit 1 ;;
esac
[[ -f $file ]] || { echo "gh stub: HTTP 404" >&2; exit 1; }
if [[ -n $expr ]]; then jq -r "$expr" "$file"; else cat "$file"; fi
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" FAKE_GH="$tmp/gh" GITHUB_REPOSITORY=omacom/omarchy-pkgs

# artifact <id> <tar|bare|empty|corrupt> <file>...: an artifact's zip.
artifact() {
  local id=$1 form=$2 dir="$tmp/a$1" f
  mkdir -p "$dir/files" "$dir/zip"
  for f in "${@:3}"; do echo "$f" >"$dir/files/$f"; done
  case $form in
    tar) tar -cf "$dir/zip/packages.tar" -C "$dir/files" "${@:3}" ;;
    bare) cp "$dir/files"/* "$dir/zip/" ;;
    empty) tar -cf "$dir/zip/packages.tar" -T /dev/null ;;
    corrupt) echo "not a tar" >"$dir/zip/packages.tar" ;;
  esac
  (cd "$dir/zip" && bsdtar -a -cf "$tmp/gh/artifacts/$id.zip" ./*)
}
artifact 11 tar linux-omarchy-7.2.8-10-x86_64.pkg.tar.zst linux-omarchy-headers-7.2.8-10-x86_64.pkg.tar.zst
artifact 12 bare xpadneo-dkms-0.9.8-1-any.pkg.tar.zst
artifact 13 empty
artifact 14 corrupt
artifact 15 tar 'linux-omarchy-1:7.2.8-10-aarch64.pkg.tar.zst'

run_json() { # run_json <run> <name=id>...: a run's artifact listing
  local pair
  for pair in "${@:2}"; do
    jq -n --arg n "${pair%=*}" --argjson i "${pair#*=}" '{name: $n, id: $i, expired: false}'
  done | jq -s '{artifacts: .}' >"$tmp/gh/runs/$1.json"
}
matrix() { # matrix <package:arch>...
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0) | split(":") | {package: .[0], arch: .[1]}) | {include: .}'
}
request() { # request <run> <request json>: the run's dkms-request artifact, replacing any
  mkdir -p "$tmp/req$1"
  printf '%s\n' "$2" >"$tmp/req$1/dkms-request.json"
  (cd "$tmp/req$1" && bsdtar -a -cf "$tmp/gh/artifacts/90$1.zip" dkms-request.json)
  [[ -f $tmp/gh/runs/$1.json ]] || echo '{"artifacts": []}' >"$tmp/gh/runs/$1.json"
  jq --argjson i "90$1" '.artifacts = [.artifacts[] | select(.name != "dkms-request")] + [{name: "dkms-request", id: $i, expired: false}]' \
    "$tmp/gh/runs/$1.json" >"$tmp/listing" && mv "$tmp/listing" "$tmp/gh/runs/$1.json"
}
collect() { # collect <run> <matrix> <reused json> [trusted]
  rm -rf "$tmp/out"
  request "$1" "$(jq -n --argjson m "$2" --argjson r "$3" --argjson t "${4:-true}" '{trusted: $t, matrix: $m, reused: $r}')"
  (cd "$tmp/repo" && "$ROOT/bin/build-artifacts" "$tmp/out" "$1" "$head") >"$tmp/stdout" 2>"$tmp/stderr"
}
outfiles() { ls "$tmp/out" 2>/dev/null | sort | tr '\n' ' '; }

k=linux-omarchy-x86_64-$(tree linux-omarchy)
run_json 1 "$k=11" "hyprland-x86_64-$(tree linux-omarchy)=12"
collect 1 "$(matrix linux-omarchy:x86_64 hyprland:x86_64)" '[]' || fail "a run's own artifacts collect: $(cat "$tmp/stderr")"
[[ $(outfiles) == "linux-omarchy-7.2.8-10-x86_64.pkg.tar.zst linux-omarchy-headers-7.2.8-10-x86_64.pkg.tar.zst " ]] &&
  pass "a planned package's artifact from this run is unpacked, and only by its own label" || fail "own: $(outfiles)"
grep -qF "hyprland-x86_64-$(tree hyprland): nothing built (edge already holds this version)" "$tmp/stdout" &&
  pass "a planned package with no artifact in the run built nothing" || fail "held: $(cat "$tmp/stdout")"

x=xpadneo-dkms-x86_64-$(tree xpadneo-dkms)
# A run that may vouch for an artifact: this repository's build-pr.yml.
runinfo() { # runinfo <id> <head repository> [path] [event] [head sha]
  jq -n --arg r "$2" --arg p "${3:-.github/workflows/build-pr.yml}" --arg e "${4:-pull_request}" --arg s "${5:-$head}" \
    '{path: $p, event: $e, head_repository: {full_name: $r}, head_sha: $s}' >"$tmp/gh/runinfo/$1.json"
}
runinfo 501 omacom/omarchy-pkgs
jq -n --arg n "$x" '{artifacts: [{name: $n, id: 99, expired: true, created_at: "2026-10-18T10:00:00Z", workflow_run: {id: 501}}, {name: $n, id: 12, expired: false, created_at: "2026-10-17T10:00:00Z", workflow_run: {id: 501}}]}' >"$tmp/gh/named/$x.json"
collect 1 "$(matrix linux-omarchy:x86_64)" "[\"$x\"]" || fail "a reused artifact collects: $(cat "$tmp/stderr")"
grep -q '^xpadneo-dkms-0.9.8-1-any.pkg.tar.zst$' <(ls "$tmp/out") &&
  pass "a reused artifact from an earlier run is collected too, past an expired one, bare files included" || fail "reused: $(outfiles)"

gone=linux-omarchy-aarch64-$(tree linux-omarchy)
echo '{"artifacts": []}' >"$tmp/gh/named/$gone.json"
! collect 1 "$(matrix)" "[\"$gone\"]" && grep -q "reused artifact $gone, which no longer exists" "$tmp/stderr" &&
  pass "a reused artifact that is gone fails, it does not pass as nothing built" || fail "gone: $(cat "$tmp/stderr")"

jq -n --arg n "$gone" '{artifacts: [{name: $n, id: 15, expired: false, created_at: "2026-10-18T10:00:00Z", workflow_run: {id: 501}}]}' >"$tmp/gh/named/$gone.json"
collect 1 "$(matrix)" "[\"$gone\"]" && [[ -f "$tmp/out/linux-omarchy-1:7.2.8-10-aarch64.pkg.tar.zst" ]] &&
  pass "a package with an epoch comes through packages.tar under its own name" || fail "epoch: $(outfiles) $(cat "$tmp/stderr")"

run_json 2 "$k=13"
! collect 2 "$(matrix linux-omarchy:x86_64)" '[]' && grep -q "artifact $k holds no package" "$tmp/stderr" &&
  pass "an artifact with no package fails" || fail "empty: $(cat "$tmp/stderr")"
run_json 3 "$k=14"
! collect 3 "$(matrix linux-omarchy:x86_64)" '[]' && grep -q "cannot unpack artifact $k" "$tmp/stderr" &&
  pass "an artifact whose packages.tar does not unpack fails" || fail "corrupt: $(cat "$tmp/stderr")"
run_json 4 "$k=404"
! collect 4 "$(matrix linux-omarchy:x86_64)" '[]' && grep -q "cannot download artifact $k" "$tmp/stderr" &&
  pass "a download that fails fails the collection" || fail "download: $(cat "$tmp/stderr")"
! (cd "$tmp/repo" && "$ROOT/bin/build-artifacts" "$tmp/out" 5 "$head") 2>"$tmp/stderr" && grep -q "cannot list run 5's artifacts" "$tmp/stderr" &&
  pass "a run whose artifacts cannot be listed fails" || fail "listing: $(cat "$tmp/stderr")"
! collect 1 "$(matrix no-such-recipe:x86_64)" '[]' && grep -q "no pkgbuilds/no-such-recipe at $head" "$tmp/stderr" &&
  pass "a planned package missing from the head fails" || fail "recipe: $(cat "$tmp/stderr")"

# A copy that fails stops the collection, it does not leave a package out.
mkdir -p "$tmp/ro"
chmod a-w "$tmp/ro"
if [[ $(id -u) != 0 ]]; then
  request 1 "$(jq -n --argjson m "$(matrix linux-omarchy:x86_64)" '{trusted: true, matrix: $m, reused: []}')"
  ! (cd "$tmp/repo" && "$ROOT/bin/build-artifacts" "$tmp/ro" 1 "$head") 2>"$tmp/stderr" &&
    grep -q "cannot copy linux-omarchy-.* from artifact $k" "$tmp/stderr" &&
    pass "a package that cannot be copied fails the collection" || fail "copy: $(cat "$tmp/stderr")"
fi
chmod u+w "$tmp/ro"

# The request: a pull request's run wrote it, so its shape is checked first.
run_json 6 "$k=11"
! (cd "$tmp/repo" && "$ROOT/bin/build-artifacts" "$tmp/out" 6 "$head") 2>"$tmp/stderr" && grep -q "run 6 has no dkms-request artifact" "$tmp/stderr" &&
  pass "a run without a dkms-request fails, it does not pass as nothing built" || fail "no request: $(cat "$tmp/stderr")"
collect 6 "$(matrix linux-omarchy:x86_64)" '[]' false && [[ -z $(outfiles) ]] && grep -q 'was not approved, so it built nothing' "$tmp/stdout" &&
  pass "an untrusted build ships nothing" || fail "untrusted: $(outfiles) $(cat "$tmp/stderr")"
for bad in '{"trusted": true, "matrix": {"include": [{"package": "../etc", "arch": "x86_64"}]}, "reused": []}' \
  '{"trusted": true, "matrix": {"include": [{"package": "linux-omarchy", "arch": "x86_64?x=1"}]}, "reused": []}' \
  '{"trusted": true, "matrix": {"include": []}, "reused": ["a&name=b-x86_64-0000000000000000000000000000000000000000"]}' \
  '{"trusted": "yes", "matrix": {"include": []}, "reused": []}' 'not json' \
  '{"trusted": true, "matrix": {"include": [{"package": "linux-omarchy\n", "arch": "x86_64"}]}, "reused": []}'; do
  request 6 "$bad"
  if (cd "$tmp/repo" && "$ROOT/bin/build-artifacts" "$tmp/out" 6 "$head") 2>"$tmp/stderr" >/dev/null; then fail "a malformed request must fail: $bad"; fi
  grep -q "run 6's dkms-request is malformed" "$tmp/stderr" || fail "malformed: $bad: $(cat "$tmp/stderr")"
done
pass "a request with a path, a query or a wrong type in it fails before it names anything"

# A package that is a link would copy whatever it points at on the runner.
mkdir -p "$tmp/a16/zip"
ln -s /etc/hostname "$tmp/a16/leak-1-1-x86_64.pkg.tar.zst"
tar -cf "$tmp/a16/zip/packages.tar" -C "$tmp/a16" leak-1-1-x86_64.pkg.tar.zst
(cd "$tmp/a16/zip" && bsdtar -a -cf "$tmp/gh/artifacts/16.zip" packages.tar)
run_json 7 "$k=16"
! collect 7 "$(matrix linux-omarchy:x86_64)" '[]' && grep -q "holds leak-1-1-x86_64.pkg.tar.zst, which is not a regular file" "$tmp/stderr" &&
  [[ -z $(outfiles) ]] && pass "a package that is a link fails, it is not followed" || fail "link: $(outfiles) $(cat "$tmp/stderr")"

# A file name with a tab or "##[" would reach plans and logs.
mkdir -p "$tmp/a17/files" "$tmp/a17/zip"
echo x >"$tmp/a17/files/evil"$'\t'"##[add-mask]x-1-1-x86_64.pkg.tar.zst"
tar -cf "$tmp/a17/zip/packages.tar" -C "$tmp/a17/files" .
(cd "$tmp/a17/zip" && bsdtar -a -cf "$tmp/gh/artifacts/17.zip" packages.tar)
run_json 8 "$k=17"
! collect 8 "$(matrix linux-omarchy:x86_64)" '[]' && grep -q "holds a file whose name makepkg would not produce" "$tmp/stderr" &&
  ! grep -qF '##[' "$tmp/stderr" "$tmp/stdout" && pass "a package file name outside makepkg's rules fails, and is not repeated" || fail "file name: $(cat "$tmp/stderr")"

# A reused artifact is only as good as the run that made it: anyone's run can
# upload one under any name. Only this repository's build-pr.yml vouches, and
# a fork's run only when its build-pr.yml is its merge base's.
fork_sha=1111111111111111111111111111111111111111 base_sha=2222222222222222222222222222222222222222
echo "{\"merge_base_commit\": {\"sha\": \"$base_sha\"}}" >"$tmp/gh/compare/$fork_sha.json"
reuse() { # reuse <label> <artifact id:run id>...: the label's artifacts, newest first
  local pair list='[]' n=0
  for pair in "${@:2}"; do
    list=$(jq -c --arg l "$1" --argjson a "${pair%%:*}" --argjson r "${pair#*:}" --arg t "$(printf '2026-10-18T%02d:%02d:00Z' $((11 - n / 60)) $((59 - n % 60)))" \
      '. + [{name: $l, id: $a, expired: false, created_at: $t, workflow_run: {id: $r}}]' <<<"$list")
    n=$((n + 1))
  done
  jq -n --argjson a "$list" '{artifacts: $a}' >"$tmp/gh/named/$1.json"
}
r=xpadneo-dkms-x86_64-$(tree xpadneo-dkms)
runinfo 601 attacker/omarchy-pkgs .github/workflows/build-pr.yml pull_request "$fork_sha"
echo '{"sha": "aaaa000000000000000000000000000000000001"}' >"$tmp/gh/blob/$base_sha.json"
echo '{"sha": "bbbb000000000000000000000000000000000002"}' >"$tmp/gh/blob/$fork_sha.json"
artifact 18 bare xpadneo-dkms-6.6.6-1-any.pkg.tar.zst
reuse "$r" 18:601 12:501
DEFAULT_BRANCH=master collect 1 "$(matrix)" "[\"$r\"]" && [[ $(outfiles) == "xpadneo-dkms-0.9.8-1-any.pkg.tar.zst " ]] &&
  grep -q "run 601 cannot vouch" "$tmp/stdout" && pass "a fork's artifact whose build-pr.yml differs from its merge base is passed over for an older trusted one" ||
  fail "fork changed: $(outfiles) / $(cat "$tmp/stdout" "$tmp/stderr")"
reuse "$r" 12:601
! DEFAULT_BRANCH=master collect 1 "$(matrix)" "[\"$r\"]" && grep -q "no artifact $r comes from a build this check trusts" "$tmp/stderr" &&
  pass "a reused artifact that only an untrusted run vouches for fails" || fail "only untrusted: $(cat "$tmp/stderr")"
runinfo 602 omacom/omarchy-pkgs .github/workflows/evil.yml pull_request
reuse "$r" 12:602
! DEFAULT_BRANCH=master collect 1 "$(matrix)" "[\"$r\"]" && grep -q "no artifact $r comes from a build this check trusts" "$tmp/stderr" &&
  pass "an artifact from another workflow fails, whoever ran it" || fail "other workflow: $(cat "$tmp/stderr")"
cp "$tmp/gh/blob/$base_sha.json" "$tmp/gh/blob/$fork_sha.json"
reuse "$r" 12:601
DEFAULT_BRANCH=master collect 1 "$(matrix)" "[\"$r\"]" && grep -q '^xpadneo-dkms-0.9.8-1-any.pkg.tar.zst$' <(ls "$tmp/out") &&
  pass "a fork's artifact whose build-pr.yml is its merge base's is reused" || fail "fork unchanged: $(cat "$tmp/stderr")"
rm "$tmp/gh/blob/$base_sha.json" "$tmp/gh/blob/$fork_sha.json"
DEFAULT_BRANCH=master collect 1 "$(matrix)" "[\"$r\"]" && grep -q '^xpadneo-dkms-0.9.8-1-any.pkg.tar.zst$' <(ls "$tmp/out") &&
  pass "a fork that branched before build-pr.yml existed is trusted (missing at both ends)" || fail "fork missing: $(cat "$tmp/stderr")"
# However many untrusted artifacts come first, every page is read: 120 of
# them fill more than the 100 a page holds.
pairs=()
for _ in $(seq 1 120); do pairs+=("18:601"); done
reuse "$r" "${pairs[@]}" 12:501
echo '{"sha": "aaaa000000000000000000000000000000000001"}' >"$tmp/gh/blob/$base_sha.json"
echo '{"sha": "bbbb000000000000000000000000000000000002"}' >"$tmp/gh/blob/$fork_sha.json"
DEFAULT_BRANCH=master collect 1 "$(matrix)" "[\"$r\"]" && [[ $(outfiles) == "xpadneo-dkms-0.9.8-1-any.pkg.tar.zst " ]] &&
  pass "a trusted artifact behind a page of untrusted ones is still found" || fail "pages: $(outfiles) / $(tail -n 3 "$tmp/stderr")"
rm "$tmp/gh/blob/$base_sha.json" "$tmp/gh/blob/$fork_sha.json"
reuse "$r" 12:601
touch "$tmp/gh/blob/$fork_sha.error"
! DEFAULT_BRANCH=master collect 1 "$(matrix)" "[\"$r\"]" && grep -q "cannot read build-pr.yml at $fork_sha" "$tmp/stderr" &&
  pass "an error reading a fork's build-pr.yml fails, it does not read as unchanged" || fail "blob error: $(cat "$tmp/stderr")"
