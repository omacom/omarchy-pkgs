# perftest

Upstream linux-rdma/perftest 26.04.17 (SHA256-verified tag archive), host-memory
build for aarch64. Arch Linux ARM ships `rdma-core` but not `perftest`; this recipe
fills the gap for RDMA/RoCE validation on systems with ConnectX adapters such as
the NVIDIA DGX Spark.

CUDA memory modes (`--use_cuda`) are not built here: the build host has no CUDA
package yet. When the CUDA recipes (omarchy-pkgs#379) are published, add
`--enable-cudart` with `NVCC_CCBIN` pointing at a supported GCC and rebuild; the
reference recipe in `omarchy-spark` shows the flags.

Carried from the `omarchy-spark` reference port.
