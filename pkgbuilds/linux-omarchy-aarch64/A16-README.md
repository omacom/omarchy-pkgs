# A16 additions to the shared ARM kernel

This keeps current Omarchy master, kernel 7.2.8, the shared/N1x stack and the existing linux-omarchy / linux-omarchy-headers package names. Revision 24 builds on upstream 7.2.8-23 and adds A16 board support (2300), deferred SoundWire codecs (2301), the upstream block-mq scheduler fix (2302), and battery event handling during temporary firmware unavailability (2303). It preserves the current shared-kernel patches, including microphone, charger, PDC, GMU, Surface and Yoga camera support, plus CCI reset/autosuspend, ath12k, Iris and DGX Spark fixes. The A16 CCI changes retain upstream reset-on-resume behavior and clean up clocks when timing initialization or reset fails. The separate 7.3 Qualcomm bridge is not overlaid on this kernel.

`a16-source.json` identifies the upstream package base, source tree and patch provenance. `prepare()` checks the complete patched source before generating version/config files; `check()` checks the A16 configuration, DTB, SoundWire policy and release. Unmodified upstream checksums and patch signatures are preserved.

The package provides `omarchy-a16-dsp-abi=1`, installs its per-release marker, and records kernel-release metadata for the model-gated runtime setup. Keep the capability only while the early-DSP interface remains compatible with omarchy-a16-support. The upstream 2002 charger notification patch is retained once; no duplicate A16 charger patch is added.

Revision 24 completed a clean native A16 build, all 8,487 module checks, packaged-header compilation and distributed source replay. All 295 patches reproduce the source tree recorded in `a16-source.json`. Both installed UKIs verify; both DSPs start before root mount, with no early modprobe or battery uevent errors. The CCI mock checks and compiled battery regression pass.

Jesse confirmed audio playback, keyboard, touchscreen, charger transitions, and Bluetooth calls/audio on revision 24, which remains running after testing. Camera and sleep remain disabled and unvalidated. Known PMIC supplier-link and codec workqueue warnings remain; other ARM boards still need regression coverage. Testing used an enclosure-specific UAS fallback for an external SSD; the kernel proposal does not include that setting.

## Corresponding source publication

The split build emits `linux-omarchy-aarch64-source` alongside kernel and headers.
It includes every declared upstream source, patch, config, signature, public key
and the actual recipe, plus final `BUILD_CONFIG`, `KERNEL_RELEASE` and checksums.
Publish and retain all three matching outputs through the existing artifact and
signed repository pipeline. `README.source` describes offline source verification
and preparation; `.BUILDINFO` records build dependencies. Source replay is not a
claim of bit-identical binaries across toolchains. No OEM firmware is included.
