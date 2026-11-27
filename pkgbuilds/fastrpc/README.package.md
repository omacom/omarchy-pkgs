# fastrpc

Qualcomm's [FastRPC](https://github.com/qualcomm/fastrpc) userspace for the Hexagon DSPs on Snapdragon machines: the CPU side of the remote procedure calls a program makes to the audio DSP (ADSP) or the compute DSP (CDSP, the "NPU").

The kernel driver (`qcom,fastrpc`) creates `/dev/fastrpc-adsp`, `/dev/fastrpc-cdsp` and `/dev/fastrpc-cdsp-secure` once the DSPs are running. This package adds:

- `libcdsprpc.so`, `libadsprpc.so`, `libsdsprpc.so` and the default listeners, which llama.cpp's Hexagon backend, QNN's HTP backend and other DSP programs load, with headers in `/usr/include/fastrpc`.
- `cdsprpcd`, `adsprpcd`, `sdsprpcd`, `gdsprpcd` and their units. Each attaches to a DSP's root process and serves its file reads and exception logs.
- `60-fastrpc.rules`: the nodes become `root:fastrpc` mode 0640 (the secure ones stay root only), the `system` DMA heap gets a `fastrpc` ACL, and `cdsprpcd` / `adsprpcd` start when their node appears. Upstream also starts `adsprpcd_audiopd` from the rule; this package does not (see below).
- `fastrpc.conf` in sysusers.d, which creates the `fastrpc` group. Add a user with `sudo gpasswd -a "$USER" fastrpc` and log in again; the node permissions apply from the next boot.
- `fastrpc_test` and `fastrpc-healthcheck`, with upstream's test libraries in `/usr/lib/fastrpc_test` and `/usr/share/fastrpc_test` (prebuilt Hexagon v68 and v75 skeletons).

## What is not here

No DSP-side code. Running anything on the CDSP needs Qualcomm's `fastrpc_shell_unsigned_3` (or the signed `fastrpc_shell_3`) built for the machine's CDSP firmware, plus `libc++.so.1` and `libc++abi.so.1` for the DSP. The library looks for the shell in each of these directories, trying `<dir>/cdsp/<name>` before `<dir>/<name>`:

1. `/usr/share/qcom/<DSP_LIBRARY_PATH>`, where a YAML file in `/usr/share/qcom/conf.d/` maps the device tree model (`/sys/firmware/devicetree/base/model`) to `DSP_LIBRARY_PATH`. This is the layout [hexagon-dsp-binaries](https://github.com/linux-msm/hexagon-dsp-binaries) installs, e.g. `x1e80100/Qualcomm/Hamoa-IoT-EVK/dsp`;
2. `/usr/lib/rfsa/adsp` and `/usr/lib/dsp`;
3. `/vendor/dsp`.

DSP-side libraries the DSP asks for afterwards (`libc++.so.1`, skeletons such as `libggml-htp-v73.so`) are searched in `$ADSP_LIBRARY_PATH` (or `$DSP_LIBRARY_PATH`), then `/usr/share/qcom/hexagon/v<arch>` (v73 on Snapdragon X Elite), then the same list.

Without a shell, `fastrpc_test` fails with `open_shell failed for domain 3, tried 'fastrpc_shell_unsigned_3' and 'fastrpc_shell_unsigned'` in the journal. The daemons do not need one.

## adsprpcd_audiopd

Upstream's rule starts it with every ADSP. It asks the ADSP to create its static audio process in memory the kernel hands over, and on boards whose device tree does not protect that memory it resets the machine (qualcomm/fastrpc#414). Linux audio on Snapdragon laptops does not use that process, so here it only runs if started by hand.

## fastrpc-healthcheck

It reports a running DSP as `Offline` when the firmware file is compressed (`.mbn.xz`, as Omarchy's firmware packages install it): it looks for the uncompressed name the remoteproc requests. Check `/sys/class/remoteproc/*/state` instead.

## Licence

BSD-3-Clause.
