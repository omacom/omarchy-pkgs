# qcom-firmware-extract

Copies the vendor-signed Qualcomm firmware a Snapdragon laptop needs, including
the GPU zap shader and audio/compute DSP images, from the owner's own Windows
installation on the same machine into `/usr/lib/firmware/updates/`.

The package itself contains no firmware. The files it copies never leave the
machine and are never downloaded. It is a temporary measure until laptop
vendors contribute complete firmware sets to linux-firmware.

## How it works

The device tree names every firmware file the kernel will ask for
(`firmware-name` properties). The tool keeps the names that are missing under
`/usr/lib/firmware{,/updates}`, finds each one by file name in
`Windows/System32/DriverStore/FileRepository` on an NTFS partition it can
mount read-only: with `--stage`, any such partition, and with `--install`,
only those on internal disks. Disk names and partition numbers are not assumed;
EFI, Linux and recovery partitions without a driver store are ignored. Directory
and firmware names are matched case-insensitively. An existing Windows mount is
read in place and is never remounted or unmounted by this tool. Otherwise the
tool tries a temporary read-only `ntfs3` mount, then `ntfs-3g` when available;
it never forces or repairs an NTFS volume. A DSP device-tree image the device tree calls
`*_dtb.mbn` is also found under its Windows name, `*_dtbs.elf`, when the exact
name is missing. If Windows carries several variants and linux-firmware has a
companion image from the same device-tree node, the sibling image's hash
selects the compatible variant. Identical duplicates are accepted; differing
variants without a unique companion match are skipped. The result is
installed under `/usr/lib/firmware/updates/<name>`. The GPU zap shader is
added to the initramfs through `/etc/mkinitcpio.conf.d/qcom-firmware.conf`;
the DSP images are loaded from the root filesystem. What was installed, from
where, and its checksum is recorded in
`/var/lib/omarchy/qcom-firmware/manifest`.

Nothing is model-specific. A laptop whose firmware linux-firmware already
ships gets nothing copied; a machine without a device tree exits at once.

## Firmware that does not come from Windows

Some boards name firmware that must not be copied from Windows. The board
package may handle it itself, for example by processing a vendor driver file
or by holding back an image not yet tested on that board. Or the machine's
own boot firmware loads it before Linux starts, and Windows drivers do not
carry it as a file. The board package lists such names, one per line, in
`/usr/share/qcom-firmware-extract/provided.d/<compatible>.list`, where
`<compatible>` is one of the board's device-tree compatible strings. Blank
lines are ignored, and a `#` at the start of a line or after a space starts
a comment. An entry with a space inside, or a list that cannot be read, is
skipped with a warning. On that board, listed names are never searched for,
installed or reported missing, even when Windows or the stage holds a copy;
everything else is handled as usual.

A copy that an earlier `--install` put in `/usr/lib/firmware/updates` before
the name was listed stays there, and while it does, it loads before any other
copy. The tool never deletes it: matching bytes would not prove that the file
is still the one it installed, since a board's own tool may keep the same file
at that path. The next `--install` stops recording it in the manifest and
prints its path, so the board package, or the user, can remove it.

Because `--list-missing` leaves listed names out, a board must not list
firmware that a hardware check relies on unless its package installs that
firmware before the check runs. Omarchy's `install/hardware/qualcomm/firmware.sh`
looks for `adsp` in that output to decide whether to keep the DSP driver off,
so a listed ADSP image would bypass the check.

## When it runs

- **Installer, live session:** `qcom-firmware-extract --stage DIR` right
  after the disk is chosen, before anything is written. A full-disk install
  destroys the Windows partition the files come from, so this is the only
  moment they can be read. The stage is copied into the target. Running
  `--stage` again, for example with `-d`, adds the files earlier runs did
  not find.
- **Installer, hardware setup:** `qcom-firmware-extract --install --no-rebuild`
  from `install/hardware/qualcomm/firmware.sh`. Each file comes from the stage
  if it holds one, otherwise from a Windows partition still on an internal
  disk. A staged file that a later device tree names under another path is
  found by file name, after Windows, unless Windows held variants it refused
  as ambiguous. The installer builds the boot image once afterwards.
- **Installed system:** `sudo qcom-firmware-extract` uses the stage and scans
  the internal disks again for what it lacks; when nothing is missing, it does
  not touch the disks. `sudo qcom-firmware-extract -d /path/to/FileRepository`
  instead takes any driver store you can mount, including one on a USB disk
  (a Windows install of the *same model*: the files are tied to the vendor's
  signing keys). It rebuilds the boot image; reboot afterwards.

`--list-required` includes firmware already installed in the live system, so the
A16 preflight can verify every staged copy before disk cleanup.

Staged files are checked against their manifest's SHA-256 before reuse. A corrupt
or incomplete stage does not hide a readable Windows source: rerunning staging
replaces the bad copy. If Windows is no longer available, corrupt files are
reported and left uninstalled rather than silently trusted.

BitLocker volumes are opened read-only with cryptsetup, or Dislocker when
cryptsetup cannot read their metadata. A clear-key protector, present when
protection is suspended, can be used automatically. Otherwise
`--unlock-bitlocker` prompts on the local terminal for the Windows recovery key.
The key is read by the unlock tool with echo disabled; it is not passed in command
arguments, saved, or written to the firmware log. Cancelling stops the command.
Windows stays encrypted. Temporary NTFS mounts, FUSE mounts and decrypted
mappings are released before staging succeeds. An existing owner mount is
reused without being changed or unmounted. Install the optional cryptsetup and
dislocker packages for these paths; the ARM ISO includes them and ntfs-3g.
An exported Windows `FileRepository` can still be supplied with `-d`. Conflicting
firmware from multiple Windows installations is still refused unless the bytes
agree or an installed companion image identifies a unique match. Missing files
remain explicitly reported; partial extraction is not proof that all hardware
will work.

## Retirement

When linux-firmware ships a machine's vendor directory, the tool copies nothing
and still configures its GPU firmware for early display. When every supported
machine is covered, drop the package and prune the `/usr/lib/firmware/updates`
entries listed in the manifest.

Derived from Canonical's `qcom-firmware-extract` (GPL-2+).

## Board requirements outside the device tree

`required.d/<compatible>.list` adds firmware requested directly by a driver.
Each line is a Linux firmware path followed by an optional Windows basename.
The A16 list preserves QCC2072 `board.bin`, including with `--stage-installed`,
and accepts the NCM820A ELF named by ASUS's Wi-Fi INF. It does not select a
random `bdwlan.eXX` variant. Conflicting copies are refused by the same
companion/ambiguity rules as DSP firmware. Existing Linux firmware can be
exported into a dedicated directory and imported with `-d` before installation.
