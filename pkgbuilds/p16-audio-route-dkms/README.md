# P16 CS42L43 speaker route DKMS package

This package replaces the in-tree `mt8901_acp_sdw_legacy_mach` platform driver with a copy of the current upstream driver plus four static DAPM routes from the card's `Speaker` endpoint to the CS42L43 AMP1/AMP2 positive and negative output pins. The routes are enabled only when all three exact DMI fields identify `ASUS`, `ProArt P16 H7607BA`, and board `H7607BA`, and ACPI device `NVDA6210` is present. Other boards continue to use the upstream route table unchanged.

The source is copied from the prepared Linux 7.3 tree at `sound/soc/mediatek/mt8901/mt8901-acp-sdw-legacy-mach.c`, whose SHA-256 is `1136655fcf885059e1f6c9e2184d9e6335c84f9fd9203e9adb10431fd3d0d2fc`. Only DMI/ACPI includes, the exact board guard and the four routes/table composition were added. See `PROVENANCE` and `p16-speaker-routes.patch`.

DKMS attempts a build for installed official Omarchy kernels ending in
`-omarchy`, including future releases, using the anchored pattern
`^.*-omarchy$`. Other kernel families and manually suffixed test kernels are
excluded. There is no list of exact kernel versions to extend. Build failures
remain visible to DKMS; they must be resolved before using the replacement
module with the affected kernel. The exact DMI/ACPI guard is unchanged.

Automatic build selection is distinct from compatibility validation. This
package replaces the complete machine driver, so maintainers must review the
upstream source delta and compile against the target headers before shipping
a new kernel. The reviewed base SHA-256 is
`1136655fcf885059e1f6c9e2184d9e6335c84f9fd9203e9adb10431fd3d0d2fc`.
An unchanged source hash alone does not establish ABI, signature or playback
compatibility; runtime audio remains separate QA.

The Arch package installs only DKMS source under `/usr/src/p16-audio-route-0.1.0`; the `dkms` package hooks add/build/install it for supported kernels. Header packages remain kernel-specific optional dependencies supplied by the selected kernel package. Do not hot-reload this replacement driver: a live rmmod/modprobe reprobe was observed to leave CS35L56 in a failed calibration state, and reloading the codec module can also lose required controls when the version-qualified firmware is not shipped. Validate final audio after a cold boot using a kernel that contains the host's accepted SoundWire patch set; the relevant SoundWire slave fixes are gated on a system BIOS reboot.

Build with `makepkg -sf`; this only creates a package. Install/reload and physical audio validation are separate steps. The local scope test checks the patch and hardware gate.


Run `python3 test_package.py` from this directory to check the kernel-family
selection, exact hardware gate, source identity and local recipe checksums.
