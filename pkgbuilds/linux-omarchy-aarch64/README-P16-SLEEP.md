# ProArt P16 suspend-to-idle candidate

This package activates coordinated suspend-to-idle automatically on ASUS ProArt P16 systems with NVIDIA N1x, identified by the ASUS DMI vendor, the ProArt P16 product family and the NVDA6210 ACPI platform device. It does not require an enable parameter, a particular product-code suffix, a BIOS release number or a whole-DSDT hash. A ProArt P16 without N1x does not match.

## Automatic Activation And Disable Override

Boot the updated kernel normally and use `s2idle`. To disable this correction for troubleshooting, add `acpi.n1x_coordinated_s2idle=0` to the kernel command line and reboot. The legacy `=1` value is accepted but cannot force activation on unrelated hardware. An invalid value disables the correction and logs a warning. Keep a working kernel entry available during validation.

Hardware matching establishes eligibility. Actual activation still requires the firmware OSLPI acknowledgement and cached PSCI OSI capability. Each of the 20 CPUs must have the validated four-level hierarchy, three parents and seven complete compositions before coordinated mode is published. The raw LPI state shape, registers, LevelIDs, context-loss semantics and topology are checked; incompatible firmware is refused regardless of BIOS version. Ordinary idle retains the prepared leaf path, and shared-domain selection requires actual suspend-to-idle.

Only H7607BA BIOS 303 has been physically tested so far. Removing the version and hash pins does not establish hardware validation of other firmware revisions.

## Patch order and provenance

The recipe retains its existing N1x prerequisites and then applies:

1. `1120`: defer pciehp event processing across system resume.
2. `1121`: bounded PCI identity retry for the P16 soldered SD reader.
3. `1122`: coordinated hierarchy port with the original P16 suspend-only policy.
4. `1123`: in-tree LPS0 late suspend/early resume timing, gated on the admitted
   coordinated P16 entering s2idle, MT8901 platform ID 2, and the expected
   `0x3f8` DSM function mask.
   Entry notifications run before IRQ suspension, with a three-second delay
   for the EC event; failed entries are unwound and pending exits retained.
5. `1124`: automatic ASUS ProArt P16/N1x family detection, replacing the original explicit-enable, BIOS-release and DSDT-hash restrictions while retaining firmware compatibility checks and a disable override.

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

6. `1125`: preserve Ryan Hughes' existing DRIPS latency adjustment for non-coordinated N1x states, including fallback when coordination is refused. Coordinated composite latencies are unchanged.

## Evidence and limits

The five-patch implementation before the fallback-only follow-up was built as `7.3.0-8-omarchy-n1x-pr1958-1` and physically tested on H7607BA BIOS 303. It boots with no activation argument, no external LPS0 module, and automatic OSI/genpd admission of all 20 CPUs. The in-tree LPS0 driver advertises functions `0x3f8`. NVIDIA 615.78.08, Wi-Fi and the SD reader work after boot.

Two five-second platform PM tests passed, followed by three manual lid cycles with estimated suspended times of 380.317, 152.117 and 1221.047 seconds. The first was confirmed to wake solely on lid open; the logs for the other cycles show resume at lid opening. GPU, Wi-Fi and SD recovered, with no blocking kernel warnings/errors in these captures. An earlier external-module trial had an intermittent Wi-Fi scan failure, which is not claimed fixed generally.

The long integrated-kernel battery test reported 92.296 Wh before and 91.847 Wh immediately after resume: **0.449 Wh over 1225.775 seconds = 1.319 W**, including suspend/resume transitions and approximately 4.728 seconds of awake overhead. AC was disconnected in every captured sample, the gauge was confirmed decreasing below full charge, and neither endpoint snapshot crossed suspend. The following 0.209 Wh consumed while awake during settling is excluded. This validates the integrated implementation on this machine, not physical DRIPS residency or other models/BIOS revisions; gauge update timing and a single long measurement limit precision.

For reference, the earlier three-patch kernel plus temporary LPS0 module measured 0.497 Wh over 1181.737 seconds, about1.514 W including transitions. These are separate trials, not a controlled percentage comparison. No private-layout module is required by this package.

The first local test boot reached emergency mode because the test kernel was installed manually and `linux-modules-cleanup.service` removed its unowned module directory before it was selected. Restoring the modules and registering their directory ownership fixed that packaging mistake without changing the kernel, UKI or PR patches. This is distinct from the package's normal pacman-owned installation.

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

Run the compiled function tests against a kernel tree after this
recipe's complete patch series has been applied:

```sh
bash test.sh /path/to/prepared/linux-7.3
```

`makepkg` also invokes those tests from `check()` after building. A C compiler,
its ASan/UBSan runtimes and Python are required. The first command explicitly
reports the compiled tests as skipped when no prepared tree is supplied.
