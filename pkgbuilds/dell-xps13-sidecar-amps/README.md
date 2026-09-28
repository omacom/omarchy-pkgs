# Dell XPS 13 sidecar speaker amplifiers

This temporary package enables the two CS35L56 sidecar speaker amplifiers on
the Dell XPS 13 DX13260 with PCI subsystem ID `1028:0e53`.

Linux commit
[`efd80de2de9d`](https://github.com/torvalds/linux/commit/efd80de2de9d06ddf0eee55ca11b04e39bfc7cd8)
adds this machine to the `snd_soc_sof_sdw` PCI quirk table with
`SOC_SDW_SIDECAR_AMPS`. That commit first appears in Linux 7.2-rc5. Until the
Arch kernel ships it, this package selects the equivalent existing driver path
with the module's `quirk=65536` override.

The package does not replace the kernel, audio firmware, or speaker tuning. It
owns only a modprobe drop-in and rebuilds the boot images when installed,
upgraded, or removed.

`dell-xps13-sidecar-amps-apply` repeats the legacy cleanup and boot-image
rebuild idempotently. System integrations can run it as root after installation
when they need a directly observable success or failure status; package-manager
scriptlet failures are otherwise only reported by Pacman.

## Removal

Once every kernel you intend to boot contains the upstream commit, remove the
workaround and reboot:

```bash
sudo pacman -Rns dell-xps13-sidecar-amps
systemctl reboot
```

Removing the package deletes its modprobe drop-in and rebuilds the boot images,
so no temporary override remains embedded in the initramfs or Limine UKIs.
