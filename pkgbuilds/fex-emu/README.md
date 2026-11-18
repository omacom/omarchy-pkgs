# fex-emu

FEX-Emu/FEX `FEX-2604`, the x86 and x86-64 emulator `omarchy-steam-fex` runs
Steam with. The recipe is asahi-alarm/PKGBUILDs' `FEX-Emu` 2604-1: Clang and
lld with LTO, tuned for `apple-m1`, and the same check that `FEXInterpreter`
has no `cnth`, which traps on Apple Silicon. `cmake.patch` only prints the
tuning it builds with. FEX-2604 does not compile against Arch Linux ARM's
fmt 12, so it links the fmt its tag pins in `External/fmt` statically, and does
not depend on `fmt`.

Package names here are lower case, so it is `fex-emu`, providing, conflicting
with and replacing asahi-alarm's `FEX-Emu`. `omarchy-steam-fex` and `steam`
depend on `FEX-Emu` and resolve to this package; installed Macs swap at the
next `pacman -Syu`, since `[omarchy]` is listed first. Its other dependencies come from Arch Linux ARM. `xxhash` is a runtime
dependency, since every FEX tool but `FEXBash`, `FEXGetConfig` and `FEXpidof`
links `libxxhash.so.0`. FEXConfig, the Qt Quick configuration GUI, needs
`qt6-declarative`, an optional dependency so the command-line tools stay light.
