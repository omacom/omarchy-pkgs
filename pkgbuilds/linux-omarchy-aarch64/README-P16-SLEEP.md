# ProArt P16 suspend-to-idle candidate

This package activates coordinated suspend-to-idle automatically on ASUS ProArt P16 systems with NVIDIA N1x, identified by the ASUS DMI vendor, the ProArt P16 product family and the NVDA6210 ACPI platform device. It does not require an enable parameter, a particular product-code suffix, a BIOS release number or a whole-DSDT hash. A ProArt P16 without N1x does not match.

## Automatic Activation And Disable Override

Boot the updated kernel normally and use `s2idle`. To disable this correction for troubleshooting, add `acpi.n1x_coordinated_s2idle=0` to the kernel command line and reboot. The legacy `=1` value is accepted but cannot force activation on unrelated hardware. An invalid value disables the correction and logs a warning. Keep a working kernel entry available during validation.

Hardware matching establishes eligibility. Actual activation still requires the firmware OSLPI acknowledgement and cached PSCI OSI capability. The P16 policy admits 18- and 20-CPU N1X configurations only when every present CPU has complete coverage and passes the existing four-level hierarchy, three-parent and seven-composition contract. Raw LPI state shape, registers, LevelIDs, context-loss semantics and parent paths remain checked; incompatible firmware is refused regardless of CPU count or BIOS version. Ordinary idle retains the prepared leaf path, and shared-domain selection requires actual suspend-to-idle.

18-CPU support is provisional: we assume that SKU uses the same validated ACPI hierarchy with two fewer cores, and let the existing runtime checks test that assumption. We have access only to the 20-CPU P16 and cannot physically test the 18-CPU version. A native 18-CPU owner must validate boot, suspend/resume and power consumption; their ACPI/topology and kernel logs will guide any further adaptation. Passing source tests or reducing the CPUs exposed on a 20-CPU machine does not establish native 18-CPU hardware compatibility. If the firmware contract does not match, the existing non-coordinated fallback remains available.

H7607BA BIOS 303 and 305 have physical test evidence, scoped to the kernels and
intervals recorded below. Removing version and hash pins does not establish
hardware validation of other firmware revisions.

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
7. `1126`: admit the complete known BIOS 305 parent profiles while retaining BIOS
   303 support, firmware timing sentinels, system QoS and suspend-only guards.

## Evidence and limits

The recipe is based on the current `7.3-9` package and proposes `7.3-10`, retaining the upstream P14 BIOS 303 keyboard and Copilot-key changes. The physical measurements below belong to the earlier isolated test build; the updated package revision has not been physically retested.

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


## Current recipe compatibility

The PR is refreshed on the official 7.3-46 recipe and uses pkgrel 47 so its
packaging change is shipped. It retains upstream's separate kernel, headers and
NVIDIA open-module split, driver version and seven NVIDIA patches unchanged.
The sleep implementation retains its existing firmware-state and lifecycle
checks. The 1122 follow-up admits 18 CPUs as well as 20, with provisional
18-CPU support and no physical validation of that SKU. That local candidate also includes
ASUS platform changes. That kernel portion is now included in this package PR
(see README-P16-PLATFORM.md); userspace battery integration remains excluded.
Its successful build/boot and the extracted-function tests do not establish new physical
suspend measurements for this refreshed official recipe.

## Independent sleep report and remaining wake-source limits

An independent owner, `jlobue10`, tested a second H7607BA BIOS303 with 20 CPUs
and the byte-identical 1120-1125 set at commit `8abf19a4`, without the ASUS/SPI
platform patches. On an Omarchy 7.3-3.1 base, the stock/control kernels woke
after about 4-6 seconds; the patched candidate remained asleep for 12 minutes,
33 minutes, 49 minutes and 3 hours 17 minutes until an external wake. Two
usable energy intervals measured 1.546 W and 1.559 W. These are that owner's
observations, not a rerun on the current recipe or a physical DRIPS reading.
Full report: https://github.com/omacom/omarchy-pkgs/pull/1958#issuecomment-6715195039

That owner reports that RTC alarms did not wake their patched candidate; the
stock/control kernels woke too early to compare RTC behavior. Timed wake has
not been validated here either. Lid wake is tested; do not assume RTC wake
works from this coordinated state. The USB receiver disconnect in that report
was a manual unplug, as `jlobue10` later clarified; it is not evidence of a
spontaneous receiver disconnect or a USB-caused wake:
https://github.com/omacom/omarchy-pkgs/pull/1958#issuecomment-6727318724
RTC wake remains unresolved. A separate MT8901 USB remote-wake correction and
its bounded hardware test are documented in README-P16-PLATFORM.md.

## Acknowledgments

Thank you to `jlobue10` for the independent kernel comparisons, raw logs,
energy measurements and follow-up reports. Their testing helped distinguish
the suspension improvement from the remaining RTC and peripheral wake issues
and prompted the USB wake-route investigation. The USB kernel fixes retain
their NVIDIA authorship and review credits in the original patches.


## BIOS305 LPI contract follow-up

Patch1126 retains the BIOS303 descriptor profiles and admits only the complete
known BIOS305 cluster/package descriptors with uniform valid enabled flags.
The system level additionally accepts the exact paired U32_MAX residency and
latency sentinel while MPEL is unset. Firmware timings remain unchanged; finite
QoS limits still reject this sentinel conservatively. Tuple, GAS, topology,
PSCI and suspend-only entry checks remain required. This does not write MPEL,
ELST or SYSRAM. The new admission and governor harnesses run from check().

On one 20-CPU H7607BA with BIOS305, Experimental7.3-44.10 completed one physical
suspend/resume cycle lasting6m34.688s. Battery energy decreased0.209Wh over
400.983s, averaging1.876W including transitions and6.295s awake around the
suspend interval. This is a whole-interval measurement, not steady sleep power
or physical DRIPS residency. The normal7.3-44.10 kernel was booted and its
admission checked; no physical power measurement was made on that kernel.
BIOS303 evidence above remains separate. Native18-CPU hardware remains untested,
and this change does not establish an RTC wake fix.
