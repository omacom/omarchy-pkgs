# aurora-scripts

asahi-alarm's `asahi-scripts` 20261023, built from the asahi-alarm/asahi-scripts
tag instead of taken from the asahi-alarm repository. The recipe and install
script are asahi-alarm/PKGBUILDs' `asahi-scripts` 20261023-1; only the name, the
group and `arch` change (the scripts are Apple Silicon only).

It ships `update-m1n1`, `asahi-fwupdate`, `asahi-diagnose`, the `asahi`
mkinitcpio hook that loads the vendor firmware in the initramfs, the m1n1
pacman hook and the first-boot unit, at the same paths as `asahi-scripts`.

`asahi-fwupdate-esp-room.patch` changes one thing in `asahi-fwupdate`. It writes
the new firmware as `vendorfw.new` beside the live `vendorfw` on the EFI system
partition before the swap, and on a 500 MB partition a copy that ran out of room
was left half-written there, taking the room the UKI needed next. The patched
script removes a failed run's `vendorfw.new` first, stages the new copy only
when the partition has its size free, with a tenth and 1 MiB more, and removes a
staging copy that could not be finished. Either way the live firmware is not
touched and the script fails.

`asahi-fwupdate-unmount-on-exit.patch` unmounts the EFI system partition from
`/run/.system-efi` on every exit. Without it the mount stays when there is no
firmware tarball or the extraction fails.

## Existing installations

`provides=("asahi-scripts=$pkgver")` keeps every `asahi-scripts>=…` dependency
satisfied. `replaces=('asahi-scripts')` swaps the asahi-alarm package for this
one at the next `pacman -Syu`, since `[omarchy]` is listed first. The licence
is installed under `/usr/share/licenses/aurora-scripts/`.
