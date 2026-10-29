# Hyprland software-rendering backport

Automatic upstream version bumps are held (`sync: false`) while the packaged release carries [Hyprland #16343](https://github.com/hyprwm/Hyprland/pull/16343) as `software-renderer.patch`. `prepare()` applies that patch with `--fuzz=0`. Hyprland's `release_ring: fast` builds edge, rc, and stable from this recipe. Aquamarine changes in the official/ALARM repositories are checked by the separate six-hour `sync-rebuilds` job through `rebuild_on`, which proposes a package release bump for rebuilding.

The hold does not require staying on v0.56.2 until #16343 lands. If a newer upstream release does not yet include the fix, update `pkgver`, rebase the patch and refresh its checksum, and test software rendering and accelerated rendering before publishing. Keep `sync: false` while the backport is needed.

Remove `sync: false` and `software-renderer.patch` in the same change once the selected upstream release includes the #16343 behavior. Set `pkgver` to that release, then test software rendering and accelerated rendering before publishing.

## Output and VRR fixes

`wl-output-global-grace.patch` keeps a removed `wl_output` global for five seconds before destroying it, as wlroots does. Without it, an output that comes and goes within a roundtrip, such as a dock's monitor flapping while its tunnel comes up, disconnects every client that has not bound it yet with "global wl_output (N) is unavailable". `monitor-rule-vrr.patch` makes a config reload apply a monitor rule's `vrr`; without it, changing only `vrr` is ignored until the next session. Neither is upstream yet. Rebase both with `--fuzz=0` on a version bump, and drop each once the selected release carries the fix.

## XWayland drag-and-drop fix

`xwayland-dnd-clipboard.patch` stops `sendSelectionToDevice` from creating an X11 clipboard offer when focus moves to an XWayland window. That offer cleared `m_dndDataOffers`, so dragging a file from a Wayland app such as Nautilus into an XWayland app such as VLC dropped the clipboard contents instead of the file ([hyprwm/Hyprland discussion #11179](https://github.com/hyprwm/Hyprland/discussions/11179)). The upstream PR for it was closed without merging, so the fix is not in any Hyprland release yet. Rebase it with `--fuzz=0` on a version bump, and drop it once the selected release carries an equivalent fix.
