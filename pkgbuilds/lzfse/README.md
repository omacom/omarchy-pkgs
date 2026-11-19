# lzfse

Apple's LZFSE library and command line tool, from the lzfse/lzfse `lzfse-1.0`
tag. `aurora-fwextract` uses it to unpack the macOS firmware. The recipe is
asahi-alarm/PKGBUILDs' `lzfse` 1.0-1, which neither Arch nor Arch Linux ARM
ship.

The name and version stay asahi-alarm's; `pkgrel=2` sorts above asahi-alarm's
1.0-1, so installed Macs take this build from `[omarchy]`, which is listed
first. The BSD licence is installed under `/usr/share/licenses/lzfse/`.
