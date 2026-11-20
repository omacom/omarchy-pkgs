# Hyprland

Automatic upstream version bumps are held (`sync: false`) because `omarchy-hyprland-titlebars` requires the exact Hyprland it was built against, and a new Hyprland release can break the plugin's build. 0.57.0 did, so the plugin's rebuild failed and every `pacman -Syu` that offered Arch's 0.57.0 stopped on its `hyprland=0.56.2` dependency. Bump Hyprland by hand, in the same change as a plugin release that builds against it. Hyprland is on the normal ring, so a merge publishes it to edge only, and rc and stable get it by promotion together with the plugin. Aquamarine changes in the official/ALARM repositories are checked by the separate six-hour `sync-rebuilds` job through `rebuild_on`, which proposes a package release bump for rebuilding.

## Output, VRR, and NVIDIA fixes

`wl-output-global-grace.patch` keeps a removed `wl_output` global for five seconds before destroying it, as wlroots does. Without it, an output that comes and goes within a roundtrip, such as a dock's monitor flapping while its tunnel comes up, disconnects every client that has not bound it yet with "global wl_output (N) is unavailable". `monitor-rule-vrr.patch` makes a config reload apply a monitor rule's `vrr`; without it, changing only `vrr` is ignored until the next session. `nvidia-egl-teardown.patch` releases the EGL context before Hyprland terminates the display, which NVIDIA's EGL otherwise crashes on at exit. Two earlier carries, the removed-output session-lock fix and the dmabuf format-table fix, shipped upstream in 0.57.1 and were dropped here. Rebase each patch with `--fuzz=0` on a version bump, and drop each once the selected release carries the fix.

## NV12 for Chromium's hardware video encoder

`advertise-nv12-opt-in.patch` adds an environment variable, `HYPRLAND_EGL_ADVERTISE_NV12`. Hyprland 0.57 stopped advertising YUV dmabuf formats because its renderer draws them without converting to RGB ([hyprwm/Hyprland#16570](https://github.com/hyprwm/Hyprland/pull/16570)). Chromium's VA-API video encoder takes its input only as NV12 dmabufs and will not allocate a format the compositor does not advertise, although it never shows those buffers, so its hardware encode fails on the first frame. With the variable set, NV12 and P010 are advertised again; unset, nothing changes. A client that attaches such a buffer to a surface is still drawn with wrong colours, so nothing in Omarchy sets the variable yet. Drop the patch when Hyprland advertises YUV again.

## x86_64

This recipe also builds for x86_64, so PCs take this build instead of Arch's `extra/hyprland`: `[omarchy]` comes before `[extra]` in Omarchy's `pacman.conf`. That gives PCs the patches above and keeps them on the Hyprland the titlebars plugin was built against when Arch moves first. Move both architectures and the plugin to a newer Hyprland in one change, with a `pkgrel` above Arch's for the same version so a machine already on Arch's build moves to this one.
