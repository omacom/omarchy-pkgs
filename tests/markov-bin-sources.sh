#!/bin/bash
# Run as builder in a disposable builder container after bin/build downloaded
# sources. No network or secret keys needed; every case has a fresh keyring.
set -euo pipefail
root=$(realpath "${BASH_SOURCE[0]%/*}/..")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
recipe="$root/pkgbuilds/markov-bin"
source "$recipe/PKGBUILD"
for case_name in valid bad-archive bad-checksums bad-signature missing-key wrong-allowlist; do
  dir="$work/$case_name"
  mkdir -p "$dir/gnupg"
  chmod 700 "$dir/gnupg"
  cp "$recipe/PKGBUILD" "$recipe/markov.1" "$dir/"
  cp "$root/src/markov-bin/$_archive" "$root/src/markov-bin/$_checksums" "$root/src/markov-bin/$_checksums.sig" "$dir/"
  if [[ $case_name != missing-key ]]; then
    gpg --homedir "$dir/gnupg" --batch --import "$recipe/keys/pgp/${validpgpkeys[0]}.asc" >/dev/null 2>&1
  fi
  case "$case_name" in
    bad-archive) printf x >> "$dir/$_archive" ;;
    bad-checksums) printf x >> "$dir/$_checksums" ;;
    bad-signature) printf 'invalid signature\n' > "$dir/$_checksums.sig" ;;
    wrong-allowlist) sed -i "s/${validpgpkeys[0]}/0000000000000000000000000000000000000000/" "$dir/PKGBUILD" ;;
  esac
  status=0
  (cd "$dir" && GNUPGHOME="$dir/gnupg" makepkg --verifysource --noconfirm) > "$dir/result.log" 2>&1 || status=$?
  if [[ $case_name == valid ]]; then
    [[ $status == 0 ]] || { cat "$dir/result.log"; exit 1; }
  else
    [[ $status != 0 ]] || { echo "FAIL: accepted $case_name"; exit 1; }
    # Ensure the failure reached the intended verification layer.
    if [[ $case_name == bad-archive ]]; then
      grep -q 'validity check' "$dir/result.log"
    else
      grep -Eq 'PGP|signature|public key|signing' "$dir/result.log"
    fi
  fi
  echo "PASS: $case_name (exit=$status)"
done
# A good signature alone does not bind our chosen archive: prepare() must
# require exactly one matching hash and must check that hash as well.
dir="$work/prepare"
mkdir "$dir"
cp "$root/src/markov-bin/$_archive" "$dir/"
(
  cd "$dir"
  printf '%064d  other-file\n' 0 > "$_checksums"
  if prepare; then echo 'FAIL: missing archive accepted'; exit 1; fi
  printf '%064d  %s\n' 0 "$_archive" > "$_checksums"
  if prepare; then echo 'FAIL: wrong archive hash accepted'; exit 1; fi
  sha256sum "$_archive" > "$_checksums"
  prepare
  cat "$_checksums" >> duplicate
  cat duplicate >> "$_checksums"
  if prepare; then echo 'FAIL: duplicate archive accepted'; exit 1; fi
)
echo 'PASS: signed manifest archive selection/hash/duplicate checks'
