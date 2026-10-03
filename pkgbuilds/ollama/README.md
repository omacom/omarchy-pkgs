# ollama and ollama-cuda (aarch64)

Omarchy's Install → AI → Ollama installs `ollama-cuda` when `nvidia-smi` is
present. Arch's recipe is x86_64-only because Arch's CUDA is; Arch Linux ARM has
neither. This is Arch's split recipe reduced to the CPU package `ollama` and an
`ollama-cuda` backend built against Omarchy's aarch64 `cuda` package with
`gcc15` as the CUDA host compiler. ROCm, Vulkan and docs are dropped.

The CUDA backend carries native code for compute capability 12.1 (GB10, the
DGX Spark) plus PTX for that capability; it has not been tested on any other
ARM GPU. The service, sysusers, tmpfiles and ld.so.conf files are Arch's.
