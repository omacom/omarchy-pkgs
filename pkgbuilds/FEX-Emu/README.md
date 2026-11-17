# FEX-Emu

FEX-Emu/FEX `FEX-2604`, the x86 and x86-64 emulator `omarchy-steam-fex` runs
Steam with. The recipe is asahi-alarm/PKGBUILDs' `FEX-Emu` 2604-1: Clang and
lld with LTO, tuned for `apple-m1`, and the same check that `FEXInterpreter`
has no `cnth`, which traps on Apple Silicon. `cmake.patch` only prints the
tuning it builds with.

The name and version stay asahi-alarm's; `pkgrel=2` sorts above asahi-alarm's
2604-1, so installed Macs take this build from `[omarchy]`, which is listed
first. Its dependencies all come from Arch Linux ARM. The x86 root filesystem
(`fex-emu-rootfs-arch`) and Mesa overlays are separate packages and are not
built here.
