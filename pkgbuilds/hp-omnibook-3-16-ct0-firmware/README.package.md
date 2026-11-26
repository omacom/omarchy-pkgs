# hp-omnibook-3-16-ct0-firmware

Audio DSP, compute DSP, GPU and video firmware for the HP OmniBook 3 16 (16-ct0), from HP's own Windows driver download.

The firmware only runs if HP signed it for this board, so linux-firmware cannot carry it until HP submits it. The package holds no firmware itself. Its recipe downloads the driver package below when the package is built, unpacks it without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

## Source

- [Qualcomm Driver Pack r02010.1 for the HP OmniBook 3 16-ct0 (boards 8FD0 and 8FD1)](https://ftp.hp.com/pub/softpaq/sp174501-175000/sp174797.exe), 150 MB, SHA-256 `c0b43804f921d3e74494753fe8891b77bc09fe347f949d25365e50aabc543569`, checked 2026-11-15.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sc7280/HP/omnibook-3-16-ct0/adspr.jsn` | `e9ba7199626b0c03f2ec02822d744f678ad567fe0625a28fe5f5908b7281e9db` | Qualcomm Driver Pack r02010.1 for the HP OmniBook 3 16-ct0 (boards 8FD0 and 8FD1), `src/Driver/qcsubsys_ext_adsp8270/adspr.jsn` |
| `qcom/sc7280/HP/omnibook-3-16-ct0/adsps.jsn` | `19b1396b5e2c0d14fb8a4eb8e47181df7f62989f4af519b439cf0ee45a46f76e` | Qualcomm Driver Pack r02010.1 for the HP OmniBook 3 16-ct0 (boards 8FD0 and 8FD1), `src/Driver/qcsubsys_ext_adsp8270/adsps.jsn` |
| `qcom/sc7280/HP/omnibook-3-16-ct0/adspua.jsn` | `d65dc1aedce2c1131da8ffaed7dcffc05cc9c58da491e0c39acb2ac5b3f4bc1d` | Qualcomm Driver Pack r02010.1 for the HP OmniBook 3 16-ct0 (boards 8FD0 and 8FD1), `src/Driver/qcsubsys_ext_adsp8270/adspua.jsn` |
| `qcom/sc7280/HP/omnibook-3-16-ct0/cdspr.jsn` | `7e46c515ab1bb012768be6e961eca69b1c8aad9af1cbac886b3b5ae8d4228f64` | Qualcomm Driver Pack r02010.1 for the HP OmniBook 3 16-ct0 (boards 8FD0 and 8FD1), `src/Driver/qcsubsys_ext_cdsp8270/cdspr.jsn` |
| `qcom/sc7280/HP/omnibook-3-16-ct0/qcadsp8270.mbn` | `0c7dd9beb5d970c7d54532eddbf141fc5acd244ff86808f5abf92355a6fc35c9` | Qualcomm Driver Pack r02010.1 for the HP OmniBook 3 16-ct0 (boards 8FD0 and 8FD1), `src/Driver/qcsubsys_ext_adsp8270/qcadsp8270.mbn` |
| `qcom/sc7280/HP/omnibook-3-16-ct0/qccdsp8270.mbn` | `49a64694086e9979605445506e89adfc9203d18e92c610be754e76ec17432fef` | Qualcomm Driver Pack r02010.1 for the HP OmniBook 3 16-ct0 (boards 8FD0 and 8FD1), `src/Driver/qcsubsys_ext_cdsp8270/qccdsp8270.mbn` |
| `qcom/sc7280/HP/omnibook-3-16-ct0/qcdxkmsuc8270.mbn` | `5a87622c1fe32fd024523953dd6f7028eaf0d2295538701d2dad7107cd4372e4` | Qualcomm Driver Pack r02010.1 for the HP OmniBook 3 16-ct0 (boards 8FD0 and 8FD1), `src/Driver/qcdx8270/qcdxkmsuc8270.mbn` |
| `qcom/sc7280/HP/omnibook-3-16-ct0/qcvss8270.mbn` | `f6c80b8f28bc794b75610024d51e90fcb1a6c505a51e32dd01589eb2de6ea8e0` | Qualcomm Driver Pack r02010.1 for the HP OmniBook 3 16-ct0 (boards 8FD0 and 8FD1), `src/Driver/qcdx8270/qcvss8270.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-sc7280-hp-omnibook-3-16-ct0`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
