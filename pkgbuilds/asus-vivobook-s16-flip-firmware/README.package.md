# asus-vivobook-s16-flip-firmware

Audio DSP, compute DSP, GPU and video firmware for the ASUS Vivobook S16 Flip TP5608QA, from ASUS's own Windows driver download.

The firmware only runs if ASUS signed it for this board, so linux-firmware cannot carry it until ASUS submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running it, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Its files are byte for byte the ones in `qcom/x126100/ASUSTeK/vivobook-s14-flip-tp5408qa`, which the table links them to as linux-firmware's WHENCE would, so the recipe can take them from another machine's download, the smallest that holds them.

## Source

- [TP5408QA V1.305.9300.0](https://dlcdnets.asus.com/pub/ASUS/nb/Image/Driver/DriverPackage/51031/SOCPackage_forWebSite_Qualcomm_Z_V1.305.9300.0_51031.exe), 387 MB, SHA-256 `a2b5dbd232923eed04949904da3281b43f1cea1a0b17c9887e041bcafe300035`, checked 2026-11-14.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/x126100/ASUSTeK/vivobook-s16-flip-tp5608qa/adsp_dtbs.elf` | `c39f3953179a1d4924cb47a8c08cf69fdcf2bda453ec04ff674c35bb627db39b` | TP5408QA V1.305.9300.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8380/adsp_dtbs.elf` |
| `qcom/x126100/ASUSTeK/vivobook-s16-flip-tp5608qa/adspr.jsn` | `549bb9c8e32dc6253d0d0ddde2ce5c26f75f8333d3e55861f297e169a9f3e5c0` | TP5408QA V1.305.9300.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8380/adspr.jsn` |
| `qcom/x126100/ASUSTeK/vivobook-s16-flip-tp5608qa/adsps.jsn` | `12ac2f3ae8ced12aa4b06b3ab3a01bc4d8efe1c92ebea503c002f209a6ec176f` | TP5408QA V1.305.9300.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8380/adsps.jsn` |
| `qcom/x126100/ASUSTeK/vivobook-s16-flip-tp5608qa/adspua.jsn` | `982a99853495e34726b8e44697fdfad303334de0a67cbf6cde306c8f1731000b` | TP5408QA V1.305.9300.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8380/adspua.jsn` |
| `qcom/x126100/ASUSTeK/vivobook-s16-flip-tp5608qa/cdsp_dtbs.elf` | `c1e3cdeee17e61ee5f9426fef78e5e35eaf9fdd49d3d39b9bd82dcad04c71647` | TP5408QA V1.305.9300.0, `QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/cdsp_dtbs.elf` |
| `qcom/x126100/ASUSTeK/vivobook-s16-flip-tp5608qa/cdspr.jsn` | `7e46c515ab1bb012768be6e961eca69b1c8aad9af1cbac886b3b5ae8d4228f64` | TP5408QA V1.305.9300.0, `QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/cdspr.jsn` |
| `qcom/x126100/ASUSTeK/vivobook-s16-flip-tp5608qa/qcadsp8380.mbn` | `83bf4d7a5ca5d4607d90af6625b90d6b05e190a44c37f0932e1c2af72945ede5` | TP5408QA V1.305.9300.0, `QualcommBSP/Subsystem/qcsubsys_ext_adsp8380/qcadsp8380.mbn` |
| `qcom/x126100/ASUSTeK/vivobook-s16-flip-tp5608qa/qccdsp8380.mbn` | `4d2aa10aa60245177ca253d4a8f7ee15c0a0390e877efec29fa25c7d4b725568` | TP5408QA V1.305.9300.0, `QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/qccdsp8380.mbn` |
| `qcom/x126100/ASUSTeK/vivobook-s16-flip-tp5608qa/qcdxkmsucpurwa.mbn` | `848341997c48213d818168ed0ec48ee722c30738e5ffede40550d38252e3ac71` | TP5408QA V1.305.9300.0, `QualcommBSP/GFX/qcdx8380/qcdxkmsucpurwa.mbn` |
| `qcom/x126100/ASUSTeK/vivobook-s16-flip-tp5608qa/qcvss8380.mbn` | `fa5e78c9743c5ca3439baadfe7f1e118591f8a1ad976e9f87b75937945d42e8b` | TP5408QA V1.305.9300.0, `QualcommBSP/GFX/qcdx8380/qcvss8380.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-x126100-asustek-vivobook-s16-flip-tp5608qa`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
