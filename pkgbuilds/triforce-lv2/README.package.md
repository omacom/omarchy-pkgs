# triforce-lv2

James Calligeros' beamformer for the three-microphone arrays in Apple Silicon laptops, an LV2 plugin. `aurora-audio` depends on `triforce-lv2>=0.2.0` for its microphone chain.

Built from the chadmed/triforce 0.3.2 tag. The recipe follows asahi-alarm's: same name, same `pkgver`, a higher `pkgrel`, so a Mac that has asahi-alarm's build takes this one at its next update. The plugin installs to `/usr/lib/lv2/triforce.lv2/`, as before.

Triforce is GPL-2.0-or-later (its `Cargo.toml`, `LICENCE.txt` and source headers), not MIT as asahi-alarm's recipe declares.
