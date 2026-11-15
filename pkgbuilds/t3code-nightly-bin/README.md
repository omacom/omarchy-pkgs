# T3 Code Nightly

`t3code-nightly-bin` packages upstream nightly releases for x86_64 and aarch64.
Run `t3code-nightly` for the desktop or `t3-nightly` for the server CLI.
The app launcher entry is **T3 Code (Nightly)**. Optional Electron flags go in
`~/.config/t3code-nightly-flags.conf` (or under `$XDG_CONFIG_HOME`).

The package can be installed alongside `t3code-bin`, with separate binaries,
icons, and desktop entries. Upstream still shares its application data and URL
schemes between channels: installing both does not create isolated profiles.

The upstream watch accepts only `vX.Y.Z-nightly.YYYYMMDD.N` releases. Arch versions
replace the hyphen with an underscore; downloads retain upstream's original tag
and filenames. Both architecture checksums must be available before an update.
A nightly is picked up once it is 30 minutes old, because upstream publishes the release before its AppImages finish uploading.
