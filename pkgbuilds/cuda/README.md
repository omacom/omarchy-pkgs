# cuda (aarch64)

The recipe pins all 56 CUDA 13.0 toolkit payloads from NVIDIA's SBSA repository,
including NVVM/PTX compilation, nvJPEG and GDS tools. Hashes come from NVIDIA's
APT metadata for that repository. Source hashes are checked by makepkg;
DEBs are extracted without executing their maintainer scripts.

CUDA 13.0 requires a supported host compiler. Use the side-by-side gcc15 package:

```sh
nvcc -ccbin /opt/gcc15/bin/g++ -arch=sm_121 example.cu -o example
```

Release 2 adapts Arch's glibc 2.42 compatibility patch to the SBSA include path:
https://gitlab.archlinux.org/archlinux/packaging/packages/cuda/-/commit/c36d77ac1d8e60fcd97490f8e432a8d034ddcc10

This changes the rsqrt/rsqrtf exception declarations to match glibc. The compiler
version check is not bypassed. Both compile and GPU execution must be tested;
packaging alone does not establish compatibility. GDS additionally requires
kernel/storage support and is not established by the unified-memory smoke test.

The package keeps NVIDIA's license text under /usr/share/licenses. The payloads
are NVIDIA's own SBSA (generic ARM64 server) toolkit, so nothing here is
DGX-specific except the tested GPU; Arch Linux ARM ships no cuda package.
