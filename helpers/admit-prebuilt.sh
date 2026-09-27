#!/bin/bash
# Run inside the native utility image with readonly policies, staged archives and manifest.
set -euo pipefail

arch=$1
shift
include_staged=$1
shift
scope=/helpers/package-scope.py
output="/build-output/$MIRROR/$arch"
manifest=/publication/manifest.json
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if (( $# == 0 )); then
  [[ -f $manifest ]] || { echo 'No approved manifest; select a reviewed job with --package' >&2; exit 1; }
  python3 "$scope" verify --policy-root /pkgbuilds --arch "$arch" --directory "$output" --manifest "$manifest" >/dev/null
  cat "$manifest"
  exit 0
fi

[[ -d $output && ! -L $output ]] || { echo "Invalid staged output directory: $output" >&2; exit 1; }
# Read bounded metadata from regular staged archives in the trusted utility.
# The operator's reviewed policy remains the authority for allowed pkgname values.
python3 - "$scope" "$output" > "$work/candidates" <<'PYMETA'
import importlib.util
import os
from pathlib import Path
import stat
import sys

spec = importlib.util.spec_from_file_location("package_scope", sys.argv[1])
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)
try:
    for path in sorted(Path(sys.argv[2]).iterdir()):
        if not path.name.endswith(scope.EXT):
            continue
        filename = scope.archive_name(path.name)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                scope.fail(f"not a regular archive: {filename}")
            pkgname = scope.metadata(fd)["pkgname"]
        finally:
            os.close(fd)
        sys.stdout.buffer.write(os.fsencode(filename) + b"\0" + pkgname.encode() + b"\0")
except (ValueError, OSError) as exc:
    print(f"admit-prebuilt: {exc}", file=sys.stderr)
    sys.exit(1)
PYMETA

parts=()
declare -A allowed=()
for job in "$@"; do
  policy="/pkgbuilds/$job/.omarchy/package.json"
  [[ $job =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ && -f $policy && ! -L $policy ]] || {
    echo "Unknown reviewed job: $job (use a pkgbuild directory, not an output alias)" >&2; exit 1;
  }
  jobdir=$(mktemp -d "$work/job.XXXXXX")
  jq -er 'if .artifacts then .artifacts.packages + [.artifacts.pkgbase + "-debug"] else ["'"$job"'", "'"$job"'-debug"] end | .[]' \
    "$policy" > "$jobdir/names"
  allowed=()
  while IFS= read -r name; do allowed["$name"]=1; done < "$jobdir/names"
  mkdir "$jobdir/output"
  : > "$jobdir/files"
  while IFS= read -r -d '' filename && IFS= read -r -d '' pkgname; do
    [[ -n ${allowed[$pkgname]:-} ]] || continue
    # Reopen without following links; a changed or special source is refused.
    python3 - "$output/$filename" "$jobdir/output/$filename" <<'PYCOPY'
import os
import shutil
import stat
import sys

fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        raise ValueError("not a regular staged archive")
    with os.fdopen(fd, "rb", closefd=False) as source, open(sys.argv[2], "xb") as target:
        shutil.copyfileobj(source, target)
finally:
    os.close(fd)
PYCOPY
    printf '%s\n' "$filename" >> "$jobdir/files"
  done < "$work/candidates"
  [[ -s $jobdir/files ]] || { echo "No staged archives for reviewed job: $job" >&2; exit 1; }
  python3 "$scope" create --policy-root /pkgbuilds --package "$job" --arch "$arch" \
    --directory "$jobdir/output" --files "$jobdir/files" > "$jobdir/manifest.json"
  parts+=(--manifest "$jobdir/manifest.json")
done

if [[ $include_staged == true && -f $manifest ]]; then
  # Retention is confined to jobs already approved by the host manifest.
  jq --argjson selected "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
    '.jobs |= map(select(.package as $p | $selected | index($p) | not))' \
    "$manifest" > "$work/prior.json"
  if (( $(jq '.jobs | length' "$work/prior.json") > 0 )); then
    python3 "$scope" verify --allow-extra --policy-root /pkgbuilds --arch "$arch" \
      --directory "$output" --manifest "$work/prior.json" >/dev/null
    parts+=(--manifest "$work/prior.json")
  fi
fi
python3 "$scope" merge "${parts[@]}" > "$work/combined.json"
python3 "$scope" verify --policy-root /pkgbuilds --arch "$arch" \
  --directory "$output" --manifest "$work/combined.json" >/dev/null
cat "$work/combined.json"
