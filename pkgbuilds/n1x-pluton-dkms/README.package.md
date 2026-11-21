# n1x-pluton-dkms

Optional NVIDIA N1X ARM64 firmware diagnostics, loaded manually by the user.
The source is derived from Johann Hartmann's asus-proart-p16-rtx-spark-linux,
PR3 merge 5f3fbe50cd37ffe9ab2c697cb60c37bc01314a99. Original SPDX notices,
firmware references and available upstream protocol/provenance are retained.
source-provenance.json records the exact reviewed input hashes and adaptations.
Only source and tests are distributed; OEM drivers/firmware are not bundled.

## Installation and manual use

Install the package and the headers matching your ARM64 kernel. DKMS builds
and signs according to the system DKMS configuration, independently of whether
the module is loaded. Runtime depends on dkms, and python for the CLI.
No specific headers package is required because kernels provide different ones.
There is no service, module alias, modules-load file or install-time activation.
No private kernel suffix, bundle marker or second diagnostic package is required.
First confirm that the target is an NVIDIA N1X with the matching ACPI device
(NVDA8601 ROT1); the driver validates the ACPI resources before mapping.
Do not load it on another SoC or bind unrelated devices manually.

Load passively with `sudo modprobe n1x_pluton`, then run
`sudo n1x-pluton-info`. To permit typed queries, load with
`sudo modprobe n1x_pluton enable_transport=1`; the parameter is read-only after
loading. `sudo n1x-pluton-info --device-info --services --versions` sends only
PCBI 4, 5 and 7. Device `/dev/n1x-pluton` has mode 0600. Queries may initialize
the firmware mailbox transport; passive module loading does not query it.
Raw transport command 2 and external channel-discovery ioctl are rejected.
There is no arbitrary service/payload ioctl, key operation, firmware load/update
or TPM service. Internal channel discovery is needed for the typed requests.
Kernel validators bound full replies and poison uncertain protocol state.

## Validation and limits

The reviewed source was physically tested on ASUS ProArt P16 H7607BA, BIOS 303,
ARM64 kernel 7.3.0-41.8, before and after a roughly 78-second s2idle cycle.
The SCP status/version/descriptors and Pluton typed 4/5/7 queries succeeded.
This is single-machine evidence, not a claim for every N1X BIOS or firmware.
Both modules compile with W=1 against the tested 41.8 headers. check() runs
sanitized fault tests plus packaging checks; Pluton also exercises malformed
protocol replies, user-copy failures and eight serialized callers.

PM callbacks serialize requests with suspend/resume and reject suspended
operations. They do not manage firmware lifecycle/power. SCP snapshot opens
copy SRAM privately; Pluton retains state for open files across removal and
rejects removed-device requests. Hardware PM/unload behavior on other firmware
remains unvalidated. Close diagnostic readers before manual removal; no automatic
unload, reset or suspend is performed. No DSP/AFE/ALS/battery policy is installed.

Automatic upstream synchronization is disabled (`sync: false`): this is a
reviewed firmware ABI snapshot without a standalone tagged driver release.
Updating the pin requires review of protocol validators and physical validation;
following arbitrary repository commits would bypass that qualification.
