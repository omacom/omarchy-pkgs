# NVIDIA driver policy for Omarchy GPUs

Omarchy ships two NVIDIA driver stacks and never mixes them on one GPU.

## Legacy GPUs: Maxwell, Pascal, Volta

NVIDIA made the 580 driver series the last to support Maxwell, Pascal, and Volta
(device IDs `0x1340 <= ID < 0x1e00`). Omarchy serves those GPUs from the `nvidia-580xx`
branch:

- `nvidia-580xx-utils`
- `nvidia-580xx-dkms`
- `lib32-nvidia-580xx-utils` (via `omarchy-install-gaming-gpu-lib32`)

The open kernel modules (`linux-omarchy-nvidia-open`, `nvidia-open-dkms`) and the
mainline `nvidia-utils` package are Turing+ only, so a legacy GPU must never be
given them. The two branches already conflict through `conflicts` and `provides`,
so pacman cannot hold both. Keep that; do not relax it.

When 580 stops getting new releases, this becomes a frozen legacy branch. Pin the
last release and keep shipping it as long as it builds against the current kernel.
Legacy GPUs cannot move to the newer mainline branch. The fallback is the free
`nouveau` driver for GTX 900/1000-class GPUs, with the signed-firmware and
re-clocking limits that begin with Maxwell, or a GPU upgrade.

## Modern GPUs: Turing and newer

Device IDs `0x1e00` and up. Omarchy serves these from the open kernel modules and
mainline `nvidia-utils`:

- `linux-omarchy-nvidia-open` (prebuilt with the `linux-omarchy` kernel)
- `nvidia-open-dkms` (DKMS, for other kernels)
- `nvidia-utils`

The omarchy repo selects the NVIDIA stack from the PCI device ID. `omarchy-hw-nvidia-gsp`
and `omarchy-hw-nvidia-without-gsp` report modern and legacy, and the pending
`omarchy-hw-nvidia-arch` helper consolidates those two checks. The installer, the
fallback path in the migration, and the lib32 install all route through these, so
a legacy GPU is never offered the open stack and an unclassified GPU warns and
skips instead of defaulting to it.
