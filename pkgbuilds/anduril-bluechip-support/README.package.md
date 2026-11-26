# anduril-bluechip-support

Hardware support for the Anduril BlueChip (Snapdragon X2 Elite / Glymur) not yet carried upstream:

- **Front camera as a V4L2 & PipeWire webcam (`Front Camera`, `/dev/video50`):** Relays the OmniVision OV08X40 RGB camera from `libcamera`'s simple pipeline and Adreno X2-90 GPU software ISP via `v4l2-relayd@bluechip` at 1080p NV12 (`30 fps`), and refreshes udev's V4L2 capability state so WirePlumber exposes it as a PipeWire `Video/Source` and `xdg-desktop-portal` camera.
- **Sensor tuning:** Ships `libcamera` simple IPA black-level tuning for `ov08x40` (64 at 10-bit).
- **WirePlumber picker cleanup:** Hides the raw OV08X40 `libcamera` entry owned by the relay and the 16 raw `qcom-camss` (`platform-acb6000.isp`) nodes.
- **DMA heap udev rule:** Grants the active desktop user `uaccess` on `/dev/dma_heap/system` for user-session `libcamera` software ISP buffers.
- **libcamera 0.7.2 relay guard (`bluechip-camera-guard`):** Restarts the relay on `libcamera 0.7.2` EGL/DMA-buf leaks or start deadlocks, and automatically stands down once `libcamera >= 0.8.0` is installed.
