# P16 platform tools

Read-only kernel/update checks and a manual USB4 command-line proposal for
ARM64 ASUS ProArt P16 H7607BA. This package contains code and documentation;
it installs no hooks, services, module options, firmware or boot configuration.
It does not require a particular kernel name, distribution suffix, signing key,
SSDT override, DSP or NPU driver. No hardware/firmware query is sent.

## Kernel and UKI audit

Run after updating the kernel, headers and DKMS modules, before selecting the
candidate for boot. Root may be needed to read protected boot files; the tool
requires no privilege for files already readable by the user.

```sh
p16-platform-tools audit --release "$(uname -r)"
sudo p16-platform-tools audit --release TARGET_RELEASE \
  --module nvidia --module nvidia_drm --module spbm --uki /path/to/candidate.efi
```

The release defaults to the running kernel. The audit checks the installed
`/usr/lib/modules/RELEASE/vmlinuz`, matching header release, mandatory loadable
`spi_hid`, `spi_hid_acpi`, `asus_wmi`, module files, vermagic and dependency
resolution with `modprobe --show-depends` (never loads modules). Add any other
required driver explicitly with repeated `--module`. NVIDIA modules additionally
need a matching `nvidia-utils` package version. Signature metadata is reported;
`--require-signatures` makes missing signer metadata fatal. Presence does not
verify cryptographic validity, key enrollment, revocation or Secure Boot trust.
Built-in base drivers are currently rejected, rather than claiming module parity.

`--uki` parses the supplied PE EFI application. Kernel comparison ignores only
PE checksum, certificate-table metadata and a trailing Authenticode certificate;
other kernel bytes must match. This does not verify the certificate. It requires unique `.uname`,
`.linux` and `.initrd` sections, exact kernel content and release, and exact
uncompressed SPI module bytes. It rejects early NPU/DSP modules, duplicate or
unsafe CPIO names, malformed sections and multi-profile UKIs. The initrd is
parsed in memory; paths and symlinks are never extracted or followed. Supported
initrd formats are newc CPIO, gzip, xz and zstd, including an early archive
followed by a compressed main archive. Other compression formats fail clearly.
Use this on locally generated images you trust: decompression uses memory and
this is not a sandbox for hostile images. The command does not require or
install an ACPI table. It does not assert installed module signatures are trusted.

Exit status is 0 only if the requested checks pass, 1 for audit failure and 2
for CLI argument errors. An installed-kernel check does not check a UKI unless
`--uki` is supplied, and no audit proves physical hardware operation.

After editing mkinitcpio configuration, rebuild the candidate using your normal
mkinitcpio/boot tooling, then run the UKI audit against that exact file. Keep a
known working recovery entry. These are manual checks; no global update hook
or automatic boot promotion is installed.

## Opt-in USB4 proposal

```sh
p16-platform-tools usb4 --cmdline 'root=UUID=... quiet pci=nomsi'
```

Stdout is the replacement value for a Limine `cmdline:` field, not an executable
shell command. Copy the existing entry's complete kernel command line into the
argument. Preserve and review the rest of that entry using your normal boot
configuration process. The tool does not read or modify any Limine file and
prints no automatic install instructions or global drop-in.

The proposal preserves other parameters (including quoted values), consolidates
`pci=` options and replaces `hpbussize=0x80`, `hpmmiosize=32M`,
`hpmmioprefsize=32G`, and `power_wrap_drv.usb4_release=0`. The last parameter is
compatible with kernels exposing that power_wrap option; these options alone
do not add USB4 host-driver or PCI allocation support to an unsupported kernel.
Review the generated value, build an isolated candidate and keep recovery.
No USB4 dock has been physically qualified by this package.

## Evidence and attribution

Design references: Johann Hartmann's GPL platform-driver work and MIT tooling
at `johannhartmann/asus-proart-p16-rtx-spark-linux`, PR #3 merge
`5f3fbe50cd37ffe9ab2c697cb60c37bc01314a99`; in particular
`scripts/p16-platform-update-check`, `verify-boot.py`, `verify-platform-install.py`
and the USB4/power_wrap patch documentation. This implementation is independent
MIT Python code and does not copy their board-specific install policy.
See https://github.com/johannhartmann/asus-proart-p16-rtx-spark-linux/pull/3
and https://uapi-group.org/specifications/specs/unified_kernel_image/ .

Relevant upstream physical evidence targets BIOS 303 and a 20-CPU H7607BA;
other BIOS/CPU configurations require separate qualification. Reports include
coordinated suspend/resume; a separate local approximately 78-second smoke
trial is only a short recovery check,
not physical USB4 dock qualification or proof that every package combination
works. NPU numerical results belong to a separate driver stack: enabling NPU,
checking inference and qualifying its suspend/resume require separate QA. This
package neither enables that stack nor adds RTC, DSP, charge or power-limit policy.

Run portable tests with `python test_tools.py`. Fixtures exercise the actual CLI,
command failures, ABI/header/version mismatches, signature policy, real PE
parsing and CPIO/module parity without root or P16 hardware.
