# n1x-scp-dkms

Optional NVIDIA N1X ARM64 firmware diagnostics, loaded manually by the user.
The source is derived from Johann Hartmann's asus-proart-p16-rtx-spark-linux,
PR3 merge 5f3fbe50cd37ffe9ab2c697cb60c37bc01314a99. Original SPDX notices,
firmware references and available upstream protocol/provenance are retained.
source-provenance.json records the exact reviewed input hashes and adaptations.
Only source and tests are distributed; OEM drivers/firmware are not bundled.

## Installation and manual use

Install the package and the headers matching your ARM64 kernel. DKMS builds
and signs according to the system DKMS configuration, independently of whether
the module is loaded. Runtime depends on dkms.
No specific headers package is required because kernels provide different ones.
There is no service, module alias, modules-load file or install-time activation.
No private kernel suffix, bundle marker or second diagnostic package is required.
First confirm that the target is an NVIDIA N1X with the matching ACPI device
(NVDA8200 SCP); the driver validates the ACPI resources before mapping.
Do not load it on another SoC or bind unrelated devices manually.

Load passively with `sudo modprobe n1x_scp`. Mount debugfs if not already
mounted, then read `/sys/kernel/debug/n1x_scp/status` and `firmware_log` as root.
To permit bounded version/descriptor queries, load with
`sudo modprobe n1x_scp enable_mailbox=1` on the validated firmware ABI.
The parameter is read-only after loading; do not unload an in-use diagnostic
instance merely to switch modes. `firmware_version` and `sensor_descriptors`
are root-readable. The exact accepted dispatch instructions are checked at
probe; no product/BIOS allowlist substitutes for that firmware check. The
validated device returned firmware 3.0.1.0 with that dispatch ABI. Only the
validated descriptor slot 1 is queried; a timeout or unexpected response
poisons queries until a new instance. No reset/start, ALS client or DSP exists.
The upstream README.md documents firmware offsets and OEM reference hashes.

## Validation and limits

The upstream reviewed source was physically tested on ASUS ProArt P16 H7607BA, BIOS 303,
ARM64 kernel 7.3.0-41.8, before and after a roughly 78-second s2idle cycle.
The SCP status/version/descriptors succeeded in that upstream validation.
This is single-machine evidence, not a claim for every N1X BIOS or firmware.
The upstream SCP module compiled with W=1 against the tested 41.8 headers.
These are historical upstream results, not hardware validation of this package's
adaptations. Package `check()` runs `test_snapshot.py`, `test_mailbox.py` and
`test_package.py`. The first two compile extracted production C with ASan/UBSan:
snapshot allocation/copy/lifetime and mailbox token/command mismatches, oversized
replies, timeouts, malformed descriptor counts/lengths/slots, poison before lock
release and refusal of later queries. The packaging test checks manual loading
and the ARM64 DKMS restriction. No hardware is accessed by these tests.

PM callbacks serialize requests with suspend/resume and reject suspended
operations. They do not manage firmware lifecycle/power. SCP snapshot opens
copy SRAM privately. Hardware PM/unload behavior on other firmware
remains unvalidated. Close diagnostic readers before manual removal; no automatic
unload, reset or suspend is performed. No DSP/AFE/ALS/battery policy is installed.

Automatic upstream synchronization is disabled (`sync: false`): this is a
reviewed firmware ABI snapshot without a standalone tagged driver release.
Updating the pin requires review of protocol validators and physical validation;
following arbitrary repository commits would bypass that qualification.
