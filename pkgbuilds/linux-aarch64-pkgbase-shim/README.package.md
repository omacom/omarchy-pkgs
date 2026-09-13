# linux-aarch64-pkgbase-shim

Arch Linux ARM installs its kernel as `/boot/Image` instead of
`usr/lib/modules/<ver>/vmlinuz`. Limine discovers the kernel through
`modules.builtin`, but needs `vmlinuz` beside it to build a boot entry.

This package is one pacman hook. After a kernel package is installed or
upgraded (`usr/lib/modules/*/`), and when the shim itself is installed, it
writes into each package-owned modules directory without native kernel metadata:

- `pkgbase`: compatibility metadata naming the package that owns the directory
- `vmlinuz`: a copy of `/boot/Image` (the owner must own that too)

Reinstalling a kernel refreshes the shim's copy when the image changes, even
if the module-directory version is unchanged. Package-owned files are preserved.

It runs as `85-`, before `90-mkinitcpio-install`, so the usual hook then builds
the initramfs/UKI and the Limine entry. If that hook would not run in the same
transaction (the shim installed after the kernel, or a kernel package that
does not touch `usr/lib/initcpio/`), the script runs
`limine-mkinitcpio-install` itself. Leftover directories of removed kernels
that hold nothing but these two files are cleaned up.

## Retirement

Delete this package when `linux-aarch64` ships `vmlinuz` in its kernel module
directory. Package-owned metadata is never modified, so both approaches can coexist
during the transition.
