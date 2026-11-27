# asus-zenbook-a16-support

Hardware support for the ASUS Zenbook A16 (UX3607OA, Snapdragon X2 Elite / Glymur) not yet carried upstream:

- **Front camera as a V4L2 webcam (`Front Camera`, `/dev/video50`):** Relays the OmniVision OV02C10 RGB camera from `libcamera`'s simple pipeline and Adreno X2-90 GPU software ISP via `v4l2-relayd@zenbook-a16` at native 1080p NV12 (`30 fps`), so V4L2-only apps (Monologue, Qt Multimedia, browsers) see a standard webcam.
- **Sensor tuning & indoor gain:** Ships `libcamera` simple IPA black-level tuning for `ov02c10` (64 at 10-bit + identity CCM) and `hm1092` (32 at 10-bit), and applies a 2x sensor `digital_gain` before relay startup for indoor headroom.
- **WirePlumber picker cleanup:** Hides the monochrome HM1092 IR camera, the raw OV02C10 `libcamera` entry owned by the relay, and the 16 raw `qcom-camss` (`platform-acb6000.isp`) nodes.
- **IR emitter defaults:** Keeps `ir:flash*` off at boot and grants `video` group write access.
- **libcamera 0.7.2 relay guard (`zenbook-a16-camera-guard`):** Restarts the relay on `libcamera 0.7.2` EGL/CMA buffer leaks or start deadlocks, and automatically stands down once `libcamera >= 0.8.0` is installed.
- **Active/idle power management (`90-asus-zenbook-a16-power.rules`):** Enables runtime PM autosuspend on Qualcomm USB controllers/PHYs and the internal Realtek SD card reader (`0bda:0329`, with 15 s empty-slot media polling; a newly inserted card can take up to 15 s to appear), disables `qcom-scmi-memlat` devfreq polling on kernels prior to `7.3.6-6`, and disables wakeup on the PCIe4 Wi-Fi root port (`0004:00:00.0`) and QCC2072 endpoint (`0004:01:00.0`) so `pci_pwrctrl` power-cycles `WL_EN` cleanly across CX collapse.
- **Deep sleep (`60-zenbook-a16.conf`, `zenbook-a16-sleep`):** Selects `MemorySleepMode=s2idle` and runs a DMI-guarded `systemd-sleep` hook that lets the WSA SoundWire controllers runtime-suspend across sleep, drops USB DWC3 wakeup, and soft-blocks Bluetooth while asleep so `s2idle` reaches full APSS, CXSD, AOSD and DDR collapse (~0.26 W) with working Wi-Fi, Bluetooth and speakers on resume.
