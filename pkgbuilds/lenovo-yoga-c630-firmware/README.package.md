# lenovo-yoga-c630-firmware

Audio DSP, compute DSP, GPU, video, modem and sensor DSP firmware for the Lenovo Yoga C630, from the driver bundle Lenovo publishes for it on Windows Update.

The firmware only runs if Lenovo signed it for this board, so linux-firmware cannot carry it until Lenovo submits it. The package holds no firmware itself. Its recipe downloads the driver cabinets below when the package is built, unpacks them without running anything, checks every file against the SHA-256 it was matched to and installs it under the name the device tree asks for, compressed with xz.

Windows Update hands out short-lived links only, so a `wu://` source names the update ID, revision and SHA-1 of a file, and [wudrivers](https://github.com/birkskyum/wudrivers) fetches a fresh link for it when the package builds. makepkg then checks the file against its SHA-256 like any other source.

## Source

- Qualcomm Subsystem driver 1.0.10440.0000 for the 81JL (Windows Update 200.0.16.0), `wu://9fdf0fab-06de-463a-948a-b08a3fea73ac/1/d4b09fb5172dc20174961b7689c1c52c9e31af34`, 45 MB, SHA-256 `2cea11f9aa914534603d1fade853ceface9c770ae1cc132f3f6f89e764bd764a`, checked 2026-11-15.
- Qualcomm Adreno graphics driver 25.18.10440.0000 for the 81JL (Windows Update 200.0.16.0), `wu://9fdf0fab-06de-463a-948a-b08a3fea73ac/1/ec8ddf9a902ecec56bc1f5e2de8f9f18d6c70585`, 29 MB, SHA-256 `8eeba54f315a905f71acb230f4597540cd8b68ec0cdf04b0e0fc0cad19ab08af`, checked 2026-11-15.
- Qualcomm IPA driver 1.0.10440.0000 for the 81JL (Windows Update 200.0.16.0), `wu://9fdf0fab-06de-463a-948a-b08a3fea73ac/1/ba6078acaba6fa9e6a3ae480cf0ef942bb32df26`, 1 MB, SHA-256 `cf523bc799ecb5d834f7a1eec76133e3969e85e7ad6ecd61d1fd42447da28827`, checked 2026-11-15.

## Files

| File | SHA-256 | From |
| --- | --- | --- |
| `qcom/sdm850/LENOVO/81JL/ipa_fws.elf` | `74c8c6774b255fc328dc1b2a2826249e137348bee093f2817632f5a563e06838` | Qualcomm IPA driver 1.0.10440.0000 for the 81JL (Windows Update 200.0.16.0), `ipa_fws.elf` |
| `qcom/sdm850/LENOVO/81JL/qcadsp850.mbn` | `f733b9ba8288c58e9ed18c5ef4a2a85668007d32944002290b311f1e2105bb82` | Qualcomm Subsystem driver 1.0.10440.0000 for the 81JL (Windows Update 200.0.16.0), `qcadsp850.mbn` |
| `qcom/sdm850/LENOVO/81JL/qccdsp850.mbn` | `4f45c8d6e14e655c6913aab556ed5cbf6ee216837aeda24eb03540f8103c664a` | Qualcomm Subsystem driver 1.0.10440.0000 for the 81JL (Windows Update 200.0.16.0), `qccdsp850.mbn` |
| `qcom/sdm850/LENOVO/81JL/qcdsp1v2850.mbn` | `934004f04eecc6c1d801a65dea58eb960ddef55836832d83b5490b33aae2ebb2` | Qualcomm Subsystem driver 1.0.10440.0000 for the 81JL (Windows Update 200.0.16.0), `qcdsp1v2850.mbn` |
| `qcom/sdm850/LENOVO/81JL/qcdsp2850.mbn` | `d4ecfa7bf247acb50998076925776919f15f33924346f3a96ec6f1ab86926ff0` | Qualcomm Subsystem driver 1.0.10440.0000 for the 81JL (Windows Update 200.0.16.0), `qcdsp2850.mbn` |
| `qcom/sdm850/LENOVO/81JL/qcdxkmsuc850.mbn` | `42cc524529adea502442c7c0541af1ac1d0b1365cebae830fcc523f062a13ace` | Qualcomm Adreno graphics driver 25.18.10440.0000 for the 81JL (Windows Update 200.0.16.0), `qcdxkmsuc850.mbn` |
| `qcom/sdm850/LENOVO/81JL/qcslpi850.mbn` | `edb1632cb8a30d85875826a3cfae24605443955551a2f5fe7c5f4ae80e85be8b` | Qualcomm Subsystem driver 1.0.10440.0000 for the 81JL (Windows Update 200.0.16.0), `qcslpi850.mbn` |
| `qcom/sdm850/LENOVO/81JL/qcvss850.mbn` | `caf0cfac983c90ea1097ab4a2d184754151288c81a85a5daa053dd2fcc007ca3` | Qualcomm Adreno graphics driver 25.18.10440.0000 for the 81JL (Windows Update 200.0.16.0), `qcvss850.mbn` |

## How Omarchy installs it

The package provides `qcom-firmware-sdm850-lenovo-81jl`. Omarchy's `install/hardware/qualcomm/oem-firmware.sh` takes the folders the machine's device tree loads firmware from, as `qcom-firmware-extract --list-missing` prints them, and installs the package that provides each folder's name, so the machine needs no step of its own.

## Retirement

The kernel tries the plain name, then `.zst`, then `.xz`, so once linux-firmware ships the same files, its copies are the ones loaded. The recipe is generated from [the firmware table](https://arewearmyet.com/firmware-sources.json) by [snapdragon-firmware-recipes.py](https://github.com/birkskyum/arewearmyet/blob/main/scripts/snapdragon-firmware-recipes.py), which leaves out what linux-firmware ships and says when nothing is left. Drop the package then.
