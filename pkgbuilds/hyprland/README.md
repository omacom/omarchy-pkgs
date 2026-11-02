# Hyprland

Automatic upstream version bumps are held (`sync: false`) because `omarchy-hyprland-titlebars` requires the exact Hyprland it was built against, and a new Hyprland release can break the plugin's build. 0.57.0 did, so the plugin's rebuild failed and every `pacman -Syu` that offered Arch's 0.57.0 stopped on its `hyprland=0.56.2` dependency. Bump Hyprland by hand, in the same change as a plugin release that builds against it. Hyprland is on the normal ring, so a merge publishes it to edge only, and rc and stable get it by promotion together with the plugin. Aquamarine changes in the official/ALARM repositories are checked by the separate six-hour `sync-rebuilds` job through `rebuild_on`, which proposes a package release bump for rebuilding.

## Output, VRR, and NVIDIA fixes

`wl-output-global-grace.patch` keeps a removed `wl_output` global for five seconds before destroying it, as wlroots does. Without it, an output that comes and goes within a roundtrip, such as a dock's monitor flapping while its tunnel comes up, disconnects every client that has not bound it yet with "global wl_output (N) is unavailable". `monitor-rule-vrr.patch` makes a config reload apply a monitor rule's `vrr`; without it, changing only `vrr` is ignored until the next session. `nvidia-egl-teardown.patch` releases the EGL context before Hyprland terminates the display, which NVIDIA's EGL otherwise crashes on at exit. None is upstream yet. Rebase each with `--fuzz=0` on a version bump, and drop each once the selected release carries the fix.

## X11 scale

`xwayland-scale.patch` adds `xwayland:scale` ([ParkerrDev/xscale](https://github.com/ParkerrDev/xscale)): one scale that every X11 client renders at, so X11 apps are sharp and the size of their Wayland selves on every monitor, instead of upscaled and blurry, or tiny under `force_zero_scaling`. Hyprland scales the X11 windows itself, so it works with Arch's `xorg-xwayland` and changes no protocol. At `0`, the default, it changes nothing. It is not upstream yet. Apply it after the other patches, rebase it with `--fuzz=0` on a version bump, and drop it once the selected release carries the setting.

## x86_64

This recipe also builds for x86_64, so PCs take this build instead of Arch's `extra/hyprland`: `[omarchy]` comes before `[extra]` in Omarchy's `pacman.conf`. That gives PCs the patches above and keeps them on the Hyprland the titlebars plugin was built against when Arch moves first. Move both architectures and the plugin to a newer Hyprland in one change, with a `pkgrel` above Arch's for the same version so a machine already on Arch's build moves to this one.
