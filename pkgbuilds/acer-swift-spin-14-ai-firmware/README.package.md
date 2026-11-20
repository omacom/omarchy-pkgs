# acer-swift-spin-14-ai-firmware

Audio DSP and compute DSP firmware for the Acer Swift Spin 14 AI, from Acer's own Windows driver download.

The firmware only runs if Acer signed it for this board, so linux-firmware cannot carry it until Acer submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running it, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [Qualcomm Base Driver 685.13804.40.0 for the SFSP14-Q51T](https://global-download.acer.com/GDFiles/Driver/Base%20Driver/Base%20Driver_Qualcomm_685.13804.40.0_W11ARM64_A.zip?acerid=639186471105972146&Step1=&Step2=&Step3=SWIFT%20SFSP14-Q51T&OS=ALL&LC=en&BC=ACER&SC=PA_6), 426 MB, SHA-256 `58d0aa896171fc3b895ccb0423ff506e5282bc0edcd2dcc5357bec35a10faeb9`, checked 2026-11-15. The link changes with every version, and [the download page](https://www.acer.com/us-en/support/product-support/SFSP14-Q51T) lists the current one.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/glymur/ACER/SFSP14-Q51T/adsp_dtbs.elf` | `9fbeaada8541c03ce5cbe78079d9cc6f4f2ea4b8280d84d154dbec111277b70e` | Qualcomm Base Driver 685.13804.40.0 for the SFSP14-Q51T, `Base Driver_Qualcomm_685.13804.40.0_W11ARM64_(Qualcomm Base Driver)/longcheer/qcsubsys_ext_adsp8480/adsp_dtbs.elf` |
| `qcom/glymur/ACER/SFSP14-Q51T/adspr.jsn` | `66ce8531efb7979d234e0f0eabbe18d038ac97da771a8a194f613df8f0724e81` | Qualcomm Base Driver 685.13804.40.0 for the SFSP14-Q51T, `Base Driver_Qualcomm_685.13804.40.0_W11ARM64_(Qualcomm Base Driver)/longcheer/qcsubsys_ext_adsp8480/adspr.jsn` |
| `qcom/glymur/ACER/SFSP14-Q51T/adsps.jsn` | `12ac2f3ae8ced12aa4b06b3ab3a01bc4d8efe1c92ebea503c002f209a6ec176f` | Qualcomm Base Driver 685.13804.40.0 for the SFSP14-Q51T, `Base Driver_Qualcomm_685.13804.40.0_W11ARM64_(Qualcomm Base Driver)/longcheer/qcsubsys_ext_adsp8480/adsps.jsn` |
| `qcom/glymur/ACER/SFSP14-Q51T/adspua.jsn` | `982a99853495e34726b8e44697fdfad303334de0a67cbf6cde306c8f1731000b` | Qualcomm Base Driver 685.13804.40.0 for the SFSP14-Q51T, `Base Driver_Qualcomm_685.13804.40.0_W11ARM64_(Qualcomm Base Driver)/longcheer/qcsubsys_ext_adsp8480/adspua.jsn` |
| `qcom/glymur/ACER/SFSP14-Q51T/cdsp_dtbs.elf` | `9bee104a48d4aac647287d6c1454df170c1cff7158a2352711fd1e2163ea6d1d` | Qualcomm Base Driver 685.13804.40.0 for the SFSP14-Q51T, `Base Driver_Qualcomm_685.13804.40.0_W11ARM64_(Qualcomm Base Driver)/QC/qcnspmcdm8480/cdsp_dtbs.elf` |
| `qcom/glymur/ACER/SFSP14-Q51T/qcadsp8480.mbn` | `5b61be789919d3d0486e99f342063708974065f6f6312ca4aebe638e55547f5d` | Qualcomm Base Driver 685.13804.40.0 for the SFSP14-Q51T, `Base Driver_Qualcomm_685.13804.40.0_W11ARM64_(Qualcomm Base Driver)/longcheer/qcsubsys_ext_adsp8480/qcadsp8480.mbn` |
| `qcom/glymur/ACER/SFSP14-Q51T/qccdsp8480.mbn` | `acf13d29288d283793f418a36650e8a261eed927d30de109a59cb2210f458794` | Qualcomm Base Driver 685.13804.40.0 for the SFSP14-Q51T, `Base Driver_Qualcomm_685.13804.40.0_W11ARM64_(Qualcomm Base Driver)/QC/qcnspmcdm8480/qccdsp8480.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-glymur-acer-sfsp14-q51t`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
