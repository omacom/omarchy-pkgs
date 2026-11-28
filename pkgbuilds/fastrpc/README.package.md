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

## Queue Monitor firmware (DSPQUEUE_QUEUE_MONITOR)

Some CDSP firmware builds, made for the Windows scheduler, run dspqueues in "Queue Monitor" mode: the DSP starts no thread of its own for a queue and takes packets off it only while the host is inside a call to the queue's monitor method. Upstream's library never makes that call ([qualcomm/fastrpc#377](https://github.com/qualcomm/fastrpc/issues/377)), so a dspqueue client such as llama.cpp's Hexagon backend hangs at its first request. Reported so far: X1E80100 `CDSP.HT.2.9.c1-00078-HAMOA-1` (Surface Laptop 7, Galaxy Book4 Edge) and X2 Elite `CDSP.HT.3.3-00304`. With a DSP-side log enabled, the DSP says `Queue Monitor supported. Importing Queue ... requires packet_callback`.

This package carries two patches for it. They change nothing unless the client process has `DSPQUEUE_QUEUE_MONITOR` in its environment:

- `DSPQUEUE_QUEUE_MONITOR=2` (use this one): a pump thread per queue makes the monitor call, and at a normal exit the library cancels its pending DSP wait, so the kernel frees the process's DSP mappings.
- `DSPQUEUE_QUEUE_MONITOR=1`: the monitor call is made inside every `dspqueue_write`. It works but generation in llama.cpp is about 8x slower.

Do not interrupt a client (Ctrl-C, `kill -9`) while it has work on the DSP: the kernel driver keeps the interrupted call, and with it every buffer the process mapped, until the next reboot; later runs then fail with `failed to map buffer` in `journalctl -k`.

For llama.cpp's Hexagon backend on the Surface Laptop 7 (DSP v73) the environment is `DSPQUEUE_QUEUE_MONITOR=2 GGML_HEXAGON_ARCH=v73 GGML_HEXAGON_LIBHTP_DIR=<dir> ADSP_LIBRARY_PATH=<dir>`, where `<dir>` holds `libggml-htp-v73.so`, with `--device HTP0 -ngl 99`.

## adsprpcd_audiopd

Upstream's rule starts it with every ADSP. It asks the ADSP to create its static audio process in memory the kernel hands over, and on boards whose device tree does not protect that memory it resets the machine (qualcomm/fastrpc#414). Linux audio on Snapdragon laptops does not use that process, so here it only runs if started by hand.

## fastrpc-healthcheck

It reports a running DSP as `Offline` when the firmware file is compressed (`.mbn.xz`, as Omarchy's firmware packages install it): it looks for the uncompressed name the remoteproc requests. Check `/sys/class/remoteproc/*/state` instead.

## Licence

BSD-3-Clause.
