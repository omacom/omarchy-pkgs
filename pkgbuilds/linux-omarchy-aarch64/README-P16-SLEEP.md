# ProArt P16 suspend-to-idle candidate

This package adds an opt-in coordinated CPU idle path for the ASUS ProArt
P16 H7607BA with NVIDIA N1x, BIOS 303. It does not add a kernel command-line
option to the boot loader. The private P16 hierarchy and LPS0 timing policy
require the admission gate below.

## Enable and disable

Add `acpi.n1x_coordinated_s2idle=1` to a test boot entry's kernel command line
and boot that entry. Select `s2idle` for the test. Keep a working kernel entry
available. Remove the option and reboot to disable this candidate; no runtime
mode-switch command is provided.

The option alone does not admit a machine. The gate requires the exact ASUS
model and BIOS, NVDA6210, a raw DSDT of 73551 bytes with SHA-256
`5eced75d1b24c7fbd069aa9240695147848bbfca56cce76ab7f4a6a0eba9849f`,
the firmware OSLPI acknowledgement and cached PSCI OSI capability. Each of
the 20 CPUs must have the validated four-level hierarchy, three parents and
seven complete compositions before coordinated mode is published. Changed
firmware or an incomplete hierarchy is rejected. Ordinary idle retains the
prepared leaf path; shared-domain selection requires actual suspend-to-idle.

## Patch order and provenance

The recipe retains its existing N1x prerequisites and then applies:

1. `1120`: defer pciehp event processing across system resume.
2. `1121`: bounded PCI identity retry for the P16 soldered SD reader.
3. `1122`: coordinated hierarchy port with the P16 suspend-only policy.
4. `1123`: in-tree LPS0 late suspend/early resume timing, gated on the admitted
   coordinated P16 entering s2idle, MT8901 platform ID 2, and the expected
   `0x3f8` DSM function mask.
   Entry notifications run before IRQ suspension, with a three-second delay
   for the EC event; failed entries are unwound and pending exits retained.

The generic PCI event deferral in `1120` is Cole Leavitt's submitted
[linux-pci patch 1/2](https://patchwork.ozlabs.org/project/linux-pci/patch/20261018163910.132231-1-cole@unwrap.rs/)
of 2026-10-18. Its companion Thunderbolt-specific patch is not included.
The identity retry in `1121` is the local P16 adaptation.

The coordinated port is based on NVIDIA's official
[NV-Kernels PR 586](https://github.com/NVIDIA/NV-Kernels/pull/586), with
[PR 599](https://github.com/NVIDIA/NV-Kernels/pull/599) and
[PR 601](https://github.com/NVIDIA/NV-Kernels/pull/601), rebased onto this
package's Linux 7.3 prerequisites. PR 586 is pinned to
`2562f5f1d1cecfd2047d3810d4bf5626366f1d32`: 53 commits, including 29 upstream
prerequisites and 24 NVIDIA SAUCE changes. Existing prerequisites are retained
rather than reapplied. Ishan Shah and Bharat Dintakurti authored the NVIDIA
hierarchy/lifecycle work, alongside the upstream framework authors credited
in that series. The underlying hierarchy, lifecycle and
rollback work remains the work of those authors; the exact P16
admission gate and suspend-only restrictions are local adaptations. This is
a consolidated port, not an upstream-signed patch, and no new sign-offs are
claimed. Its SHA-256 is
`8a2319ae87519a94298e5e086c0b5ce2729fda8d6496728147e475033d60d8ae`.

## Evidence and limits

A hardware experiment on the P16/BIOS 303 measured 0.497 Wh over 1181.737 s,
approximately **1.514 W**, including suspend/resume transitions, with the first
three patches and a temporary LPS0 timing module. That
measurement belongs to the experimental kernel/module combination. It does
not establish a hardware result for a newly integrated in-tree LPS0 patch
or this package build. Validate the final package on hardware before making
that claim. A boot message or successful resume alone does not prove low power.

The function tests exercise actual extracted C code with mock providers,
`-Werror`, AddressSanitizer and UndefinedBehaviorSanitizer: firmware rejection,
private hierarchy admission, complete CPU coverage, ordinary idle exclusion,
s2idle entry/error balance, shared-domain guards, leaf fallback, mode rollback
and genpd accounting. Three further harnesses check the actual LPS0 callbacks,
notification ordering, failure cleanup, lifecycle/CONFIG gate and firmware
activation restrictions. They cannot establish firmware acceptance, DRIPS
residency, physical wake reliability or battery power.

Run the source/checksum and configuration checks without a build:

```sh
bash test.sh
```

Run all eleven compiled function tests against a kernel tree after this
recipe's complete patch series has been applied:

```sh
bash test.sh /path/to/prepared/linux-7.3
```

`makepkg` also invokes those tests from `check()` after building. A C compiler,
its ASan/UBSan runtimes and Python are required. The first command explicitly
reports the compiled tests as skipped when no prepared tree is supplied.
