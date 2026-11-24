#!/bin/bash
# pkgbuilds/tailscale publishes binaries that an hourly job picked up with
# nobody looking, and they run as root. Its verify() is what stands between a
# modified download and a published package: it must accept Tailscale's chain
# (a root key signs the signing keys, one of those signs the tarball) and
# nothing else. And package() must fail when the CLI it runs to write the
# completions fails, not ship empty ones.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
RECIPE=$ROOT/pkgbuilds/tailscale/PKGBUILD
KEYS=$ROOT/pkgbuilds/tailscale/keys/distsign
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

pkgver=$(bash -c 'source "$1" && echo "$pkgver"' _ "$RECIPE")

# signed_by <message> <signature> <key file>...: the recipe's own check.
signed_by() { bash -c 'source "$1"; shift; _signed_by "$@"' _ "$RECIPE" "$@" </dev/null >/dev/null 2>&1; }

# new_key <name> <ROOT|SIGNING>: a key pair, the private half in $T/<name>.pem
# and the public half in $T/<name>.pub the way distsign publishes one.
new_key() {
  openssl genpkey -algorithm ed25519 -out "$T/$1.pem" 2>/dev/null
  printf -- '-----BEGIN %s PUBLIC KEY-----\n%s\n-----END %s PUBLIC KEY-----\n' "$2" \
    "$(openssl pkey -in "$T/$1.pem" -pubout -outform DER | tail -c 32 | base64)" "$2" >"$T/$1.pub"
}

# sign <key name> <file> <signature out>
sign() { openssl pkeyutl -sign -rawin -inkey "$T/$1.pem" -in "$2" -out "$3"; }

# sign_tarball <key name> <tarball>: what distsign signs is the file's
# BLAKE2s-256 and its size. Written apart from the recipe, in another language.
sign_tarball() {
  python3 -c '
import hashlib, struct, sys
data = open(sys.argv[1], "rb").read()
sys.stdout.buffer.write(hashlib.blake2s(data).digest() + struct.pack("<Q", len(data)))' "$2" >"$T/message"
  sign "$1" "$T/message" "$2.signature"
}

# verify_in <dir>: the recipe's verify() the way makepkg runs it, with <dir>
# as both the recipe directory (keys/distsign) and where the sources are.
verify_in() {
  bash -c 'source "$1"; SRCDEST=$2 CARCH=$3; cd "$2"; verify' \
    _ "$RECIPE" "$1" "${ARCH:-x86_64}" </dev/null >/dev/null 2>&1
}

signed_by "$KEYS/distsign.pub" "$KEYS/distsign.pub.sig" "$KEYS"/roots/*.pem &&
  pass "a root key the recipe ships signed the signing keys it ships" || fail "no shipped root key signed keys/distsign/distsign.pub"

sed 's/^5/6/' "$KEYS/distsign.pub" >"$T/altered.pub"
cmp -s "$KEYS/distsign.pub" "$T/altered.pub" && fail "the signing keys were not altered"
signed_by "$T/altered.pub" "$KEYS/distsign.pub.sig" "$KEYS"/roots/*.pem &&
  fail "altered signing keys verified" || pass "altered signing keys are refused"

# A whole chain of our own, since nothing small carries Tailscale's signature.
new_key root ROOT
new_key signing SIGNING
new_key stranger SIGNING

# chain <dir>: a recipe directory with our root, signing keys it signed, and
# both tarballs signed by one of them.
chain() {
  mkdir -p "$1/keys/distsign/roots"
  cp "$T/root.pub" "$1/keys/distsign/roots/root.pem"
  cp "$T/signing.pub" "$1/keys/distsign/distsign.pub"
  sign root "$1/keys/distsign/distsign.pub" "$1/keys/distsign/distsign.pub.sig"
  for goarch in amd64 arm64; do
    head -c 70000 /dev/urandom >"$1/tailscale_${pkgver}_$goarch.tgz"
    sign_tarball signing "$1/tailscale_${pkgver}_$goarch.tgz"
  done
}

chain "$T/good"
verify_in "$T/good" && pass "a tarball signed through the chain verifies" || fail "a correctly signed tarball was refused"
ARCH=aarch64 verify_in "$T/good" && pass "so does the aarch64 one" || fail "the aarch64 tarball was refused"

chain "$T/tampered"
printf 'x' | dd of="$T/tampered/tailscale_${pkgver}_amd64.tgz" bs=1 seek=4000 conv=notrunc status=none
verify_in "$T/tampered" && fail "a modified tarball verified" || pass "a modified tarball is refused"

chain "$T/truncated"
truncate -s -1 "$T/truncated/tailscale_${pkgver}_amd64.tgz"
verify_in "$T/truncated" && fail "a truncated tarball verified" || pass "a truncated tarball is refused"

chain "$T/stranger"
sign_tarball stranger "$T/stranger/tailscale_${pkgver}_amd64.tgz"
verify_in "$T/stranger" && fail "a tarball signed by a key outside the signing keys verified" || pass "a tarball signed by a key outside the signing keys is refused"

# The server hands out a new signing key and signs with it, but no root signed it.
chain "$T/swapped"
cp "$T/stranger.pub" "$T/swapped/keys/distsign/distsign.pub"
sign_tarball stranger "$T/swapped/tailscale_${pkgver}_amd64.tgz"
verify_in "$T/swapped" && fail "signing keys no root signed were trusted" || pass "signing keys no root signed are refused, whatever they signed"

# Our chain is sound, but only Tailscale's roots count.
chain "$T/foreign"
rm "$T/foreign/keys/distsign/roots/root.pem"
cp "$KEYS"/roots/*.pem "$T/foreign/keys/distsign/roots/"
verify_in "$T/foreign" && fail "a chain from another root verified against the shipped roots" || pass "a chain from a root the recipe does not ship is refused"

chain "$T/unsigned"
rm "$T/unsigned/tailscale_${pkgver}_amd64.tgz.signature"
verify_in "$T/unsigned" && fail "a tarball with no signature verified" || pass "a tarball with no signature is refused"

# package_with <exit status of the tailscale stub>: the recipe's package() the
# way makepkg runs it, errexit on, over a tree shaped like the tarball's.
package_with() {
  local src="$T/src-$1" tree="$T/src-$1/tailscale_${pkgver}_amd64"
  mkdir -p "$tree/systemd"
  printf '#!/bin/bash\necho "# completions for $2"\nexit %s\n' "$1" >"$tree/tailscale"
  chmod +x "$tree/tailscale"
  touch "$tree/tailscaled" "$src/LICENSE-$pkgver" \
    "$tree/systemd"/{tailscaled.defaults,tailscaled.service,tailscale-wait-online.service,tailscale-online.target}
  bash -c 'set -eE; source "$1"; srcdir=$2 pkgdir=$3 CARCH=x86_64; cd "$srcdir"; package' \
    _ "$RECIPE" "$src" "$T/pkg-$1" </dev/null >/dev/null 2>&1
}

package_with 0 || fail "package() failed with a working CLI"
for file in usr/share/bash-completion/completions/tailscale usr/share/zsh/site-functions/_tailscale usr/share/fish/vendor_completions.d/tailscale.fish; do
  [[ -s $T/pkg-0/$file ]] || fail "$file is missing or empty"
done
pass "package() installs the three completions"
package_with 1 && fail "package() succeeded though the CLI failed to write a completion" || pass "package() fails when the CLI fails to write a completion"
