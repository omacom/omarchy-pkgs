# samsung-galaxy-book-go-firmware

Audio DSP, GPU, video and modem firmware for the Samsung Galaxy Book Go, from the driver bundle Samsung publishes for it on Windows Update.

The firmware only runs if Samsung signed it for this board, so linux-firmware cannot carry it until Samsung submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Audio DSP Subsystem extension 1.0.0750.0004 for the Galaxy Book Go PAJW (Windows Update 200.0.17.0), `wu://96754232-ab9d-43a4-ab41-e6ffdc1b74b0/1/51ef3d273670c1df1df846d19ac283ddd745756f`, 9 MB, SHA-256 `56b2f48c292cd769e3b40de1f0413ef75986e57ab6213c68d1751260253530d4`, checked 2026-11-16.
- Qualcomm Modem Subsystem extension 1.0.0800.0008 for the Galaxy Book Go PAJS (Windows Update 200.0.18.0), `wu://25c4b8c0-921d-48ee-9507-3064890b5e64/1/695c8f743c8e0676e4bb912e286436bb852e9ed9`, 41 MB, SHA-256 `29c680eac1c3d35d679ee510417a17f1b032e56753b9fd5c46449c811b2534b7`, checked 2026-11-16.
- Qualcomm Adreno graphics driver 27.20.0910.0000 for the Galaxy Book Go PAJS (Windows Update 200.0.18.0), `wu://25c4b8c0-921d-48ee-9507-3064890b5e64/1/fc0b35b7dd7eaf03782857844f7ce5e82038fa68`, 32 MB, SHA-256 `9270114e230e18a4d82016770ccb85e84fbe21a15f3db7e4ce0fb3fc0afb4aba`, checked 2026-11-16.
- Qualcomm WLAN driver 1.0.0970.0000 for the Galaxy Book Go PAJS (Windows Update 200.0.18.0), `wu://25c4b8c0-921d-48ee-9507-3064890b5e64/1/1ad942b5aeff85656081cde8a5ad288cd4e84b15`, 2 MB, SHA-256 `a53a79f652eee23952257f96a825921a0705970eb4f520ca18d042aaa42c5b2c`, checked 2026-11-16.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sc7180/Samsung/galaxy-book-go/adspr.jsn` | `2886c96e03e61c05dfed0de59451854a2aa0bc353c2a4a468ec339af70e3e8f0` | Qualcomm Audio DSP Subsystem extension 1.0.0750.0004 for the Galaxy Book Go PAJW (Windows Update 200.0.17.0), `adspr.jsn` |
| `qcom/sc7180/Samsung/galaxy-book-go/adspua.jsn` | `c75d16fc0805e5a0f51c6d0e0fcc315c09d5d2174d655fa038e9d9eb4217df2b` | Qualcomm Audio DSP Subsystem extension 1.0.0750.0004 for the Galaxy Book Go PAJW (Windows Update 200.0.17.0), `adspua.jsn` |
| `qcom/sc7180/Samsung/galaxy-book-go/modemr.jsn` | `68d946cbc26fecd262e042d03dca02fd42a3d10110327621ea7c17c73b53aed8` | Qualcomm Modem Subsystem extension 1.0.0800.0008 for the Galaxy Book Go PAJS (Windows Update 200.0.18.0), `modemr.jsn` |
| `qcom/sc7180/Samsung/galaxy-book-go/modemuw.jsn` | `b7e32e64c7f323dddbe8c687861c1f9d312191d306fbfee49ce404f80ce46807` | Qualcomm Modem Subsystem extension 1.0.0800.0008 for the Galaxy Book Go PAJS (Windows Update 200.0.18.0), `modemuw.jsn` |
| `qcom/sc7180/Samsung/galaxy-book-go/qcadsp7180.mbn` | `5704b2b9be07fda4faeb8b3ba91dfff8124bc0fb7b96f85de4a14e787b9a8c9d` | Qualcomm Audio DSP Subsystem extension 1.0.0750.0004 for the Galaxy Book Go PAJW (Windows Update 200.0.17.0), `qcadsp7180.mbn` |
| `qcom/sc7180/Samsung/galaxy-book-go/qcdxkmsuc7180.mbn` | `ab040159aee7ab7e2631acc3d2873be3bf72eafe066521a9fd5d906759deefe6` | Qualcomm Adreno graphics driver 27.20.0910.0000 for the Galaxy Book Go PAJS (Windows Update 200.0.18.0), `qcdxkmsuc7180.mbn` |
| `qcom/sc7180/Samsung/galaxy-book-go/qcmpss7180_nm.mbn` | `a4016412a5071a95934b0e9db343d51dd8b1cda1252f3b6baae09b34356f02f2` | Qualcomm Modem Subsystem extension 1.0.0800.0008 for the Galaxy Book Go PAJS (Windows Update 200.0.18.0), `qcmpss7180_nm.mbn` |
| `qcom/sc7180/Samsung/galaxy-book-go/qcvss7180.mbn` | `280ed4a092017770634e1f9e75538043100e42bc922c209eff160daf8c91b3e0` | Qualcomm Adreno graphics driver 27.20.0910.0000 for the Galaxy Book Go PAJS (Windows Update 200.0.18.0), `qcvss7180.mbn` |
| `qcom/sc7180/Samsung/galaxy-book-go/wlanmdsp.mbn` | `7688eea1c13715289f58c8d379b9f73b81d072415ac141b10b4732d5059f7f4b` | Qualcomm WLAN driver 1.0.0970.0000 for the Galaxy Book Go PAJS (Windows Update 200.0.18.0), `WLANMDSP.MBN` |

## How Omarchy installs it

The package provides `qcom-firmware-sc7180-samsung-galaxy-book-go`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
