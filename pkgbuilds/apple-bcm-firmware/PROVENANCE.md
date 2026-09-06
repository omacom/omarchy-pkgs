# Apple/Broadcom firmware provenance

This package contains proprietary firmware/data, not compiled open source.
No separate license or redistribution grant for these blobs was found upstream.
`LicenseRef-unknown` records that unresolved status; this note grants no rights.
Package publication requires a separate rights review.

Omarchy's source repository is https://github.com/omacom/apple-bcm-firmware,
forked from https://github.com/AdityaGarg8/Apple-Firmware. Aditya Garg's README
identifies the macOS GitHub Runner Image as the extraction source. The packaging
credits Aditya Garg and the t2linux and Asahi Linux contributors for collection
and renaming. Their extraction tools' MIT license does not license the blobs.
The precise runner image identifier and original Apple image hashes were not
recorded with the initial tree; the source commit and output hashes pin what
we received, not an independently reproduced Apple extraction.

The package version identifies the reviewed macOS version of the checked-in
files. The PKGBUILD records the exact Git commit and archive checksum;
intel-firmware.sha256 records every installed Intel filename and its checksum.
Only Wi-Fi 4355c1/4364b2/4364b3/4377b3 and Bluetooth 4377b3 families are packaged.
Apple Silicon families are outside this package's scope. Filename coverage
does not establish operation on every T2 Mac.

For local macOS or Apple recovery extraction, see
https://wiki.t2linux.org/guides/wifi-bluetooth/ and omarchy-pkgs/docs/t2/firmware.md.
Apple's Sonoma terms are at
https://www.apple.com/legal/sla/docs/macOSSonoma.pdf (sections 2.J–2.K).
This package does not reload drivers, alter boot configuration or start services.
