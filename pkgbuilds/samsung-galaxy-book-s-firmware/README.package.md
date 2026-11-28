# samsung-galaxy-book-s-firmware

Audio DSP, compute DSP, GPU and modem firmware for the Samsung Galaxy Book S, from the driver bundle Samsung publishes for it on Windows Update.

The firmware only runs if Samsung signed it for this board, so linux-firmware cannot carry it until Samsung submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Compute DSP Subsystem extension 1.0.1040.0000 for the Galaxy Book S PAHP (Windows Update 200.0.25.0), `wu://809f4e4e-5cd6-413e-a02b-2f480c16ea97/1/7148262bc53894856196ef36e23798f315dc7f5b`, 3 MB, SHA-256 `3f8b392d3d99c1e3df9a66f0d20ed28760dbe261737fc795610ade94e2c9ce8f`, checked 2026-11-16.
- Qualcomm Audio DSP Subsystem extension 1.0.0720.0002 for the Galaxy Book S PAHP (Windows Update 200.0.25.0), `wu://809f4e4e-5cd6-413e-a02b-2f480c16ea97/1/1309e0637a651486b8bfe5787ec6cc464ab51c1a`, 7 MB, SHA-256 `1de90d36e2aeae67956e46f6ea2a5512bcb9ebaf1105c7eebb5b69697b585506`, checked 2026-11-16.
- Qualcomm Adreno graphics driver 27.20.1640.0000 for the Galaxy Book S PAHP (Windows Update 200.0.25.0), `wu://809f4e4e-5cd6-413e-a02b-2f480c16ea97/1/ed1719eaaf12377682796d86dc47b61d46ec5b09`, 34 MB, SHA-256 `1fa296f8247b2cf0768079d2d1a0bf3a3c4b715d040273303b9614cb636f07ef`, checked 2026-11-16.
- Qualcomm Modem Subsystem extension 2.0.0900.0004 for the Galaxy Book S PAHP (Windows Update 200.0.25.0), `wu://809f4e4e-5cd6-413e-a02b-2f480c16ea97/1/201e1b626c7c78cb98e5259ac247a828fdd91451`, 42 MB, SHA-256 `3e698d6ab1f5817336e68ee16019277de3b8a0036f1c8fb9abb7f319ffc64282`, checked 2026-11-16.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/samsung/w767/qcadsp8180.mbn` | `9a84b218a468120c93ae982e5e0da18c6b8d6ffc90587e12fa395d3970b86e4b` | Qualcomm Audio DSP Subsystem extension 1.0.0720.0002 for the Galaxy Book S PAHP (Windows Update 200.0.25.0), `qcadsp8180.mbn` |
| `qcom/samsung/w767/qccdsp8180.mbn` | `4989653e99b027457ae102970b001ca5c34658b8a6ddb6fc59610aa17a981012` | Qualcomm Compute DSP Subsystem extension 1.0.1040.0000 for the Galaxy Book S PAHP (Windows Update 200.0.25.0), `qccdsp8180.mbn` |
| `qcom/samsung/w767/qcdxkmsuc8180.mbn` | `7bc9035fc38bcdc49e0a2ffbb797e65cf331592e4fab3984ae2fdacf271a4bbb` | Qualcomm Adreno graphics driver 27.20.1640.0000 for the Galaxy Book S PAHP (Windows Update 200.0.25.0), `qcdxkmsuc8180.mbn` |
| `qcom/samsung/w767/qcmpss8180_XEF.mbn` | `ecefb772cc57531edff255d59bf5639e35f00359b438eb2f4586218110e65663` | Qualcomm Modem Subsystem extension 2.0.0900.0004 for the Galaxy Book S PAHP (Windows Update 200.0.25.0), `qcmpss8180_XEF.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-samsung-w767`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
