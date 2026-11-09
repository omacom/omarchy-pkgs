# N1X SCP firmware diagnostics

The driver reads the platform-owned SCP firmware log and supports firmware
version and sensor-descriptor queries. It does not start or reset the SCP.
Sensor measurements use SPI HID and the standard HID ALS IIO client.

The driver uses the SRAM and mailbox resources supplied by ACPI, without a
product-name or BIOS-version restriction. It checks their sizes and the firmware
dispatch instructions before enabling transactions. The firmware's descriptor
query lacks an index bounds check, so the driver permits only slot 1 after
checking the two-slot layout. A timeout or unmatched response prevents further
queries for that driver instance.

The register and log reference is OEM nvSCP 2.17.0.0, SHA256
`d1cc1ae1a907d607ad979e84116a5febdb2f55136b612b210c68fdd57f901a47`,
logger setup at `0x1400050a8`. Input metadata is recorded in
`config/platform-oem.json`. The FreeRTOS 2.0.8.0 dispatch and reply
handlers are at Cortex-M offsets `0x3ff0`, `0x40f8` and `0x41a4`; the probe
checks the instruction sequence at SRAM offset `0x41ce`.

The debugfs `sram_snapshot` file returns a private copy for each open. Open
files do not retain device MMIO after removal. This diagnostic interface and
the firmware-specific matching policy still require upstream subsystem review.
