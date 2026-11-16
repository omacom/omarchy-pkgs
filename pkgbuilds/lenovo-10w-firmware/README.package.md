# lenovo-10w-firmware

Audio DSP, GPU, video and modem firmware for the Lenovo 10w, from Lenovo's own Windows driver download.

The firmware only runs if Lenovo signed it for this board, so linux-firmware cannot carry it until Lenovo submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [Qualcomm Chipset Driver 1.0.0830.0 for Windows 11 (Lenovo 10w, 82ST and 82SU)](https://download.lenovo.com/pccbbs/mobiles/jsqwh05.exe), 44 MB, SHA-256 `01bcfd3b5b7d478f577a9690f98f82baf8ee10e6cceaa4a4eaa4dca77752ec42`, checked 2026-11-16. The link changes with every version, and [the download page](https://download.lenovo.com/catalog/82ST_Win11.xml) lists the current one.
- [Qualcomm Display Driver 27.20.850.0 for Windows 11 (Lenovo 10w, 82ST and 82SU)](https://download.lenovo.com/pccbbs/mobiles/jsvqh05.exe), 24 MB, SHA-256 `8c1de7d469d84b56e1334be59b097abf0c65898fabbbee2b7528d9a22b094fbd`, checked 2026-11-16. The link changes with every version, and [the download page](https://download.lenovo.com/catalog/82ST_Win11.xml) lists the current one.
- [Qualcomm Wireless LAN Driver 1.0.840.0 for Windows 11 (Lenovo 10w, 82ST and 82SU)](https://download.lenovo.com/pccbbs/mobiles/jswqh04.exe), 3 MB, SHA-256 `2e0e133285ef6fb0350170255ccf8c0594ed83faccda38b5f8e04de201ab6ae1`, checked 2026-11-16. The link changes with every version, and [the download page](https://download.lenovo.com/catalog/82ST_Win11.xml) lists the current one.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sc7180/LENOVO/82ST/adspr.jsn` | `2886c96e03e61c05dfed0de59451854a2aa0bc353c2a4a468ec339af70e3e8f0` | Qualcomm Chipset Driver 1.0.0830.0 for Windows 11 (Lenovo 10w, 82ST and 82SU), `code$GetExtractPath$/qcsubsys_ext_adsp7180/adspr.jsn` |
| `qcom/sc7180/LENOVO/82ST/adspua.jsn` | `c75d16fc0805e5a0f51c6d0e0fcc315c09d5d2174d655fa038e9d9eb4217df2b` | Qualcomm Chipset Driver 1.0.0830.0 for Windows 11 (Lenovo 10w, 82ST and 82SU), `code$GetExtractPath$/qcsubsys_ext_adsp7180/adspua.jsn` |
| `qcom/sc7180/LENOVO/82ST/modemr.jsn` | `68d946cbc26fecd262e042d03dca02fd42a3d10110327621ea7c17c73b53aed8` | Qualcomm Chipset Driver 1.0.0830.0 for Windows 11 (Lenovo 10w, 82ST and 82SU), `code$GetExtractPath$/qcsubsys_ext_mpss7180/modemr.jsn` |
| `qcom/sc7180/LENOVO/82ST/modemuw.jsn` | `b7e32e64c7f323dddbe8c687861c1f9d312191d306fbfee49ce404f80ce46807` | Qualcomm Chipset Driver 1.0.0830.0 for Windows 11 (Lenovo 10w, 82ST and 82SU), `code$GetExtractPath$/qcsubsys_ext_mpss7180/modemuw.jsn` |
| `qcom/sc7180/LENOVO/82ST/qcadsp7180.mbn` | `f18245756a32b80fa3eced9f67501694f52c1910f7027486505442fc5c5b498a` | Qualcomm Chipset Driver 1.0.0830.0 for Windows 11 (Lenovo 10w, 82ST and 82SU), `code$GetExtractPath$/qcsubsys_ext_adsp7180/qcadsp7180.mbn` |
| `qcom/sc7180/LENOVO/82ST/qcdxkmsuc7180.mbn` | `459c2ff362bf8dcc6ce8cefd31da1d521dfcbab0f4c5908c472df314438fdc0e` | Qualcomm Display Driver 27.20.850.0 for Windows 11 (Lenovo 10w, 82ST and 82SU), `code$GetExtractPath$/qcdx7180/qcdxkmsuc7180.mbn` |
| `qcom/sc7180/LENOVO/82ST/qcmpss7180_nm.mbn` | `a239f72b6c048a39684af204ffd19e90219817a803507758b9aa354c6fa692e7` | Qualcomm Chipset Driver 1.0.0830.0 for Windows 11 (Lenovo 10w, 82ST and 82SU), `code$GetExtractPath$/qcsubsys_ext_mpss7180/qcmpss7180_nm.mbn` |
| `qcom/sc7180/LENOVO/82ST/qcvss7180.mbn` | `2d518f86cf1a3bc76921e7e25c8cbd279786edda577a93fbed13771ed4bad89f` | Qualcomm Display Driver 27.20.850.0 for Windows 11 (Lenovo 10w, 82ST and 82SU), `code$GetExtractPath$/qcdx7180/qcvss7180.mbn` |
| `qcom/sc7180/LENOVO/82ST/wlanmdsp.mbn` | `01cc452dac91ee13126fa49b8359f08c19cba13ff2e390c7ab34cd96042632c8` | Qualcomm Wireless LAN Driver 1.0.840.0 for Windows 11 (Lenovo 10w, 82ST and 82SU), `code$GetExtractPath$/qcwlan7180/WLANMDSP.MBN` |

## How Omarchy installs it

The package provides `qcom-firmware-sc7180-lenovo-82st`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
