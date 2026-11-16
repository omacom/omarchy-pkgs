# aop-boot-guard-k114

One guarded AOP and speaker DAI module load per boot for the MacBook Pro
14-inch (M5 Max, K114c).

## What installs

- `/usr/lib/aop-boot-guard/load`, the fail-closed loader
- `/usr/lib/aop-boot-guard/wdt-run`, the watchdog runner: it pets
  `/dev/watchdog` every 2 s while `insmod` runs, so a hung module load
  resets the SoC after 90 s instead of hanging the boot
- `/usr/lib/systemd/system/aop-boot-guard.service`, a root oneshot unit;
  the package does not enable it

## Kernel pins

The loader refuses to load anything unless
`/usr/lib/aop-boot-guard/manifests/<kernel release>/manifest.json` exists
for exactly the running release, holding exactly:

    {"release": "...", "aop_sha256": "...", "dai_sha256": "..."}

`aop_sha256` pins the bytes of
`/lib/modules/<release>/kernel/drivers/soc/apple/aop.ko`, `dai_sha256`
pins `/lib/modules/<release>/kernel/sound/soc/apple/snd-soc-t8152-aop-audio.ko`.
The kernel build or the machine owner drops one manifest in per pinned
kernel. No pins ship with this package: on any kernel without one the unit
fails closed and loads nothing.

## Daemon pin

The load also requires `speakerguardd-k114 0.1.12-4` (exact `pacman -Q`
match). Speaker protection moves with the loader one reviewed pair at a
time; any other installed version refuses.
