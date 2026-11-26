# Hyprland

Automatic upstream version bumps are held (`sync: false`) because `omarchy-hyprland-titlebars` requires the exact Hyprland it was built against, and a new Hyprland release can break the plugin's build. 0.57.0 did, so the plugin's rebuild failed and every `pacman -Syu` that offered Arch's 0.57.0 stopped on its `hyprland=0.56.2` dependency. Bump Hyprland by hand, in the same change as a plugin release that builds against it. Hyprland is on the normal ring, so a merge publishes it to edge only, and rc and stable get it by promotion together with the plugin. Aquamarine changes in the official/ALARM repositories are checked by the separate six-hour `sync-rebuilds` job through `rebuild_on`, which proposes a package release bump for rebuilding.

## Output, VRR, and NVIDIA fixes

`wl-output-global-grace.patch` keeps a removed `wl_output` global for five seconds before destroying it, as wlroots does. Without it, an output that comes and goes within a roundtrip, such as a dock's monitor flapping while its tunnel comes up, disconnects every client that has not bound it yet with "global wl_output (N) is unavailable". `monitor-rule-vrr.patch` makes a config reload apply a monitor rule's `vrr`; without it, changing only `vrr` is ignored until the next session. `nvidia-egl-teardown.patch` releases the EGL context before Hyprland terminates the display, which NVIDIA's EGL otherwise crashes on at exit. Two earlier carries, the removed-output session-lock fix and the dmabuf format-table fix, shipped upstream in 0.57.1 and were dropped here. Rebase each patch with `--fuzz=0` on a version bump, and drop each once the selected release carries the fix.

## Pointer focus through a press

`held-pointer-without-keyboard-focus.patch` keeps a pressed surface's pointer focus until the button is released, whether or not anything holds keyboard focus. Upstream keeps it only while some surface has keyboard focus, so on an empty workspace a drag that starts on a layer surface ends the moment the pointer leaves it: Hyprland hit-tests every motion afresh and hands the pointer to whatever is underneath. Omarchy's bar needs its drags to leave its strip (a widget pulled off the bar is removed, and the bar is dragged to another edge), and without this it had to keep a transparent surface over its whole screen, about 155 MiB of VRAM per 4K screen. The requirement arrived as an incidental check in the 2024 wl-data-device rewrite; drop the patch once upstream holds an implicit grab without keyboard focus.

## x86_64

This recipe also builds for x86_64, so PCs take this build instead of Arch's `extra/hyprland`: `[omarchy]` comes before `[extra]` in Omarchy's `pacman.conf`. That gives PCs the patches above and keeps them on the Hyprland the titlebars plugin was built against when Arch moves first. Move both architectures and the plugin to a newer Hyprland in one change, with a `pkgrel` above Arch's for the same version so a machine already on Arch's build moves to this one.
