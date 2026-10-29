# Hyprland software-rendering backport

Automatic upstream version bumps are held (`sync: false`) while the packaged release carries [Hyprland #16343](https://github.com/hyprwm/Hyprland/pull/16343) as `software-renderer.patch`. `prepare()` applies that patch with `--fuzz=0`. Hyprland's `release_ring: fast` builds edge, rc, and stable from this recipe. Aquamarine changes in the official/ALARM repositories are checked by the separate six-hour `sync-rebuilds` job through `rebuild_on`, which proposes a package release bump for rebuilding.

The hold does not require staying on v0.56.2 until #16343 lands. If a newer upstream release does not yet include the fix, update `pkgver`, rebase the patch and refresh its checksum, and test software rendering and accelerated rendering before publishing. Keep `sync: false` while the backport is needed.

Remove `sync: false` and `software-renderer.patch` in the same change once the selected upstream release includes the #16343 behavior. Set `pkgver` to that release, then test software rendering and accelerated rendering before publishing.

## Group workspace synchronization

`group-workspace-sync.patch` corrects the stale layout-space mismatch behind [omacom/omarchy#10342](https://github.com/omacom/omarchy/issues/10342). A cross-monitor swap can exchange a group's layout space without updating its members' ghost spaces. Destroying the now-empty workspace leaves a live layout referring to an expired parent; switching back from floating to tiled can then crash in dwindle. Synchronize mismatched members through the normal group workspace update before forwarding `onUpdateSpace()`.

This recipe also builds for x86_64 so the fix can reach Intel/AMD installations rather than only ARM. That changes x86_64 from Arch's Hyprland build to Omarchy's patched build and requires a maintainer decision before shipping. Keep the normal release ring: the compositor and its ABI-sensitive plugins must move together with their libraries. This patch does not alter public headers or the upstream commit hash; existing plugin rebuild rules remain in place.

Run the focused regression against an extracted or installed build without replacing the running desktop:

```bash
python3 pkgbuilds/hyprland/test-group-workspace.py \
  --hyprland /path/to/Hyprland --hyprctl /path/to/hyprctl \
  --parent-display "$WAYLAND_DISPLAY" \
  --results-dir /path/to/new/test-results
```

The test requires Python 3, foot, the compositor's runtime libraries, and an existing Wayland session. It launches a separate nested compositor with private runtime/config/state/cache directories and no desktop autostart or plugins. The explicitly selected parent display is used only for rendering a temporary nested window; all test IPC and clients target the child identified by its PID. Hyprland 0.56.2 cannot initialize with the former headless-only approach. After creating two child headless test outputs, the harness removes the child's nested output so a third monitor cannot affect directional swaps. No package installation or desktop configuration changes are needed.

`--parent-display` defaults to the current Wayland display, accepts absolute socket paths, and must refer to an existing socket. `--results-dir` is optional and must be a new directory; it preserves logs and test configuration for all four cases (one/two-member groups, each against an ordinary window or another group). Each case verifies workspace/monitor assignments, group membership, ten float/retile cycles, and client unmapping before shutdown. It must fail against unpatched 0.56.2 and pass against the patched binary; the independently tested local runtime-hook version is supporting evidence, not a substitute for testing the native package. ARM runtime verification must be performed on an ARM runner before shipping. Apply the patch with `--fuzz=0` on upgrades and remove it when the selected upstream release includes equivalent synchronization.

## Output and VRR fixes

`wl-output-global-grace.patch` keeps a removed `wl_output` global for five seconds before destroying it, as wlroots does. Without it, an output that comes and goes within a roundtrip, such as a dock's monitor flapping while its tunnel comes up, disconnects every client that has not bound it yet with "global wl_output (N) is unavailable". `monitor-rule-vrr.patch` makes a config reload apply a monitor rule's `vrr`; without it, changing only `vrr` is ignored until the next session. Neither is upstream yet. Rebase both with `--fuzz=0` on a version bump, and drop each once the selected release carries the fix.
