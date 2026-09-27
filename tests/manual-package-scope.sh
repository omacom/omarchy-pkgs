#!/bin/bash
# Offline benign fixtures for manual prebuilt admission.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/policies/recipe/.omarchy" "$TMP/policies/other/.omarchy" \
  "$TMP/output/edge/x86_64" "$TMP/publication" "$TMP/helpers"
printf '%s\n' '{"artifacts":{"pkgbase":"base","packages":["alpha","beta"]}}' > "$TMP/policies/recipe/.omarchy/package.json"
printf '%s\n' '{"source":"fixture"}' > "$TMP/policies/other/.omarchy/package.json"
cp "$ROOT/helpers/package-scope.py" "$TMP/helpers/"
sed -e "s|/helpers/package-scope.py|$TMP/helpers/package-scope.py|g" \
    -e "s|/build-output|$TMP/output|g" \
    -e "s|/publication|$TMP/publication|g" \
    -e "s|/pkgbuilds|$TMP/policies|g" \
  "$ROOT/helpers/admit-prebuilt.sh" > "$TMP/admit.sh"
python3 - "$TMP/output/edge/x86_64" <<'PY'
import io
from pathlib import Path
import subprocess
import sys
import tarfile
output = Path(sys.argv[1])
for name, base in [('alpha', 'base'), ('beta', 'base'), ('other', 'other')]:
    info = f'pkgname = {name}\npkgbase = {base}\npkgver = 1-1\narch = x86_64\n'.encode()
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w') as archive:
        entry = tarfile.TarInfo('.PKGINFO')
        entry.size = len(info)
        archive.addfile(entry, io.BytesIO(info))
    with (output / f'{name}-1-1-x86_64.pkg.tar.zst').open('wb') as dest:
        subprocess.run(['zstd', '-q', '-c'], input=data.getvalue(), stdout=dest, check=True)
PY
run_admit() { MIRROR=edge bash "$TMP/admit.sh" x86_64 "$@"; }
# An unrelated archive cannot be enrolled by selecting a reviewed split job.
if run_admit false recipe > "$TMP/result" 2> "$TMP/error"; then
  echo 'FAIL: extra archive admitted' >&2; exit 1
fi
grep -Fq 'unexpected or missing archives' "$TMP/error"
# Once both reviewed jobs are named, all primary split outputs are present.
run_admit false recipe other > "$TMP/publication/manifest.json"
jq -e '[.jobs[].package] | sort == ["other", "recipe"]' "$TMP/publication/manifest.json" >/dev/null
jq -e '.jobs[] | select(.package == "recipe") | [.artifacts[].pkgname] | sort == ["alpha", "beta"]' "$TMP/publication/manifest.json" >/dev/null
run_admit false > "$TMP/result"
if run_admit false alpha > "$TMP/result" 2> "$TMP/error"; then
  echo 'FAIL: output alias accepted as job' >&2; exit 1
fi
grep -Fq 'Unknown reviewed job' "$TMP/error"
# A split job cannot admit only one primary output.
mv "$TMP/output/edge/x86_64/beta-1-1-x86_64.pkg.tar.zst" "$TMP/beta.saved"
if run_admit false recipe > "$TMP/result" 2> "$TMP/error"; then
  echo 'FAIL: incomplete split job admitted' >&2; exit 1
fi
grep -Fq 'missing primary package' "$TMP/error"
mv "$TMP/beta.saved" "$TMP/output/edge/x86_64/beta-1-1-x86_64.pkg.tar.zst"
# Retention only uses prior approved jobs and fails on unrelated leftovers.
run_admit true recipe > "$TMP/result"
[[ $(jq '.jobs | length' "$TMP/result") == 2 ]]
cp "$TMP/output/edge/x86_64/other-1-1-x86_64.pkg.tar.zst" "$TMP/output/edge/x86_64/leftover-1-1-x86_64.pkg.tar.zst"
if run_admit true recipe > "$TMP/result" 2> "$TMP/error"; then
  echo 'FAIL: unrelated staged archive retained' >&2; exit 1
fi
grep -Fq 'unexpected or missing archives' "$TMP/error"
# Separate jobs with shared prefixes must resolve by .PKGINFO pkgname.
rm -f "$TMP/output/edge/x86_64/"*.pkg.tar.zst
mkdir -p "$TMP/policies/omarchy/.omarchy" "$TMP/policies/omarchy-settings/.omarchy" \
  "$TMP/policies/alpha/.omarchy" "$TMP/policies/beta/.omarchy"
for job in omarchy omarchy-settings alpha beta; do
  printf '%s\n' '{"source":"fixture"}' > "$TMP/policies/$job/.omarchy/package.json"
done
python3 - "$TMP/output/edge/x86_64" <<'PYSHARED'
import io
from pathlib import Path
import subprocess
import sys
import tarfile
output = Path(sys.argv[1])
for name in ('omarchy', 'omarchy-settings', 'alpha', 'beta'):
    info = f'pkgname = {name}\npkgbase = {name}\npkgver = 1-1\narch = x86_64\n'.encode()
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w') as archive:
        entry = tarfile.TarInfo('.PKGINFO')
        entry.size = len(info)
        archive.addfile(entry, io.BytesIO(info))
    with (output / f'{name}-1-1-x86_64.pkg.tar.zst').open('wb') as dest:
        subprocess.run(['zstd', '-q', '-c'], input=data.getvalue(), stdout=dest, check=True)
PYSHARED
mv "$TMP/output/edge/x86_64/alpha-1-1-x86_64.pkg.tar.zst" "$TMP/alpha.saved"
mv "$TMP/output/edge/x86_64/beta-1-1-x86_64.pkg.tar.zst" "$TMP/beta.saved"
run_admit false omarchy omarchy-settings > "$TMP/result"
jq -e '[.jobs[] | [.package, .artifacts[0].pkgname]] | sort == [["omarchy", "omarchy"], ["omarchy-settings", "omarchy-settings"]]' "$TMP/result" >/dev/null
mv "$TMP/alpha.saved" "$TMP/output/edge/x86_64/alpha-1-1-x86_64.pkg.tar.zst"
mv "$TMP/beta.saved" "$TMP/output/edge/x86_64/beta-1-1-x86_64.pkg.tar.zst"
rm -f "$TMP/output/edge/x86_64/omarchy"*.pkg.tar.zst
if run_admit false alpha > "$TMP/result" 2> "$TMP/error"; then
  echo 'FAIL: additional beta job admitted by selecting alpha' >&2; exit 1
fi
grep -Fq 'unexpected or missing archives' "$TMP/error"
# A link at a staged archive name is not a regular source, even when its target is valid.
rm -f "$TMP/output/edge/x86_64/beta-1-1-x86_64.pkg.tar.zst"
mv "$TMP/output/edge/x86_64/alpha-1-1-x86_64.pkg.tar.zst" "$TMP/alpha.real"
ln -s "$TMP/alpha.real" "$TMP/output/edge/x86_64/alpha-1-1-x86_64.pkg.tar.zst"
if run_admit false alpha > "$TMP/result" 2> "$TMP/error"; then
  echo 'FAIL: staged archive symlink admitted' >&2; exit 1
fi
echo 'PASS: exact metadata names admit shared-prefix jobs; extra jobs and unsafe sources remain blocked'
