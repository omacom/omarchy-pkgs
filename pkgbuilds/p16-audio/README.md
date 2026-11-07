# P16 audio userspace package

`p16-audio` provides the persistent user graph and jack watcher for the ASUS ProArt P16 H7607BA. The speakers graph uses the reviewed 3 kHz LR4 crossover with unity path gain and an LSP limiter at -1 dBFS; both physical sinks stay at unity and the unified `p16_two_way` sink controls both crossover bands. Dolby input remains at unity, so desktop volume controls the combined sink after Dolby.

When the headphone jack is reported, the watcher stops the crossover graph, disables both internal speaker paths, and starts a separate full-range virtual jack graph without the speaker tuning. It does not alter a Bluetooth or HDMI default sink. ALSA jack events are read from `alsactl monitor`; initial state is read once at login.

The Dolby chain is derived from ASUS profile XML `SOUNDWIRE_SDCAFUNCTION_10_MAN_01FA_FUNC_4243_SUBSYS_14841043.xml`, converted by `speaker-tuning-to-easyeffects` revision `81a8f293613ad06a3908c3a63866b40dadb1fb7e`, dynamic/Balanced, bass enhancer disabled. It is an approximation of the speaker tuning and is not Dolby Atmos software. The 3 kHz LR4 crossover is a new configuration based on the measured split point and existing public trial parameters; it is not copied from licensed source. The Dolby IRS and EQ/dynamics values derive from ASUS OEM tuning data; redistribution rights for those OEM-derived assets have not been established, so the package is a local candidate pending that check. The converter implementation is MIT-licensed (Copyright Antoine Cellerier, 2026). The profile is not Dolby Atmos software.


## Account scope and installer privileges

Physical-output hiding rules live in the configured account's WirePlumber
configuration, next to its enabled replacement graph. Other accounts retain the
normal physical outputs. Both online and offline account setup write home files
only after dropping privileges with runuser. A user-controlled home symlink
cannot redirect root writes. The previous global rule is retired only if its
regular-file content exactly matches this package's generated rules; customized
administrator rules are preserved. On upgrades, a matching generated per-user
rule is accepted as package-owned; an edited file or symlink at that path is
retained rather than overwritten.

Run `sudo bash tests/p16-audio-install-user-units.sh` from the repository root.
The four regression cases use temporary directories and the unprivileged nobody
account: offline setup, online reload, a hostile systemd symlink, and preserving
custom global rules. No real audio service or user configuration is changed.


Uninstall runs the same helper in `--remove` mode before package files disappear.
It removes only the matching per-user hiding rule and its own service link,
including for an offline account. Customized rules/links remain untouched and
cleanup is idempotent. The installer regression suite covers nine cases,
including uninstall and hostile symlinks; all home operations run as the account.

When uninstall removes its matching hiding rule in an active user session, it
tries to restart the already-running WirePlumber service after deleting that
rule, so the physical outputs are recreated with their normal media classes.
Offline accounts and preserved custom rules do not trigger that restart.

## Speaker host restart recovery

Both speaker capture sinks start muted. The policy tracks their PulseAudio
indices and restores saved volume/mute when either is recreated, before any
new state is saved. Partial graph snapshots never overwrite the saved file.
Normal changes on the complete restored graph continue to persist, and
Bluetooth/HDMI defaults are not changed during recovery.

`check()` runs the nine mocked jack/state regression cases; a separate isolated
PipeWire/Pulse server test also recovered exact volume/mute after host restart.
These checks do not replace physical wired-headphone or acoustic validation.
