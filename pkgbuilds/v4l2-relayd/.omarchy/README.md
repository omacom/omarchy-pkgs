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

The recipe's `pkgrel` carries a fractional part (`2.2`) so machines that received Omarchy's earlier `0.2.0-2` builds upgrade. The upstream watch resets it to `1` with the next upstream version.

## Testing

```bash
bin/sync-upstream v4l2-relayd
bin/build --package v4l2-relayd
```
