# Obsidian on ARM

This is the canonical `obsidian` package, extracted from omacom/omarchy-pkgs #240 at `dcef132b2df11bb762e233ea8c6af3110f079b67`. It repackages the official ARM64 desktop tarball and preserves the original contributor attribution and Electron/Chromium license files.

The package owns the installed application bundle and Electron runtime. `chrome-sandbox` is installed without setuid: Chromium's sandbox uses unprivileged user namespaces, which Arch-family kernels allow. A system that disables them must re-enable them rather than launch Obsidian with `--no-sandbox`. Obsidian's user-controlled in-app updater may separately update application code; no updater-disabling patch is applied. See https://obsidian.md/help/updates.

The package-local upstream hook selects stable desktop releases containing the exact ARM64 tarball, ignoring mobile-only tags. Missing SHA256 metadata on the selected desktop release fails rather than silently selecting an older installer. The offline tests in `test-upstream.py` run in the package's `check()`; run them directly with `python pkgbuilds/obsidian/test-upstream.py`. Upstream's scheduled sync opens or updates its normal review PR; maintainers need GitHub PR notifications enabled and should monitor failed sync runs too.

This package conflicts with `obsidian-appimage` and `obsidian-bin`. It does not automatically remove them or migrate users. Adoption in Omarchy Mac requires a separate change to the existing ARM preinstall/removal mappings. Do not modify vaults or user configuration as part of the package transaction.

Before this draft is ready, validate clean ARM installation, desktop/CLI paths, native payload architecture and opening/editing a disposable vault in a disposable GUI session. Existing AppImage operation does not validate this tarball package. The two named vendor x86-only addons are removed; any newly introduced foreign executable requires review.
