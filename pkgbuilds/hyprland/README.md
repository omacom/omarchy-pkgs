# Hyprland software-rendering backport

Upstream version bumps are held (`sync: false`) while v0.56.2 carries [Hyprland #16343](https://github.com/hyprwm/Hyprland/pull/16343) as `software-renderer.patch`. `prepare()` applies that patch with `--fuzz=0`. Hyprland's `release_ring: fast` builds edge, rc, and stable from this recipe, so the version stays pinned until the backport is removed on purpose. Aquamarine changes still rebuild the package through `rebuild_on`.

Remove `sync: false` and `software-renderer.patch` in the same change once the selected upstream release includes the #16343 behavior. Set `pkgver` to that release, then test software rendering and accelerated rendering before publishing.
