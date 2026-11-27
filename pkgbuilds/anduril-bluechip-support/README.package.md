# anduril-bluechip-support

System plumbing for the Anduril BlueChip (Snapdragon X2 Elite / Glymur, board NY4P9):

- **Loopback module options (`bluechip-camera.conf`):** Configures `v4l2loopback` (`video_nr=50`, `card_label="Front Camera"`, `exclusive_caps=1`) and pulls in `v4l2-relayd`, `v4l2loopback-dkms`, `v4l-utils`, and `gst-plugin-libcamera`.
- **DMA heap udev rule (`70-bluechip-camera.rules`):** Grants the active desktop user `uaccess` on `/dev/dma_heap/system` so `libcamera`'s software ISP and Omarchy's userland camera relay run without root.
- **WirePlumber picker cleanup (`50-bluechip-cameras.conf`):** Hides the raw OV08X40 `libcamera` entry owned by the relay and the 16 raw `qcom-camss` (`platform-acb6000.isp`) nodes.
- **Active/idle power management (`90-anduril-bluechip-power.rules`):** Enables runtime PM autosuspend on Qualcomm USB controllers/PHYs (turning off 6 unused USB/PHY GDSCs) and disables wakeup on the PCIe4 Wi-Fi root port (`0004:00:00.0`) and WCN7850 endpoint (`0004:01:00.0`) so `pci_pwrctrl` power-cycles `WL_EN` cleanly across CX collapse.
- **Deep sleep (`60-bluechip.conf`, `bluechip-sleep`):** Selects `MemorySleepMode=s2idle` and runs a device-tree-guarded `systemd-sleep` hook that drops USB DWC3 wakeup (`a{2,4,6,8}00000.usb`) and soft-blocks only unblocked Bluetooth adapters while asleep so `s2idle` drops `bi_tcxo` and reaches full APSS, CXSD, AOSD and DDR collapse with working Wi-Fi and Bluetooth on resume.

The webcam relay, `libcamera` sensor tuning (`ov08x40.yaml`), and `gamma`/`contrast`/`saturation` defaults live in userland via `omarchy-camera-tuning` (`omacom/omarchy`), so tunings can be adjusted without rebuilding this package.
