# anduril-bluechip-support

System plumbing for the Anduril BlueChip (Snapdragon X2 Elite / Glymur) front camera:

- **Loopback module options (`bluechip-camera.conf`):** Configures `v4l2loopback` (`video_nr=50`, `card_label="Front Camera"`, `exclusive_caps=1`) and pulls in `v4l2-relayd`, `v4l2loopback-dkms`, `v4l-utils`, and `gst-plugin-libcamera`.
- **DMA heap udev rule (`70-bluechip-camera.rules`):** Grants the active desktop user `uaccess` on `/dev/dma_heap/system` so `libcamera`'s software ISP and Omarchy's userland camera relay run without root.
- **WirePlumber picker cleanup (`50-bluechip-cameras.conf`):** Hides the raw OV08X40 `libcamera` entry owned by the relay and the 16 raw `qcom-camss` (`platform-acb6000.isp`) nodes.

The webcam relay, `libcamera` sensor tuning (`ov08x40.yaml`), and `gamma`/`contrast`/`saturation` defaults live in userland via `omarchy-camera-tuning` (`omacom/omarchy`), so tunings can be adjusted without rebuilding this package.
