# acer-aspire-16-ai-firmware

Audio DSP, compute DSP, GPU and video firmware for the Acer Aspire 16 AI, from Acer's own Windows driver download.

The firmware only runs if Acer signed it for this board, so linux-firmware cannot carry it until Acer submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running it, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [Qualcomm Base Driver 0.9100.1 for the A16-11M](https://global-download.acer.com/GDFiles/Driver/Base%20Driver/Base%20Driver_Qualcomm_0.9100.1_W11ARM64_A.zip?acerid=639240902299708134&Step1=&Step2=&Step3=ASPIRE%20A16-11M&OS=ALL&LC=en&BC=ACER&SC=PA_6), 187 MB, SHA-256 `a0244eb84019a5ee0fe6edb411440116b1a2b3420f8a5f587a4663050a95f91c`, checked 2026-11-02. The link changes with every version, and [the download page](https://www.acer.com/us-en/support/product-support/A16-11M) lists the current one.
- [Qualcomm Adreno X1-85/X1-45 Graphics Driver 2CHK7](https://dl.dell.com/FOLDER14982355M/1/Qualcomm-Adreno-X1-85-X1-45-Graphics-Driver_2CHK7_WINARM64_31.0.170.0_A11.EXE), 75 MB, SHA-256 `c6daba34013c69cc7331dfd3d1be7eb10e8765f0d082ed1091e9dad8d46f4191`, checked 2026-11-02.
- [MultiMedia driver 31.0.152.0 for the A16-11M](https://global-download.acer.com/GDFiles/Driver/Base%20Driver/Base%20Driver_Qualcomm_31.0.152.0_W11ARM64_A.zip?acerid=639240900297209757&Step1=&Step2=&Step3=ASPIRE%20A16-11M&OS=ALL&LC=en&BC=ACER&SC=PA_6), 177 MB, SHA-256 `e0450e73a8c5709d5d1604bd42eba61496276809591ead1739a3c2fcf8f6da86`, checked 2026-11-02. The link changes with every version, and [the download page](https://www.acer.com/us-en/support/product-support/A16-11M) lists the current one.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/x1p42100/ACER/A16-11M/adsp_dtbs.elf` | `cc50f6e817b2c7d262f618299bd3b049d099791e3beb594927ca893213803f01` | Qualcomm Base Driver 0.9100.1 for the A16-11M, `Base Driver_Qualcomm_0.9100.1_W11ARM64_(Qualcomm Base Driver)/qcsubsys_ext_adsp8380/adsp_dtbs.elf` |
| `qcom/x1p42100/ACER/A16-11M/adspr.jsn` | `549bb9c8e32dc6253d0d0ddde2ce5c26f75f8333d3e55861f297e169a9f3e5c0` | Qualcomm Base Driver 0.9100.1 for the A16-11M, `Base Driver_Qualcomm_0.9100.1_W11ARM64_(Qualcomm Base Driver)/qcsubsys_ext_adsp8380/adspr.jsn` |
| `qcom/x1p42100/ACER/A16-11M/adsps.jsn` | `12ac2f3ae8ced12aa4b06b3ab3a01bc4d8efe1c92ebea503c002f209a6ec176f` | Qualcomm Base Driver 0.9100.1 for the A16-11M, `Base Driver_Qualcomm_0.9100.1_W11ARM64_(Qualcomm Base Driver)/qcsubsys_ext_adsp8380/adsps.jsn` |
| `qcom/x1p42100/ACER/A16-11M/adspua.jsn` | `982a99853495e34726b8e44697fdfad303334de0a67cbf6cde306c8f1731000b` | Qualcomm Base Driver 0.9100.1 for the A16-11M, `Base Driver_Qualcomm_0.9100.1_W11ARM64_(Qualcomm Base Driver)/qcsubsys_ext_adsp8380/adspua.jsn` |
| `qcom/x1p42100/ACER/A16-11M/battmgr.jsn` | `be8c6fba330908e4683fb6282761cb08485a302d6a66e09721e102e342f27236` | Qualcomm Base Driver 0.9100.1 for the A16-11M, `Base Driver_Qualcomm_0.9100.1_W11ARM64_(Qualcomm Base Driver)/qcsubsys_ext_adsp8380/battmgr.jsn` |
| `qcom/x1p42100/ACER/A16-11M/cdsp_dtbs.elf` | `c1e3cdeee17e61ee5f9426fef78e5e35eaf9fdd49d3d39b9bd82dcad04c71647` | Qualcomm Base Driver 0.9100.1 for the A16-11M, `Base Driver_Qualcomm_0.9100.1_W11ARM64_(Qualcomm Base Driver)/qcnspmcdm_ext_cdsp8380/cdsp_dtbs.elf` |
| `qcom/x1p42100/ACER/A16-11M/cdspr.jsn` | `7e46c515ab1bb012768be6e961eca69b1c8aad9af1cbac886b3b5ae8d4228f64` | Qualcomm Base Driver 0.9100.1 for the A16-11M, `Base Driver_Qualcomm_0.9100.1_W11ARM64_(Qualcomm Base Driver)/qcnspmcdm_ext_cdsp8380/cdspr.jsn` |
| `qcom/x1p42100/ACER/A16-11M/qcadsp8380.mbn` | `c0d6fb5d0fa0cdb7e6d1057a5065a889afead5cd412f852dd74a49f04cfb0469` | Qualcomm Base Driver 0.9100.1 for the A16-11M, `Base Driver_Qualcomm_0.9100.1_W11ARM64_(Qualcomm Base Driver)/qcsubsys_ext_adsp8380/qcadsp8380.mbn` |
| `qcom/x1p42100/ACER/A16-11M/qccdsp8380.mbn` | `4d2aa10aa60245177ca253d4a8f7ee15c0a0390e877efec29fa25c7d4b725568` | Qualcomm Base Driver 0.9100.1 for the A16-11M, `Base Driver_Qualcomm_0.9100.1_W11ARM64_(Qualcomm Base Driver)/qcnspmcdm_ext_cdsp8380/qccdsp8380.mbn` |
| `qcom/x1p42100/ACER/A16-11M/qcdxkmsucpurwa.mbn` | `de957e0a25c2a42f417f8e95ccf1cbdfeed5a4a6d77a84e215389b8b78fc8bf4` | MultiMedia driver 31.0.152.0 for the A16-11M, `Base Driver_Qualcomm_31.0.152.0_W11ARM64_(MultiMedia Driver)/qcdx8380/qcdxkmsucpurwa.mbn` |
| `qcom/x1p42100/ACER/A16-11M/qcvss8380_pa.mbn` | `48a7de17a895996699c20d1d1213b426c302e29e65cd879f31fe05330e1d6bec` | Qualcomm Adreno X1-85/X1-45 Graphics Driver 2CHK7, `16299/Drivers/MUP/qcdx8380/qcvss8380_pa.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-x1p42100-acer-a16-11m`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
