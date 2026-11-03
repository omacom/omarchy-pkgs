# P16 CS42L43 speaker route DKMS package

This package replaces the in-tree `mt8901_acp_sdw_legacy_mach` platform driver with a copy of the current upstream driver plus four static DAPM routes from the card's `Speaker` endpoint to the CS42L43 AMP1/AMP2 positive and negative output pins. The routes are enabled only when all three exact DMI fields identify `ASUS`, `ProArt P16 H7607BA`, and board `H7607BA`, and ACPI device `NVDA6210` is present. Other boards continue to use the upstream route table unchanged.

The source is copied from `work/n1x-upstream-pr/integrated-source/sound/soc/mediatek/mt8901/mt8901-acp-sdw-legacy-mach.c`, whose SHA-256 is `1136655fcf885059e1f6c9e2184d9e6335c84f9fd9203e9adb10431fd3d0d2fc`. Only DMI/ACPI includes, the exact board guard and the four routes/table composition were added. See `PROVENANCE` and `p16-speaker-routes.patch`.

DKMS attempts a build for installed kernels ending in `-omarchy` or
`-staticduo-p16`, including future releases, using the anchored pattern
`^.*-(omarchy|staticduo-p16)$`. Other kernel families, experimental suffixes and
historical manually suffixed test kernels are excluded. Real build failures
remain visible to DKMS and must be fixed before using this driver on that kernel.
The exact DMI/ACPI hardware guard and driver source are unchanged.

A family match is not proof that a future machine-driver snapshot is compatible.
Review source changes and compile against the selected kernel's headers before
shipping it. The private P16 pipeline separately verifies the original driver
hash and compiles against the exact packaged headers; that private gate is not
installed by this package and is not claimed as an Omarchy release guarantee.
The unchanged packaged source passed this check for the locally built and booted
`7.3.0-12.1-staticduo-p16` candidate, with the reviewed base SHA-256
`1136655fcf885059e1f6c9e2184d9e6335c84f9fd9203e9adb10431fd3d0d2fc`.

The Arch package installs only DKMS source under `/usr/src/p16-audio-route-0.1.0`; the `dkms` package hooks add/build/install it for supported kernels. Header packages remain kernel-specific optional dependencies supplied by the selected kernel package. Do not hot-reload this replacement driver: a live rmmod/modprobe reprobe was observed to leave CS35L56 in a failed calibration state, and reloading the codec module can also lose required controls when the version-qualified firmware is not shipped. Validate final audio after a cold boot using a kernel that contains the host's accepted SoundWire patch set; the relevant SoundWire slave fixes are gated on a system BIOS reboot.

Build with `makepkg -sf`; this only creates a package. Install/reload and physical audio validation are separate steps. The local scope test checks the patch and hardware gate.


Run `python3 test_package.py` from this directory to check the kernel-family
selection, exact hardware gate, source identity and local recipe checksums.
