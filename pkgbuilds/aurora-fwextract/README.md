# aurora-fwextract

asahi-alarm's `asahi-fwextract` 0.9.2, built from the
asahi-alarm/asahi-alarm-installer `v0.9.2` tag instead of taken from the
asahi-alarm repository. The recipe and install script are asahi-alarm/PKGBUILDs'
`asahi-fwextract` 0.9.2-1; only the name, the group and `arch` change.

It ships `asahi-fwextract` and the `asahi_firmware` Python module that
`asahi-fwupdate` (from aurora-scripts) runs to rebuild the vendor firmware
archive. The install script runs `asahi-fwupdate` on install and upgrade, as
before.

## Existing installations

`provides=("asahi-fwextract=$pkgver")` keeps old dependencies satisfied and
`replaces=('asahi-fwextract')` swaps the asahi-alarm package at the next
`pacman -Syu`. The runtime dependencies (`python`, `aurora-scripts`, `lzfse`)
are set in `package()`, because the build environment cannot install
aurora-scripts or lzfse.
