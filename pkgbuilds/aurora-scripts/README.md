# aurora-scripts

asahi-alarm's `asahi-scripts` 20261023, built from the asahi-alarm/asahi-scripts
tag instead of taken from the asahi-alarm repository. The recipe and install
script are asahi-alarm/PKGBUILDs' `asahi-scripts` 20261023-1; only the name, the
group and `arch` change (the scripts are Apple Silicon only).

It ships `update-m1n1`, `asahi-fwupdate`, `asahi-diagnose`, the `asahi`
mkinitcpio hook that loads the vendor firmware in the initramfs, the m1n1
pacman hook and the first-boot unit, at the same paths as `asahi-scripts`.

## Existing installations

`provides=("asahi-scripts=$pkgver")` keeps every `asahi-scripts>=…` dependency
satisfied. `replaces=('asahi-scripts')` swaps the asahi-alarm package for this
one at the next `pacman -Syu`, since `[omarchy]` is listed first. The licence
is installed under `/usr/share/licenses/aurora-scripts/`.
