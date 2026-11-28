# Opt-in N1X NPU provider

Source pin: n1x-npu-linux 5f0dd10dda9dda7559d3b4086020ef9da3d975d3.
The local mmap patch preserves the original DMA allocation and selects image
pages through vm_pgoff; the unpatched IOMMU path exposed descriptor pages.

ARM64 kernel with 4 KiB pages (16/64 KiB kernels are refused before driver
registration), DRM_ACCEL, matching headers, ACPI NVDA200A revision 0x34 and
NVDA8600 revision 1, translated isolated IOMMU groups, and the upstream
NVDA8600 missing-_CCA noncoherent quirk are required. The driver checks
CCA/coherency/IORT/domain membership before mapping registers. That quirk is
a kernel contribution, not applied by DKMS. No personal kernel suffix is used.

Installation never starts or enables a service. No ACPI aliases, modules-load
entry, domain changes in udev, firmware, DSP/AFE startup or forced resets.
The module additionally requires explicit enable=1. To opt in after preparing
local firmware and reviewing IOMMU topology:

    sudo /usr/lib/n1x-npu/control --check-host
    sudo systemctl start n1x-npu.service

Only after successful hardware QA, opt in to future boots with
`sudo systemctl enable n1x-npu.service`. The checked service validates both
IOMMU groups before selecting DMA and loading the module once. A failure may
retain DMA/module ownership deliberately; no automatic retry. Stop with
`sudo systemctl stop n1x-npu.service`; unload occurs only after checked
hardware-off/released status. Do not force unload on refused shutdown.

PM: DLA -> SROOT device link orders system suspend/resume. Idle suspend performs
checked joint teardown and resume restarts once. Active/poisoned work or
published DSP buffers can refuse suspend. Runtime autosuspend returns EBUSY;
this package makes no low idle-power claim. Shared DSP upload API is present
but no DSP consumer is installed or started.

Validation: native build against Linux 7.3 ARM64 headers, portable ownership,
shutdown/PM tests, exact IOMMU/remap C mmap regression and lifetime checks.
On one ASUS ProArt P16/N1X the source plus mmap fix passed three changing-input
ReLU numerical jobs and allocation cleanup before and after 78.482 seconds of
s2idle. These public opt-in packaging gates require their own first-boot QA;
this does not establish support for all N1X systems or kernel versions.

`makepkg` checks have no vendor inputs or hardware access. Optional exact-kernel
regression: `python test_dma_mmap.py /path/to/linux-source` after
`makepkg --nobuild`. `python test_packaged_accel.py` checks the patched
EXEC/read/info/mmap/ownership/close implementation with UBSan.

Update automation is disabled while the source/firmware ABI and PM behavior
require review together. Licenses follow upstream file-level notices;
NVIDIA inputs are separate and are not licensed by this source project.

## Provider refresh

The selected source is 5f0dd10dda9dda7559d3b4086020ef9da3d975d3 (Johann-Peter
Hartmann, n1x-npu-linux). It adds per-platform provider contexts, scoped
firmware/board-policy caches and the SROOT v5 / typed DSP reinitialization
interfaces. The public package still installs no DSP consumer, OEM firmware
or runtime binary and retains explicit enable=1, no ACPI autoload aliases,
4 KiB page admission and early translated-IOMMU checks. The local mmap fix is
rebased once and continues to map pages from the original DMA allocation.

Package version 0.1.1.r5f0dd10 is intentionally newer than the previous
0.1.0.r92e9434 despite the lexically lower git abbreviation; DKMS uses the
same explicitly documented package version. Public n1x names and portable
hardware checks are preserved; no private kernel suffix, boot marker or
platform service gate is included.

Numerical evidence from a matching private provider on one P16 found 16/16
exact FP16 matches for bounded ReLU/Conv1x1/Conv1x1+ReLU cases with changing
inputs and no retained jobs. That boot already had Lockdep disabled, so this
is not PM/lock-order qualification or validation of this public adaptation.
MNIST remains numerically incorrect; full ONNX/model accuracy is not claimed.
