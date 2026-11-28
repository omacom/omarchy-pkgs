# Slack Desktop

Slack publishes Linux builds for x86_64 only. On x86_64 this package installs that `.deb` unchanged, replacing the AUR `slack-desktop` recipe with one Omarchy controls. On AArch64 it runs the same application code on the AArch64 build of the Electron release Slack ships with, so `slack-desktop` resolves to a working package on ARM Omarchy installs too. Everything below applies to the AArch64 build only.

## Electron version

`_electronver` must equal the Electron version inside Slack's `.deb` (`usr/lib/slack/version`). The upstream watch reads that file from each new `.deb` (`source_variables` in `.omarchy/package.json`), writes it to `_electronver` and hashes the matching Electron download, so a Slack release that moves to a new Electron needs no hand edit. `prepare()` still refuses to build when the two differ, which catches a recipe edited by hand.

## Native modules

Slack's app carries eight x86_64 Node addons. None can load on AArch64, so they are removed, and the build fails on any other foreign binary so a new native module is reviewed before it ships.

Three are required while Slack boots on Linux and are replaced by JavaScript:

- `file-handler-info` and `electron-native-auth` are MIT-licensed and their Linux builds compile no-op implementations (`impl_none.cc`, `addon_none.cc`). The replacements return the same results.
- `@tinyspeck/slack-desktop-utils` is closed source. Its replacement throws `Method not implemented` from every native call, which is the error Slack's own wrapper uses for methods a platform lacks. Slack catches it, so these Linux features are unavailable: double-press and combo global shortcuts, the huddle screen-share border overlay, audio device detail lookups, clipboard set-and-paste, and haptics.

`@tinyspeck/native-keymap` already catches a missing addon and returns defaults, so keyboard layout detection reports `unknown`. The other four addons are Windows/macOS helpers that Slack does not use on Linux.

## Validation

Installed and used on an aarch64 Omarchy machine (N1x). Features listed above as unavailable were not expected to work and were not checked.
