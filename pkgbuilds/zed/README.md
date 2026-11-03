# Zed on ARM

Adapted from the tested ARM recipe in omarchy-mac/omarchy-pkgs-aarch64 #25, retaining the AUR zed-bin contributor attribution. Uses official ARM64 vendor binaries, system libraries and the canonical `zed` name. No x86_64 package is added; Arch supplies that architecture separately.

The wrapper sets `ZED_UPDATE_EXPLANATION` so pacman owns updates. The existing GitHub release watch selects stable version tags and checks the ARM asset through the common upstream updater. Upstream's scheduled sync creates or updates its normal review PR; maintainers need GitHub PR notifications enabled and should monitor failed sync runs too. Initial version 1.20.2 preserves the validated downstream baseline; live release discovery already observes the newer 1.21.0, which requires its own artifact qualification.

This package supplies the dependency needed by omacom/omarchy-pkgs #537 (`omazed`). Publish and validate it before enabling that dependency on ARM. It conflicts with alternate Zed packages; it does not silently remove them.

Before this draft becomes ready, require upstream's clean ARM build/install checks and editing a disposable file in a disposable GUI session. CLI version output and ELF inspection do not prove GPU rendering or editing behavior.
