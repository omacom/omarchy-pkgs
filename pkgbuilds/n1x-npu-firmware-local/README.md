# Local SROOT firmware preparation tools

This package contains Python source and documentation only. It contains no
NVIDIA firmware/driver and does not download, extract, install firmware or start
hardware during package build or installation. It is CI-buildable without OEM
inputs. `skip_build: true` only excludes unscoped local builds; CI still builds
this source-only package. `sync: false` requires manual ABI/hash review.

Supply your own NVIDIA 617.42 Windows ARM64 nvlddmkm.sys under its applicable
license. Upstream n1x-npu-linux 92e9434a records the 617.42 archive SHA256 as
425a75f54655ddcc8ee6859cec49bc431a17ef18094daaf59f205b159fb6e2bd.
The tool checks the entire KMD and each extracted firmware image, with bounded
PE section parsing. It refuses unknown inputs and existing outputs.

    n1x-npu-prepare-firmware --kmd /local/nvlddmkm.sys --output-dir ./sroot

Review hashes, then explicitly copy sroot-v0.bin and sroot-v1.bin to
/usr/lib/firmware/nvidia/n1x/ with root ownership and mode 0600. That is an
administrator action; the tool never restarts a service or loads a module.
Do not place firmware in a public source PR or generated CI artifact.

The extractor is based on the MIT-covered prepare_inputs.py from
johannhartmann/n1x-npu-linux, reviewed commit 92e9434a65d2b9d3bb0517efb9efc371e9c6b42c.
Source license does not grant rights to NVIDIA inputs or extracted outputs.
No redistribution rights are asserted here. Maintainers must review applicable
NVIDIA driver/firmware terms before any separate binary distribution proposal.
https://docs.nvidia.com/cuda/eula/index.html is a starting point, not evidence
that these particular Windows driver firmware images are redistributable.

The pinned firmware/provider combination passed numerical NPU jobs and a
78.482-second s2idle cycle on one ASUS P16 N1X. This preparation-tool package
only verifies bytes and does not establish broader hardware compatibility.
