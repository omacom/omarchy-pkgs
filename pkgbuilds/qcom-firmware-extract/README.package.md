# qcom-firmware-extract

Copies the vendor-signed Qualcomm firmware a Snapdragon laptop needs, including
the GPU zap shader and audio/compute DSP images, from the owner's own Windows
installation on the same machine into `/usr/lib/firmware/updates/`.

Omarchy ships no vendor-signed firmware: the live ISO and every package carry
only files from linux-firmware. The files this tool copies never leave the
machine and are never downloaded. It is a temporary measure until laptop
vendors contribute complete firmware sets to linux-firmware.

## How it works

The device tree names every firmware file the kernel will ask for
(`firmware-name` properties). The tool keeps the names that are missing under
`/usr/lib/firmware{,/updates}`, finds each one by file name in
`Windows/System32/DriverStore/FileRepository` on any NTFS partition it can
mount read-only. If Windows carries several variants and linux-firmware has a
companion image from the same device-tree node, the sibling image's hash
selects the compatible variant. Identical duplicates are accepted; differing
variants without a unique companion match are skipped. The result is
installed under `/usr/lib/firmware/updates/<name>`. The GPU zap shader is added to the
initramfs through `/etc/mkinitcpio.conf.d/qcom-firmware.conf`; the DSP images
are loaded from the root filesystem. What was installed, from where, and its
checksum is recorded in `/var/lib/omarchy/qcom-firmware/manifest`.

Nothing is model-specific. A laptop whose firmware linux-firmware already
ships gets nothing copied; a machine without a device tree exits at once.

## When it runs

- **Installer, live session:** `qcom-firmware-extract --stage DIR` right
  after the disk is chosen, before anything is written. A full-disk install
  destroys the Windows partition the files come from, so this is the only
  moment they can be read. The stage is copied into the target.
- **Installer, hardware setup:** `qcom-firmware-extract --install --no-rebuild`
  from `install/hardware/qualcomm/firmware.sh`, using the stage
  (or a Windows partition still on disk). The installer builds the boot image
  once afterwards.
- **Installed system:** `sudo qcom-firmware-extract` scans the disks again,
  or `sudo qcom-firmware-extract -d /path/to/FileRepository` takes any driver
  store you can mount (a Windows install of the *same model*: the files are
  tied to the vendor's signing keys). It rebuilds the boot image; reboot
  afterwards.

BitLocker volumes cannot be read; turn BitLocker off in Windows first.

## Retirement

When linux-firmware ships a machine's vendor directory the tool copies nothing
and still configures its GPU firmware for early display. When every supported machine is covered, drop the
package and prune the `/usr/lib/firmware/updates` entries listed in the
manifest.

Derived from Canonical's `qcom-firmware-extract` (GPL-2+).
