# asus-vivobook-s15-firmware

Audio DSP, compute DSP, GPU and video firmware for the ASUS Vivobook S 15, from ASUS's own Windows driver download.

The firmware only runs if ASUS signed it for this board, so linux-firmware cannot carry it until ASUS submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [S5507QA V1.318.7800.0](https://dlcdnets.asus.com/pub/ASUS/nb/Image/Driver/DriverPackage/43699/SOCPackage_forWebSite_Qualcomm_Z_V1.318.7800.0_43699_1.exe), 176 MB, SHA-256 `7d8fa75780fe2a2fd90882ac7c4dcca21152ba3cd4eb33183bfa6c72f4f20801`, checked 2026-11-02.
- [S5507QAD V1.367.7800.0](https://dlcdnets.asus.com/pub/ASUS/nb/Image/Driver/DriverPackage/44984/SOCPackage_forWebSite_Qualcomm_Z_V1.367.7800.0_44984.exe), 176 MB, SHA-256 `90bb38a0e60085ce5cd43ab8583d84843c36cc7763d457241f022c8b032867bc`, checked 2026-11-02.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/x1e80100/ASUSTeK/vivobook-s15/adsp_dtbs.elf` | `4cf6f9eb7a4e5cf78481af0e8787ea61b6ac1d8ea72d5ce9785a72e02adda04d` | S5507QA V1.318.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_0324_Signed/adsp_dtbs.elf` |
| `qcom/x1e80100/ASUSTeK/vivobook-s15/adspr.jsn` | `e9ba7199626b0c03f2ec02822d744f678ad567fe0625a28fe5f5908b7281e9db` | S5507QA V1.318.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_0324_Signed/adspr.jsn` |
| `qcom/x1e80100/ASUSTeK/vivobook-s15/adsps.jsn` | `19b1396b5e2c0d14fb8a4eb8e47181df7f62989f4af519b439cf0ee45a46f76e` | S5507QA V1.318.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_0324_Signed/adsps.jsn` |
| `qcom/x1e80100/ASUSTeK/vivobook-s15/adspua.jsn` | `d65dc1aedce2c1131da8ffaed7dcffc05cc9c58da491e0c39acb2ac5b3f4bc1d` | S5507QA V1.318.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_0324_Signed/adspua.jsn` |
| `qcom/x1e80100/ASUSTeK/vivobook-s15/battmgr.jsn` | `b8aad1d149128f414eb1fd6fcbb6e0a5b7dabcd2cba001599e1ce9a0e2e291a4` | S5507QA V1.318.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_0324_Signed/battmgr.jsn` |
| `qcom/x1e80100/ASUSTeK/vivobook-s15/cdsp_dtbs.elf` | `1e0535bd2a8adcd14d6079ffa99f6fce5c6561d4759a60f6076dcfbaa4437f8a` | S5507QA V1.318.7800.0, `Driver/QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/cdsp_dtbs.elf` |
| `qcom/x1e80100/ASUSTeK/vivobook-s15/cdspr.jsn` | `7e46c515ab1bb012768be6e961eca69b1c8aad9af1cbac886b3b5ae8d4228f64` | S5507QA V1.318.7800.0, `Driver/QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/cdspr.jsn` |
| `qcom/x1e80100/ASUSTeK/vivobook-s15/qcadsp8380.mbn` | `4ddea417cedc2eb965f3e6559ca92ea1a112c4c3bd8b901ddb5eca06d50970f7` | S5507QA V1.318.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_0324_Signed/qcadsp8380.mbn` |
| `qcom/x1e80100/ASUSTeK/vivobook-s15/qccdsp8380.mbn` | `4387fa1a234aacbff50f8a215b96536d17c4b25b6b798392e15a162e4adcd7a0` | S5507QA V1.318.7800.0, `Driver/QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/qccdsp8380.mbn` |
| `qcom/x1e80100/ASUSTeK/vivobook-s15/qcdxkmsuc8380.mbn` | `10ac12861f2b12154f055928033a407f37fb9d87967e6d0cc0636a277f007932` | S5507QA V1.318.7800.0, `Driver/QualcommBSP/GFX/qcdx8380/qcdxkmsuc8380.mbn` |
| `qcom/x1e80100/ASUSTeK/vivobook-s15/qcvss8380.mbn` | `d81f81727c6b51fd760e842e77377f83375c5163c4965cab50d5c5c6cb74ec4a` | S5507QA V1.318.7800.0, `Driver/QualcommBSP/GFX/qcdx8380/qcvss8380.mbn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s15/adsp_dtbs.elf` | `e251321b394b41ae9ff79af254805aca8f5f0204907a57254976008f340d96c6` | S5507QAD V1.367.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_QAD_Signed/adsp_dtbs.elf` |
| `qcom/x1p42100/ASUSTeK/vivobook-s15/adspr.jsn` | `e9ba7199626b0c03f2ec02822d744f678ad567fe0625a28fe5f5908b7281e9db` | S5507QAD V1.367.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_QAD_Signed/adspr.jsn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s15/adsps.jsn` | `19b1396b5e2c0d14fb8a4eb8e47181df7f62989f4af519b439cf0ee45a46f76e` | S5507QAD V1.367.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_QAD_Signed/adsps.jsn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s15/adspua.jsn` | `d65dc1aedce2c1131da8ffaed7dcffc05cc9c58da491e0c39acb2ac5b3f4bc1d` | S5507QAD V1.367.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_QAD_Signed/adspua.jsn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s15/battmgr.jsn` | `b8aad1d149128f414eb1fd6fcbb6e0a5b7dabcd2cba001599e1ce9a0e2e291a4` | S5507QAD V1.367.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_QAD_Signed/battmgr.jsn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s15/cdsp_dtbs.elf` | `1e0535bd2a8adcd14d6079ffa99f6fce5c6561d4759a60f6076dcfbaa4437f8a` | S5507QAD V1.367.7800.0, `Driver/QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/cdsp_dtbs.elf` |
| `qcom/x1p42100/ASUSTeK/vivobook-s15/cdspr.jsn` | `7e46c515ab1bb012768be6e961eca69b1c8aad9af1cbac886b3b5ae8d4228f64` | S5507QAD V1.367.7800.0, `Driver/QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/cdspr.jsn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s15/qcadsp8380.mbn` | `d8e2d3d5403f5da9e2f5194e26920e45bfa77d93fe71fdb742c4976bf13a05f7` | S5507QAD V1.367.7800.0, `Driver/QualcommBSP/Subsystem/qcsubsys_ext_adsp8380_QAD_Signed/qcadsp8380.mbn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s15/qccdsp8380.mbn` | `4387fa1a234aacbff50f8a215b96536d17c4b25b6b798392e15a162e4adcd7a0` | S5507QAD V1.367.7800.0, `Driver/QualcommBSP/NPU/qcnspmcdm_ext_cdsp8380/qccdsp8380.mbn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s15/qcdxkmsucpurwa.mbn` | `f9342cb44a79f5abdd1f0ae888c6c3df8e60f28a6c3a5077591369268d1b5c0a` | S5507QAD V1.367.7800.0, `Driver/QualcommBSP/GFX/qcdx8380/qcdxkmsucpurwa.mbn` |
| `qcom/x1p42100/ASUSTeK/vivobook-s15/qcvss8380.mbn` | `60ef91ee42fe360f87cf8ff5ee8ec399f90df7160b533f0dbca3cc30a4c5a4ff` | S5507QAD V1.367.7800.0, `Driver/QualcommBSP/GFX/qcdx8380/qcvss8380_pa.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-x1e80100-asustek-vivobook-s15` and `qcom-firmware-x1p42100-asustek-vivobook-s15`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
