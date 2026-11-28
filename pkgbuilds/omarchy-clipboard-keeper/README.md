# Omarchy Clipboard Keeper

A small Wayland client that keeps the last regular clipboard selection in memory after its source application closes. It does not use `wl-clip-persist`, create a history, or modify Omarchy's clipboard history. The next copy replaces the cache and the graphical session ending discards it. There is no expiry timer.

## Design

The client uses `ext-data-control-v1` to capture supported representations in parallel, with bounded nonblocking transfers. It leaves the live application in control of its selection. Only after that selection disappears does it offer the completed snapshot, with the original MIME types and bytes. A private MIME marker prevents recapturing its own offers. It does not touch PRIMARY selection.

Hyprland 0.56.2 can omit the `selection(NULL)` event when the source disconnects. A regression test reproduces this behavior. While a complete external snapshot is cached, the client obtains a fresh data device's initial selection every 100 ms to check whether an owner still exists. These probes inspect metadata only; they do not reread payloads or spawn processes. No such polling happens when the cache is empty or this client already owns the clipboard. After owner loss, it waits another 80 ms and sends a Wayland sync before restoring, to reduce races with a newer copy. Typical handoff latency is up to about 180 ms, plus scheduling.

Wayland has no atomic compare-and-set for selections, so the interval between checking and restoring cannot be eliminated. It also does not distinguish an explicit external clear from owner loss. Use the service's clear signal below when intentionally clearing its cache; a plain `wl-copy --clear` can otherwise cause the previous snapshot to be restored.

## Formats and bounds

- Plain text and its X11 aliases, HTML, Markdown, RTF, file URIs and GNOME file-copy metadata, PNG, JPEG, WebP, GIF, BMP, TIFF, SVG, and Qt images. Unknown private formats are not cached.
- Copies advertising KDE password-manager hints, the KeePassXC marker, or `application/x-kde-onlyReplaceEmpty` are excluded. Applications that do not mark secrets cannot be identified automatically.
- 64 supported MIME types, 32 MiB total bytes per copy, and 64 MiB of retained payloads including ongoing pastes. Capture timeout: 2 seconds; outgoing transfer timeout: 5 seconds; at most 32 concurrent outgoing transfers.
- A new copy immediately invalidates the previous cache, including when the new copy is sensitive, unsupported, oversized, or fails. Active transfers can retain their snapshot for at most 5 seconds.
- The snapshot must finish before the source closes. Incomplete copies are discarded rather than restoring truncated data or stale content. Very fast source closure and large copies can therefore lose persistence.
- No content is written to disk or logs. Core dumps are disabled and released buffers are zeroed. RAM may be swapped according to system policy.
- The first advertised Wayland seat is used. Multiseat operation is not implemented. The compositor must advertise `ext-data-control-v1`.

## Service

The package owns `/usr/lib/systemd/user/omarchy-clipboard-persist.service`. Omarchy's first-run setup and migration enable it with the graphical session. It is independent of the shell's history watcher and survives shell restarts.

```sh
systemctl --user status omarchy-clipboard-persist.service
systemctl --user kill --signal=SIGUSR1 omarchy-clipboard-persist.service
```

The signal clears the active clipboard and this cache. It does not delete the history stored by Omarchy. To stop and disable persistence:

```sh
systemctl --user disable --now omarchy-clipboard-persist.service
```

## Building and testing

```sh
make
make check
```

`wayland-scanner` generates bindings from the installed `wayland-protocols` XML. Runtime dependencies are libwayland-client and libc. Tests use libwayland-server with a socketpair, without connecting to a desktop or changing its clipboard. `makepkg` runs them in `check()`.

The protocol tests exercise live-owner passivity, byte-exact UTF-8/HTML/images, repeated pastes, file metadata, missing owner-loss events, rapid replacement, sensitive and unsupported copies, incomplete captures, stalled or oversized transfers, slow readers, explicit clear, and graceful termination. They also run with AddressSanitizer and UndefinedBehaviorSanitizer. Live Hyprland checks covered Wayland text and PNG owners exiting, replacement, sensitive exclusions, and clearing. Broad application-specific Emacs/Electron and native aarch64 validation remain for upstream review.

This is repository-local source, so `.omarchy/package.json` disables upstream version synchronization. Maintainers update this recipe and source together.
