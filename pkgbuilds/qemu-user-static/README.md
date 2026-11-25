# ARM static QEMU

This aarch64-only split recipe provides qemu-user-static and qemu-user-static-binfmt, built from the upstream QEMU release with Arch's static configure options. It preserves Marcelo’s recipe, imported through omarchy-mac/omarchy-pkgs-aarch64#61, including licensing and binfmt behavior. It does not change x86 packages or the build workers.

## Patches

Three linux-user patches let x86-64 containers run that stock qemu-user can't, such as SQL Server 2022:

- `1000` keeps 64-bit guest mappings inside the guest's address space. With equal host and guest page sizes, qemu passed the host a NULL hint and the kernel placed x86-64 mappings near 2^48, which x86-64 code takes for kernel addresses. Mappings now start at 3/4 of the guest's 47 bits, as the default x86-64 layout places them.
- `1001` passes Linux AIO (`io_setup`, `io_submit`, `io_getevents`, `io_cancel`, `io_destroy`) through to the host when guest and host share the structure layout; stock qemu-user returns ENOSYS.
- `1002` is upstream QEMU `586284af4c2c`, carried unchanged: `sigcontext.trapno` carries the real trap number instead of -1. QEMU 11.2 has it; drop the patch then.

## Updates

Updates are reviewed pins, not automatic. To move to a new QEMU release, update `pkgver` and the tarball's `sha256sums` entry together, check its detached signature against Michael Roth's key `CEACC9E15534EBABB82D3FA03353C9CEF108B584` outside the build, and rebase the patches. The epoch of 1 stays from the earlier Debian repackaging, so upstream versions sort above it. The build fails if a binfmt rule names an emulator the package doesn't ship.

## binfmt rules

The rules are generated with `--ignore-family yes`, so 32-bit ARM binaries are registered even though the script groups them with aarch64; Apple Silicon has no AArch32 execution. Native aarch64 stays excluded. Rules use the persistent and preserve-argv0 flags and never the credential flag.
