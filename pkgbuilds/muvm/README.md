# muvm

AsahiLinux/muvm 0.7.0, which runs programs in a libkrun microVM. On Apple
Silicon, `omarchy-steam-fex` runs Steam in it under FEX-Emu. The recipe is
asahi-alarm/PKGBUILDs' `muvm` 0.7.0-1, built here from the `muvm-0.7.0` tag
with Arch Linux ARM's Rust and `Cargo.lock`, not the pinned rustup toolchain.
The licence is the one upstream ships in `crates/muvm/`.

The name and version stay asahi-alarm's; `pkgrel=2` sorts above asahi-alarm's
0.7.0-1, so installed Macs take this build from `[omarchy]`, which is listed
first. `libkrun`, `socat` and `passt` come from Arch Linux ARM.
