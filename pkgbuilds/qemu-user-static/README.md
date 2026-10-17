# ARM static QEMU

This aarch64-only split recipe provides qemu-user-static and qemu-user-static-binfmt using Debian’s static ARM64 binaries. It preserves Marcelo’s recipe, imported through omarchy-mac/omarchy-pkgs-aarch64#61, including licensing and binfmt behavior. It does not change x86 packages or the build workers.

## Updates

Updates are reviewed pins, not automatic. To move to a new Debian 13 revision, update `_debver`, `pkgver` (Debian epoch.upstream.revision), `_snapshot` (the snapshot.debian.org SHA1 of the ARM64 `qemu-user` archive) and `sha256sums_aarch64` together, and confirm both Debian ordering and `vercmp` advance. A one-time Arch epoch of 1 moves away from the previous upstream-only version.

## binfmt rules

The rules are generated with `--ignore-family yes`, so 32-bit ARM binaries are registered even though the script groups them with aarch64; Apple Silicon has no AArch32 execution. Native aarch64 stays excluded. Rules use the persistent and preserve-argv0 flags and never the credential flag.
