# Superwhisper

Packages the vendor's signed portable x86_64 Linux archive under `/opt/superwhisper`, with a launcher, desktop entries, user service, fonts, icons and the fcitx5 text-commit addon. Local models are downloaded through Superwhisper's settings; they are not bundled in the package.

`sync-upstream` follows stable releases from `superultrainc/superwhisper-linux-releases` (`v1.0.0` and later); prereleases are ignored. The vendor version is kept in `_version`. The recipe verifies the archive's SHA256 and Minisign signature against the checked-in vendor release key. Packaging never runs the downloaded installer.

Omarchy's Setup → Defaults → Dictation → Superwhisper invokes `/usr/share/superwhisper/setup-user`, then configures its shortcuts and saves Superwhisper as the default backend. The package does not add Omarchy menu extensions and omits the portable installer’s menu-writing helper. User setup enables the packaged service, links the vendor's panel and agent skill, and retires known portable-install wrappers and unit overrides with backups. Preferences, history and downloaded models are retained. Package updates come from OPR; the portable install's private update timer is disabled.

Omarchy loads the selected backend's generated `~/.config/superwhisper/shortcuts.lua` bridge itself, so no Superwhisper block is required in the user's Hyprland files. The bridge retains cancellation and correction-based vocabulary learning alongside Omarchy's shared dictation commands.

The launcher redirects the vendor’s generated Hyprland include to a private, unloaded file for both the daemon and CLI. User setup waits for daemon readiness. The portable updater is disabled and refused by the packaged launcher. The archive is verified before extraction, its version is checked, and the bundled panel uses explicit Omarchy palette references for Qt 6.12.

Fresh profiles start with Alt+Space toggle, no native hold, and Escape cancellation before the daemon starts, avoiding a conflict with Omarchy’s Right Alt binding. Existing preferences remain unchanged.

Panel discovery is asynchronous: user setup retries placement, leaves a pending marker if the shell is unavailable, and retries on the next setup without moving an already placed panel. Bundled component license notices are installed under `/usr/share/licenses/superwhisper-bin/`.
