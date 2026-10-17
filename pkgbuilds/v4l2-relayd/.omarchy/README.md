# v4l2-relayd - reset output on idle

## Overview

Omarchy carries a small patch for `v4l2-relayd` that resets the output pipeline after a real camera streaming session ends.

Without this, stale `v4l2loopback` state can cause format negotiation failures when switching between camera apps.

## What the patches do

### `patches/reset-output-on-idle.patch`

Adds the package source patch file:

```text
0001-reset-output-on-idle.patch
```

That source patch modifies `src/v4l2-relayd.c` to:

- track how long the input pipeline was active
- ignore brief PipeWire/WirePlumber probes
- after a real streaming session longer than 3 seconds, reset the output pipeline from `READY` back to `PLAYING`

### `patches/add-reset-output-source.patch`

Updates `PKGBUILD` to:

- include `0001-reset-output-on-idle.patch` in `source=()`
- add a `SKIP` checksum for the local patch file
- apply the patch in `prepare()`

## pkgrel

`package.json` includes a `pkgrel` suffix/offset so users who already received Omarchy's previous `0.2.0-2` build will upgrade to `0.2.0-2.1`.

The `pkgrel` metadata is automatically removed by `bin/sync-aur` when AUR moves to a new `pkgver`.

## Testing

```bash
bin/sync-aur v4l2-relayd
bin/repo build --package v4l2-relayd
```
