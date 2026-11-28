# speakersafetyd

Asahi Linux's speaker safety daemon. It models the voice coil and magnet temperature of each Apple Silicon speaker from the amps' current and voltage sense, and cuts the gain before they overheat. `aurora-audio` and `omarchy-mac` depend on it.

Built from the AsahiLinux/speakersafetyd 3.0.0 tag, with no patches. asahi-alarm's J504 patch (full speaker names in `conf/apple/j504.conf`) is upstream commit 31c55fb, released in 2.0.2. Upstream relicensed to GPL-2.0-only in 3.0.0; the MIT notice for the older code ships beside it. The recipe keeps asahi-alarm's package name and a version at or above theirs, so a Mac that has asahi-alarm's build takes this one at its next update.

The unit, udev rule and configs install where asahi-alarm put them. `speakerguardd`'s drop-in (`/usr/lib/systemd/system/speakersafetyd.service.d/50-j700-guard.conf`) and `omarchy-mac`'s preset keep applying to `speakersafetyd.service`.
