# speakersafetyd

Asahi Linux's speaker safety daemon. It models the voice coil and magnet temperature of each Apple Silicon speaker from the amps' current and voltage sense, and cuts the gain before they overheat. `aurora-audio` and `omarchy-mac` depend on it.

Built from the AsahiLinux/speakersafetyd 2.0.1 tag, with asahi-alarm's J504 patch (full speaker names in `conf/apple/j504.conf`, upstream commit fd95fe3). The recipe follows asahi-alarm's: same name, same `pkgver`, a higher `pkgrel`, so a Mac that has asahi-alarm's build takes this one at its next update.

The unit, udev rule and configs install where asahi-alarm put them. `speakerguardd`'s drop-in (`/usr/lib/systemd/system/speakersafetyd.service.d/50-j700-guard.conf`) and `omarchy-mac`'s preset keep applying to `speakersafetyd.service`.
