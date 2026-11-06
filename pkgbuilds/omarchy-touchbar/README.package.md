# omarchy-touchbar

One prebuilt aarch64 package supplies the modified tiny-dfr daemon and its matching Omarchy shell plugin. It adds an animated Omarchy menu logo, tap/hold dictation through the selected backend, adaptive brightness and event-driven system-font following. It provides/conflicts with `tiny-dfr` while retaining its service and udev interfaces.

Supported hardware is limited to the Apple Silicon 13-inch MacBook Pro models `apple,j293` (M1 / MacBookPro17,1) and `apple,j493` (M2 / Mac14,7). Physical validation is on M1; M2 has model-detection fixture coverage rather than a hardware test. Intel Macs and other Apple Silicon models are excluded by the integration's hardware guards.

## Coordinated integration

[Omarchy PR #17826](https://github.com/omacom/omarchy/pull/17826) supplies guarded fresh-install root/user setup, the existing-user `omarchy install touchbar` command and removal/rollback. This package is that PR's publication dependency. Merge and publish this package before enabling the main integration on a release channel; the main setup fails clearly when the configured repositories cannot supply it.

The runtime plugin consists of regular package-owned files under `/usr/share/omarchy/shell/plugins/touchbar`; pacman upgrades it with the native daemon in one transaction. Client installation, first boot and updates do not clone sources, invoke makepkg or install a compiler. Rust compilation happens only on the package builder. The package includes a protected root activation/font helper and a portable generated animated configuration; it does not ship videos, test fixtures or a git checkout.

## Pinned provenance and updates

- Native renderer: [guirossibrum/tiny-dfr](https://github.com/guirossibrum/tiny-dfr), commit `6b77e96f8cef5ddf5c6c5c5b4a003b477f342ec9`.
- Matching plugin: [guirossibrum/omarchy-touchbar](https://github.com/guirossibrum/omarchy-touchbar), commit `1c1f34ac84459017b320123b57f5e14e7427ab7a`.

Omarchy owns and tests the privileged activation/font helpers and release renderer in `default/touchbar/`. This recipe retrieves those three files from Omarchy commit `f2b3549cbbe6c65cc8c947274765c6a865725176` (`_integration_commit`) with SHA-256 verification. The package install hook is owned here. There is one canonical copy of each input, so changes require a pin/hash update rather than copying helper code between repositories.

`sync: false` is intentional initially: the native revision, plugin schema and local privileged helpers must be qualified together. A release or moving-branch watcher would advance only part of that contract. Update the pins through a reviewed package PR, rerun the combined native/configuration and setup checks, and bump the package version/release so a published filename is never reused. No upstream watch or automatic upstream update is configured.

## Publication

This package uses the existing normal release ring. For an untrusted contributor, the only initial maintainer action is the `build-approved` label (and GitHub workflow approval if required). Existing CI then builds aarch64 natively, runs the repository's required checks and can auto-merge a green package-only PR. The existing publication workflow signs and publishes the merged artifact to `edge`; `rc` and `stable` receive it through the normal promotion process. No signing credentials, release workflow or repository trust changes are requested by this contribution.

The package directory is the canonical recipe once merged. Omarchy runtime setup consumes the versioned binary package; it does not need a duplicate recipe or manual synchronization with the main repository.

Package release 3 includes the reviewed font-rule retirement fixes. Main setup now requires that minimum before activation, preserves edited hooks, rescans live plugin discovery and completes user cleanup after package removal.
