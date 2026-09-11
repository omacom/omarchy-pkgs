# CUDA-compatible host compiler

CUDA 13.0's nvcc explicitly rejects GCC versions newer than 15;
the initial native Arch compilation test failed with Arch ARM's GCC 16.

This package builds GNU GCC 15.3.0 for aarch64 under `/opt/gcc15`, so it can coexist
with Arch's system compiler. Select it explicitly using
`nvcc -ccbin /opt/gcc15/bin/g++`. No unsupported-compiler bypass is configured.

The source checksum is from GNU's published release `sha512.sum`. This first
build uses a single-stage C/C++ compiler configuration; bootstrap comparison and
the full GCC testsuite are not performed. Optional sanitizer/quadmath runtimes
are excluded. C/C++ and native CUDA compilation/execution tests are required
before treating this package as validated.
