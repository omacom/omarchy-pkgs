#!/bin/bash
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/PKGBUILD"
test_root=$(mktemp -d)
trap 'chmod -R u+rwX "$test_root"; rm -rf "$test_root"' EXIT
srcdir="$test_root/source with spaces"
mkdir -p "$srcdir/src" "$test_root/bin"
reset_inputs() {
  chmod -R u+rwX "$srcdir"
  rm -f "$srcdir/src/fuxi-gmac-ioctl.c"
  printf 'static const struct net_device_ops operations = { };\n' >"$srcdir/src/fuxi-gmac-net.c"
  printf 'yt6801-objs := fuxi-gmac-net.o\n' >"$srcdir/src/Makefile"
}
reject() {
  if check; then
    echo "FAIL $1" >&2
    exit 1
  fi
}
reset_inputs
check
: >"$srcdir/src/fuxi-gmac-ioctl.c"
reject 'dormant private implementation'
reset_inputs
printf '.ndo_do_ioctl = handler,\n' >>"$srcdir/src/fuxi-gmac-net.c"
reject 'private netdev callback'
reset_inputs
printf 'yt6801-objs += fuxi-gmac-ioctl.o\n' >>"$srcdir/src/Makefile"
reject 'private object'
reset_inputs
rm "$srcdir/src/Makefile"
reject 'missing input'
reset_inputs
chmod 000 "$srcdir/src/Makefile"
if (( EUID != 0 )); then reject 'unreadable input'; fi
reset_inputs
printf '#!/bin/bash\nexit 2\n' >"$test_root/bin/grep"
chmod +x "$test_root/bin/grep"
PATH="$test_root/bin:$PATH" reject 'grep I/O error'
printf 'PASS private interface check accepts clean input and rejects callbacks, objects, missing/unreadable input and grep errors\n'
