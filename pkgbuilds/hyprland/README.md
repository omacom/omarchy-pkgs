# Hyprland software-rendering backport

Automatic upstream version bumps are held (`sync: false`) while the packaged release carries [Hyprland #16343](https://github.com/hyprwm/Hyprland/pull/16343) as `software-renderer.patch`. `prepare()` applies that patch with `--fuzz=0`. Hyprland's `release_ring: fast` builds edge, rc, and stable from this recipe. Aquamarine changes in the official/ALARM repositories are checked by the separate six-hour `sync-rebuilds` job through `rebuild_on`, which proposes a package release bump for rebuilding.

The hold does not require staying on v0.56.2 until #16343 lands. If a newer upstream release does not yet include the fix, update `pkgver`, rebase the patch and refresh its checksum, and test software rendering and accelerated rendering before publishing. Keep `sync: false` while the backport is needed.

Remove `sync: false` and `software-renderer.patch` in the same change once the selected upstream release includes the #16343 behavior. Set `pkgver` to that release, then test software rendering and accelerated rendering before publishing.

## Hidden-window decoration cleanup

`hidden-decoration-unload.patch` moves pending decoration destruction ahead of the mapped/hidden guard in Hyprland 0.56.2. Plugin unload must destroy decorations and release their input listeners before `dlclose`, even when their owner is a swallowed or unmapping window. The cleanup ordering is already present in upstream's `CWindowPresentation::updateDecorations()` after the desktop-view refactor (commit `af0d014cb26f536d8cb7cab2b9d5784f69767c8a`). Drop this backport once the packaged release contains that behavior.

This recipe also builds x86_64 so the correction can reach the affected architecture. See [Omarchy #15260](https://github.com/omacom/omarchy/issues/15260) for the original crash. The regression uses a genuinely hidden swallowed terminal, unloads the titlebar plugin, and sends real virtual-pointer events afterward.

The package `check()` compiles the actual prepared `CWindow::updateWindowDecos()` method against a small ownership fixture. It verifies destruction and listener release for visible, hidden, and unmapped owners, preserves updates to surviving decorations, and checks repeated cleanup does not destroy them twice. The unmodified 0.56.2 method fails the hidden-owner case. The graphical titlebar verifier supplies the separate end-to-end unload/input regression.
