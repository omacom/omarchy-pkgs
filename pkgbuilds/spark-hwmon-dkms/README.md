# DGX Spark and ProArt P16 telemetry

This updates the existing `spark-hwmon-dkms` package, based on
`antheas/spark_hwmon` commit `352c76e538cadece0e4887a153fef95f8f5ea1d4`.
The upstream NVDA8800 DGX Spark implementation and the two existing Omarchy
patches remain: bounded firmware register offsets, read-only power limits by
default, and platform-driver binding for Linux 7.3. The existing DGX power-cap
opt-in is not extended to the new P16 path.

## P16 support

The separate NVDA8810 backend adapts the RTX Spark work in
`johannhartmann/spark_hwmon` commit
`ef94faace8a44380e8ba8c8bd8cffd185c82af67`. It adds power/temperature reads
from supported ACPI sensor objects and a guarded MMIO telemetry fallback for the
exact ASUS / ProArt P16 H7607BA model. The validated MTEL schema, platform ID
2, four firmware limit contracts, and package-temperature range are checked
before fallback registration. The fallback maps the fixed P16 telemetry window
at `0x1c238000`, guarded by exact-model and runtime checks. This vendor window
is distinct from the advertised `NVDA8810` `_CRS` resources. The P16 backend exports readings only; it
does not write MMIO power requests, alter limits, restore requests on unload,
or provide power-cap writes. No firmware tables or userspace charge policy are
installed.

There is no BIOS-version allowlist. This permits a matching firmware contract
to be considered after a BIOS update; it does not establish validation on every
BIOS. Unknown models, incompatible schema, invalid platform IDs or malformed
bounds must not activate the P16 fallback. The ordinary NVDA8800 driver retains
its own discovery and offset checks.

## Validation and limits

The package's `check()` runs the production helper tests and compiles the DKMS
source against installed kernel headers in temporary DKMS directories. Set
`SPBM_KERNEL_BUILD=/usr/lib/modules/<release>/build` to select specific headers.
Building a source package does not load the module or change the running system.

Local evidence from the P16 on BIOS H7607BA.303 reports 13 readable MMIO power
channels and no optional ACPI temperatures. The package candidate builds
against the selected main-kernel headers; this does not establish hardware
validation of this separately patched upstream package on BIOS 303 or other
firmware.
Absolute energy calibration, raw status meanings and power-limit manipulation
are outside this contribution. The new official-package variant requires its
own physical validation; a successful build is not a measurement of hardware
accuracy. Keep that distinction when reporting its results.
