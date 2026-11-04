# ASUS ProArt P16 platform enablement

This section documents the three platform patches carried with the P16 sleep
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
kernel build and the existing function harnesses passed. On H7607BA BIOS303,
a boot with this patch shows successful `_RST`, the first GPIO190 interrupt,
a SPI HID sensor hub and an ambient-light IIO device. A physical cover and
phone-light test changed the desktop sensor reading from 0 to about2175 lux
and back to ambient. Absolute calibration is not established.

A user-operated s2idle cycle of about57 seconds completed; after resume the
light sensor still reported13 lux, SPI error/timeout counters remained zero,
and NVIDIA plus audio services remained active. This is one functional cycle,
not a new sleep-power measurement or repeated-cycle qualification. No GNOME
battery policy, custom fan policy or desktop settings are included.
