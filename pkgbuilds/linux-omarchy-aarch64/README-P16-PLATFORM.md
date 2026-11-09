# ASUS ProArt P16 platform enablement

This section documents the platform patches carried with the P16 sleep
patch set. They add ARM64 reachability for the existing ASUS WMI drivers,
describe the MT8901's interrupt-only GPIO lines, and retry ACPI IRQ lookup for
SPI-HID when SPI enumeration did not provide an IRQ. They do not add a GNOME
extension, system service, userspace control daemon, or battery-limit policy.

## Patch scope and provenance

`9100-asus-arm64-wmi-p16.patch` moves the shared ASUS WMI sources and Kconfig
symbols out of the x86-only build path so ARM64 ACPI systems can build them. It
also handles the ProArt P16's two-dword RSOC response for the ASUS WMI battery
query and avoids resetting the firmware charge threshold during initialization
on that model.

`9101-p16-virtual-gpio.patch` describes MT8901 GPIO 182 through 208 as EINT-only
lines; GPIO 190 is the observed MSFW1111 interrupt line. The MTK pinctrl
callbacks treat these virtual GPIOs as inputs, avoid pinmux/register writes for
them, and reject output, value read/write, and pin configuration operations.
Existing real GPIO behavior is unchanged.

`9102-spi-acpi-irq-retry.patch` asks the ACPI GPIO layer for the device's first
GPIO IRQ only when the SPI device has no positive IRQ. A negative lookup result,
including `-EPROBE_DEFER`, is returned unchanged through `dev_err_probe()` so
driver core may retry probing later.

The upstream reference is Johann Hartmann and Josephine Pfeiffer's
`asus-proart-p16-rtx-spark-linux` repository, revision
`93e0d2286888a69f31eca8f5b243005c9b293535`, as recorded in the local source
receipt. The input patch SHA-256 values are
`1c5a9f3ce03931bc50dcb7c4580f57c2b3fcc8a87ce92a226a174f8bf3e6755a` for the
combined ASUS ARM64/WMI patch,
`0e20e5854cb0613e154f18cb8ddbae52a3ae614915815ea2872dd7db6dc97018` for
virtual GPIO, and
`6e94e341bcd221dbfec7432c12a7668b6da9eac34a1f3ba7e3d337657baa8d79` for the
SPI IRQ retry. The recipe's three patches are adapted for Linux 7.3 and
were checked by reverse-applying and reapplying them with `--fuzz=0` against
the prepared tree; they are not represented as byte-identical upstream
patches. This package does not include GNOME integration.

## Verification

Run the platform test against a prepared kernel source tree:

```sh
python test_platform.py /path/to/prepared/linux-7.3
```

The test checks the ARM64 Kconfig/Makefile wiring and effective config,
verifies GPIO 182-208 and GPIO 190's EINT mapping, and compiles the actual
`mtk_is_virt_gpio`, pinctrl GPIO callbacks, and SPI ACPI IRQ fallback block
from the prepared source with mocked register/ACPI providers. It verifies that
virtual pins do not write registers, only allow input direction, and that a
deferred ACPI IRQ lookup retains `-EPROBE_DEFER`.

The prepared local 7.3.12.1 tree passes this check. It also has
`CONFIG_ASUS_WMI=m`, `CONFIG_ASUS_NB_WMI=m`, `CONFIG_ACPI_WMI=m`,
`CONFIG_SPI_HID_ACPI=m`, and `CONFIG_SPI_HID_CORE=m`, with `PINCTRL_MT8901=y`.
This is build and source-level evidence, not proof of all hardware functions.

## Hardware status and limits

The available boot record is from ASUS ProArt P16 H7607BA BIOS 303. It reports
ASUS WMI and ASUS notebook WMI drivers loaded and platform profiles visible.
The optional ASUS Armoury driver was not enabled or loaded. The boot record
also records ASUS WMI warnings for LPS0 sleep-handler registration, factory fan
curve, and an unknown key filter code; these patches do not establish that
those features are fixed.

The SPI-HID ACPI driver bound in that boot, but it exposed zero HID/hidraw
children. The IRQ fallback therefore repairs a missing-IRQ probe path; the
current evidence does not demonstrate usable SPI sensors or input devices.
Battery cutoff behavior, fan controls, other BIOS revisions, and other ASUS
models remain unverified. The family match is an eligibility check, not a claim
that every eligible firmware has been validated.

## Capability-aware initialization follow-up

Patch 9103 keeps the ROG Ally MCU restoration callback behind the same
x86/suspend availability as its ACPI registration API. The P16's independent
coordinated LPS0 path is unchanged. It also avoids installing/removing an
i8042 filter when that controller is not reachable, and tests each optional
fan curve against its corresponding CPU/GPU/middle fan capability.

The reported curve error `0x00110032` refers to the middle fan. CPU and GPU
RPM and eight-point curves are readable on the tested machine; no custom
fan writes or thermal-response validation are claimed. The new harness
compiles the actual functions for x86, ARM64 and no-suspend configurations,
checks i8042 reachability and verifies independent fan detection. The ASUS
module also compiles against packaged Linux 7.3 headers with `W=1`.
A boot with this follow-up remains pending; SPI sensor availability is
still under investigation.

## SPI-HID ACPI reset follow-up

Patch 9104 invokes `_RST` on the namespace handle already held in the ACPI
configuration. The previous `device_reset(&adev->dev)` looked for a physical
ACPI companion on the namespace object's embedded device and skipped AML.
A boot trace showed reset-control lookup returning `-ENOENT` with no nested
ACPI evaluation, and no sensor interrupts or bus transfers.

The production callback regression requires `_RST` to run on the saved handle
and checks success plus firmware-error reporting. The complete native ARM64
kernel build and the existing function harnesses passed. On H7607BA BIOS 303,
a boot with this patch shows successful `_RST`, the first GPIO190 interrupt,
a SPI HID sensor hub and an ambient-light IIO device. A physical cover and
phone-light test changed the desktop sensor reading from 0 to about2175 lux
and back to ambient. Absolute calibration is not established.

A user-operated s2idle cycle of about57 seconds completed; after resume the
light sensor still reported13 lux, SPI error/timeout counters remained zero,
and NVIDIA plus audio services remained active. This is one functional cycle,
not a new sleep-power measurement or repeated-cycle qualification. No GNOME
battery policy, custom fan policy or desktop settings are included.

## MT7925 MLO membership follow-up

Patch 9105 is the unmodified upstream commit
`dd3f17ef69ed6d0085cd94a15b9dec227b4ebfb1`, authored by Andrei Rusu de Castro:
`wifi: mt76: mt7925: keep MLD membership consistent during link add`.
Both station updates sent while adding a secondary link now include the same
published and pending links. Publication still happens after successful setup;
the firmware record retains its capacity bound and primary-first order.

`test_mld.py` extracts the actual function and firmware structure from the
prepared kernel tree and compiles a native harness with ASan/UBSan and
`-Werror`. The previous implementation fails with member counts 1/2; the fixed
implementation passes pending/published membership, missing station/BSS,
duplicate prevention, record capacity and initial-primary cases. Both real
add-time ASSOC callers must pass the same pending link. `check()` runs this
test alongside the existing sleep and platform tests.

The patch was fully built and booted on H7607BA BIOS 303 in an isolated Linux
7.3 test kernel using the same Omarchy 7.3-26 base and P16 patch set. Active
MLO links at 5975 and 5500 MHz carried a 120-second simultaneous ping test:
240/240 replies each from gateway, LAN host and Internet through VPN, with
mean latencies 10.6/10.9/15.0 ms and isolated peaks near 274 ms. A subsequent
180-second operator walk received 360/360 gateway, 359/360 LAN and 360/360
Internet replies, means 5.3/6.5/9.8 ms, and a maximum near 107 ms. No
reconnections occurred in these intervals; the walk retained the same AP and
therefore does not validate inter-AP roaming. Initial supplicant scan/link/key
warnings remain, and suspend/resume with this Wi-Fi change is untested.

No frequency band, BSSID, VPN or roaming configuration is changed by this
kernel patch. These observations support the narrow backport; they do not
establish that every MT7925 connectivity issue is resolved.

## MT8901 USB Remote Wake

Patches `9106` and `9107` carry two unmodified NVIDIA fixes for
[MT8901 USB wake from s2idle](https://bugs.launchpad.net/bugs/2172005):

- `906426cf64e3873ac821d1d7c4cbfeabe7972f4f` reports debounce as unsupported
  for EINT lines without debounce hardware, instead of emitting an invalid
  argument warning for the optional setting.
- `f942d998370e28b184497c0db73787947be06039` prefers the firmware's
  wake-capable ACPI GpioInt as the MediaTek v2 xHCI dedicated wake IRQ, retains
  the previous ordinary IRQ fallback and enables controller wakeup when the
  firmware marks the GPIO line wake-capable. Deferred lookup and probe-error
  cleanup are preserved.

Both commits are authored by Kiran Maddaraki, acknowledged by NVIDIA reviewers
and signed off by Brad Figg. The existing `9101` virtual GPIO/input-only
handling supplies the EINT-only pin prerequisite. This change is confined to
the MediaTek v2 controller path; global platform IRQ indexing is unchanged.

On H7607BA BIOS 303 with the 20-CPU N1X, USB5 describes normal interrupt GSI 584
and a separate wake-capable GpioInt on pin 182. Its old optional IRQ1 lookup
did not find that GPIO. Merely enabling the receiver, root hub and controller
wakeup permissions had not allowed the same Corsair `1b1c:1b65` mouse to wake
the machine. With these fixes, boot registered GPIO 182 as dedicated wake
IRQ 226 and enabled controller wakeup without a manual root-hub policy change.

A coordinated manual test on a Linux 7.3 test kernel built from the Omarchy
7.3-39 base plus the same P16 patch set entered s2idle for 33.9568 seconds. A
click on that same mouse resumed the system, `pm_wakeup_irq` reported 226 and
the dedicated wake IRQ counter increased to 1. Suspend statistics increased
success by 1 and failure by 0, and the captured interval had no USB disconnect.
The mouse remained usable after resume. This is one confirmed USB remote-wake
cycle on this firmware, not validation of every device/port, repeated-cycle
reliability, other firmware or a new long-term power measurement. RTC wake is
not fixed or claimed by these patches.

`test_usb_wake.py` and `test_usb_debounce.py` compile the actual prepared-source
lookup, wake registration/removal and debounce code with ASan/UBSan. All 21
checks pass; the pre-fix implementation fails 7. They cover GPIO preference,
missing/non-wake/error fallback, deferred probing, non-MTK exclusion, wakeup
defaults and cleanup, plus supported/unsupported debounce and error
propagation. The full native kernel build also passed before the hardware
test; those results do not replace a build of every future recipe refresh.

Thank you to `jlobue10` for the independent tests, detailed raw logs and
follow-up reports that led us to investigate the USB wake route. Their
reported receiver disconnect was a manual unplug, not a spontaneous fault:
https://github.com/omacom/omarchy-pkgs/pull/1958#issuecomment-6727318724


## SROOT DMA and SPI-HID response follow-up

Patch 9110 limits a missing-`_CCA` correction to ACPI `NVDA8600` revision 1
on architectures that require the attribute. It records noncoherent DMA
before normal ACPI/IORT DMA configuration. Explicit and inherited `_CCA`,
other devices/revisions and the existing IOMMU route remain authoritative.
The firmware's SROOT mapping and the vendor provider's noncached allocation
motivated this correction. It does not borrow the NPU device's coherent DMA
context or ship NPU firmware, userspace packages or a model runtime.

Patches 9111--9113 build on the existing GPIO IRQ and ACPI namespace reset
fixes. GET input/feature requests use their corresponding wire command and
validate the response type and report ID. The output mutex stays held until
the response is copied, preventing another caller from replacing the shared
reply. `MSFW1111` with VID 0000/PID 0100 supplies input through asynchronous
DATA reports; sensor pending reads wait for those samples, while synchronous
raw input requests return `-EOPNOTSUPP`. A private native-order input-body
structure keeps decoded lengths separate from the packed wire ABI.

9111 and 9112 retain Johann-Peter Hartmann's original review-draft headers
and patch bytes. They are not accepted upstream commits. 9113 is the original
follow-up from `asus-proart-p16-rtx-spark-linux` commit
`cab38b1357af8683ba2156bec4dbe132abd8399d`; its published patch has no author
or DCO header, so none is invented. The existing transport prerequisites and
public wire layout are preserved. Thanks to Johann Hartmann and Josephine
Pfeiffer for the platform work and shared sources, and to `jlobue10` for
independent hardware reports and careful follow-up testing.

`test_npu_cca.py` compiles the actual prepared `acpi_init_coherency` function
and checks missing, explicit and inherited attributes, device/revision scope,
firmware errors and architectures that do not require `_CCA`.
`test_spi_get_requests.py` compiles the actual GET callback with ASan/UBSan
and `-Werror`: feature/input typing, response mismatch, zero/short/truncated
buffers, timeout recovery and deterministic concurrent response ownership.
`test_spi_lengths_stream.py` compiles the actual parser, header validator and
request dispatcher, checking all 16384 encoded lengths, bad fields and
stream-only dispatch. The canonical `test.sh` runs these with the complete
existing production-function suite against the prepared source tree.

Physical evidence is limited to a 20-CPU ASUS H7607BA on BIOS 303. An isolated
Linux 7.3 candidate carrying these same four patch bytes completed three NPU
jobs, then an operator-controlled s2idle cycle lasting about 78 seconds;
suspend statistics increased success by one and failure by zero. These NPU
observations used a separately supplied experimental driver/runtime and do
not establish that this kernel package alone provides an NPU userspace API.
The SPI sensor remained available after resume. The earlier USB remote-wake
result above remains a separate test. USB4 docking, other BIOS revisions,
18-CPU physical hardware, long-term reliability and sustained NPU workloads
remain untested. No RTC diagnostic instrumentation or functional RTC wake fix
is included, and these results do not establish physical DRIPS residency.
