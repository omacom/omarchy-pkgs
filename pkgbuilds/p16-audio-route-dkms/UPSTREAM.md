# Upstream source and H7607BA route patch

## Canonical kernel source

The kernel recipe pins the mainline Linux 7.3 release archive and applies an
ordered patch series on top of it:

- Archive: [linux-7.3.tar.xz](https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.tar.xz)
- Upstream tag: [v7.3](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tag/?h=v7.3)
- Tag commit: `c03c1a14507dfaf8b856c2608f9ac216021fc222`
- Archive SHA-256: `87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953`
- Omarchy aarch64 recipe revision: [`omacom/omarchy-pkgs` `3659b467`](https://github.com/omacom/omarchy-pkgs/commit/3659b4671149c0cc458f4bd2d9d9b021c0539d13)
- Recipe build/source receipt: `work/n1x-drips-kernel/build-inputs/provenance/receipt.json`

The MT8901 legacy SoundWire machine driver originated as MediaTek/NVIDIA
contribution `3e220be45c709fb8744579f09c5ede4dbbf14fc6`, carried by Omarchy
audio patch `1030-n1x-audio.patch` in the pinned recipe. That patch includes
the original `From:` and `Signed-off-by:` headers. The source file retains
MediaTek copyright and author notices and `SPDX-License-Identifier:
GPL-2.0`. The local P16 patch does not replace those notices or assert new
ownership.

The current review snapshot is
`work/n1x-upstream-pr/integrated-source/sound/soc/mediatek/mt8901/mt8901-acp-sdw-legacy-mach.c`,
SHA-256 `1136655fcf885059e1f6c9e2184d9e6335c84f9fd9203e9adb10431fd3d0d2fc`.
It is accepted by the P16 kernel-builder audio compatibility gate as the
source base hash. The gate compares the prepared kernel file with this value
before trying a DKMS build against packaged headers. The packaged modified
driver has SHA-256
`c2f40519feadc69d6626953a04f57a4bc5345723c556d6b6eebf5134fff7c9ec`.

## Patch contents

The minimal unified diff is [route-h7607ba.patch](route-h7607ba.patch). It
adds DMI and ACPI headers, exact DMI matches for ASUS / ProArt P16 H7607BA /
H7607BA, an `NVDA6210` ACPI-presence guard, and four static DAPM routes from
`Speaker` to CS42L43 AMP1/AMP2 positive and negative output pins. The card's
route array is copied and extended before card registration, so the links
follow the card's normal device-managed lifetime. The existing route list is
otherwise preserved byte-for-byte in the copy.

The package is SPDX GPL-2.0-only in line with the replaced kernel source. It
keeps the upstream source's existing MediaTek copyright/authorship; no
additional copyright holder or submitter is invented for this local patch.

## Why the routes are absent upstream

The generic SoundWire codec table declares CS42L43 speaker endpoint DP6 and a
callback that installs the same four paths. The P16 machine topology in
`drivers/soundwire/mediatek/mtk-sdw-mach.c` supplies only endpoint numbers 0,
1, and 2 for CS42L43 in the 2-amp and 4-amp configurations. The speaker
playback endpoint is number 3; it is deliberately omitted because the
CS35L56s are separate SoundWire devices. The endpoint parser therefore never
creates the DP6 DAI link on this card, and its `asoc_sdw_cs42l43_spk_rtd_init()`
callback cannot add the routes. The four P16-specific links fill that gap;
they do not duplicate routes from the uninstantiated callback.

The kernel change replaces the complete `mt8901_acp_sdw_legacy_mach` driver,
not just a route table. DKMS is therefore limited to the exact reviewed
releases in `dkms.conf`. A new release must pass the base-source compatibility
gate and compile against its packaged headers before its exact release string
is added. Header compilation and runtime validation are separate evidence;
an unchanged source hash alone does not prove module signing or playback.
