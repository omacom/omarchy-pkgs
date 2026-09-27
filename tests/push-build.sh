#!/bin/bash
# Offline preflight checks: no ssh, container, credentials or publish actions.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/helpers" "$TMP/build-output/edge/x86_64" \
  "$TMP/.publication/edge/x86_64" "$TMP/pkgbuilds/recipe/.omarchy"
cp "$ROOT/bin/push-build" "$TMP/bin/"
cp "$ROOT/helpers/"{message-helpers,paths,host-helpers,docker-helpers}.sh "$TMP/helpers/"
cp "$ROOT/helpers/package-scope.py" "$TMP/helpers/"
printf '%s\n' '{"artifacts":{"pkgbase":"base","packages":["alpha","beta"]}}' > "$TMP/pkgbuilds/recipe/.omarchy/package.json"
run_push() { "$TMP/bin/push-build" --host fixture --dry-run "$@" > "$TMP/log" 2>&1; }
if run_push --package recipe; then echo 'FAIL: absent manifest accepted' >&2; exit 1; fi
grep -Fq 'No local approved build manifest' "$TMP/log"
printf '%s\n' '{"version":1,"target_arch":"x86_64","jobs":[{"package":"recipe"}]}' > "$TMP/.publication/edge/x86_64/manifest.json"
if run_push --package alpha; then echo 'FAIL: output alias accepted' >&2; exit 1; fi
grep -Fq 'Unknown reviewed job: alpha (use a pkgbuild directory, not an output alias)' "$TMP/log"
if run_push --yes; then echo 'FAIL: unattended unscoped push accepted' >&2; exit 1; fi
grep -Fq -- '--package is required' "$TMP/log"
# The utility image is mocked only for this dry-run selection test.
cat > "$TMP/bin/docker" <<'MOCK'
#!/bin/bash
case $1 in
  info|buildx) exit 0 ;;
  run)
    shift
    saw_user=false
    while (( $# )); do
      case $1 in
        --user)
          [[ $2 == "$(id -u):$(id -g)" ]] || { echo "wrong Docker verifier UID:GID: $2" >&2; exit 1; }
          saw_user=true
          shift 2 ;;
        -v)
          case $2 in
            *:/output:ro) output=${2%:/output:ro} ;;
            *:/pkgbuilds:ro) policies=${2%:/pkgbuilds:ro} ;;
            *:/helpers:ro) helpers=${2%:/helpers:ro} ;;
            *:/selection:ro) selection=${2%:/selection:ro} ;;
          esac
          shift 2 ;;
        --rm|--platform=*) shift ;;
        omarchy-pkg-builder:*) shift; break ;;
        *) shift ;;
      esac
    done
    [[ $saw_user == true ]] || { echo 'missing Docker verifier --user' >&2; exit 1; }
    shift # python3
    shift # /helpers/package-scope.py
    args=()
    for arg in "$@"; do
      case $arg in
        /output) arg=$output ;;
        /pkgbuilds) arg=$policies ;;
        /selection/manifest.json) arg=$selection/manifest.json ;;
      esac
      args+=("$arg")
    done
    exec python3 "$helpers/package-scope.py" "${args[@]}" ;;
esac
MOCK
chmod +x "$TMP/bin/docker"
python3 - "$TMP/build-output/edge/x86_64" <<'PYFIX'
import io
from pathlib import Path
import subprocess
import sys
import tarfile
out = Path(sys.argv[1])
for name in ('alpha', 'beta'):
    info = f'pkgname = {name}\npkgbase = base\npkgver = 1-1\narch = x86_64\n'.encode()
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode='w') as archive:
        item = tarfile.TarInfo('.PKGINFO')
        item.size = len(info)
        archive.addfile(item, io.BytesIO(info))
    with (out / f'{name}-1-1-x86_64.pkg.tar.zst').open('wb') as dest:
        subprocess.run(['zstd', '-q', '-c'], input=data.getvalue(), stdout=dest, check=True)
PYFIX
printf '%s\n' alpha-1-1-x86_64.pkg.tar.zst beta-1-1-x86_64.pkg.tar.zst > "$TMP/files"
python3 "$ROOT/helpers/package-scope.py" create --policy-root "$TMP/pkgbuilds" \
  --package recipe --arch x86_64 --directory "$TMP/build-output/edge/x86_64" \
  --files "$TMP/files" > "$TMP/.publication/edge/x86_64/manifest.json"
if ! PATH="$TMP/bin:$PATH" CONTAINER_ENGINE=docker run_push --package recipe; then
  cat "$TMP/log" >&2; echo 'FAIL: approved split job dry run' >&2; exit 1
fi
grep -Fq '2 package(s) to push' "$TMP/log"
grep -Fq 'alpha-1-1-x86_64.pkg.tar.zst' "$TMP/log"
grep -Fq 'beta-1-1-x86_64.pkg.tar.zst' "$TMP/log"
if ! PATH="$TMP/bin:$PATH" CONTAINER_ENGINE=docker run_push; then
  cat "$TMP/log" >&2; echo 'FAIL: interactive manifest-wide dry run' >&2; exit 1
fi
grep -Fq -- '--package recipe' "$TMP/log"
printf 'changed fixture bytes' >> "$TMP/build-output/edge/x86_64/alpha-1-1-x86_64.pkg.tar.zst"
if PATH="$TMP/bin:$PATH" CONTAINER_ENGINE=docker run_push --package recipe; then
  echo 'FAIL: changed local archive accepted' >&2; exit 1
fi
grep -Fq 'package-scope:' "$TMP/log"
echo 'PASS: push selects complete approved split group; preflight rejects unapproved scope'
