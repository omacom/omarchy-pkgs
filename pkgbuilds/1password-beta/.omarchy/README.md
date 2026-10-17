# 1Password Beta - aarch64 Support

## Overview

`post-sync.sh` adds aarch64 (ARM64) support to the AUR `1password-beta` PKGBUILD after each sync.

This is implemented as a dynamic sync hook instead of a static patch because the aarch64 checksums include the current upstream version and need to be refreshed whenever AUR updates `_tarver`.

## Background

1Password officially provides ARM64 builds for Linux:

- https://downloads.1password.com/linux/tar/beta/aarch64/
- https://downloads.1password.com/linux/tar/stable/aarch64/

The AUR PKGBUILD only supports x86_64.

## Changes Made

1. Adds aarch64 to the arch array: `arch=('x86_64' 'aarch64')`
2. Uses architecture-specific source arrays:
   - x86_64: `.x64.tar.gz`
   - aarch64: `.arm64.tar.gz`
3. Keeps the AUR x86_64 checksums
4. Downloads and calculates current aarch64 checksums during sync
5. Uses `${_archdir}` for source directory names instead of hardcoded `.x64`
6. Omarchy sync drops AUR-only `.SRCINFO` after rewriting the PKGBUILD

## Testing

```bash
bin/sync-aur 1password-beta
bin/repo build --arch aarch64 --package 1password-beta
```

The aarch64 build should download from:

```text
https://downloads.1password.com/linux/tar/beta/aarch64/1password-<version>.arm64.tar.gz
```
