# microsoft-surface-laptop-7-support

Hardware support for the Microsoft Surface Laptop 7 with Snapdragon X Elite, 15" (`microsoft,romulus15`) and 13.8" (`microsoft,romulus13`), that no upstream package carries yet. Omarchy's Surface Laptop 7 hardware setup (`install/hardware/microsoft/surface-laptop-7.sh`) installs it.

The package contains no Microsoft or Qualcomm firmware; `microsoft-surface-laptop-7-firmware` carries that.

## Contents

- **Battery cycle count and identity** (`surface-laptop-7-battery`). Linux reads this laptop's battery through the Qualcomm battery service (`qcom_battmgr`), which has the charge limit but reports a placeholder pack: `QCOMMBATT01`, `Qualcomm`, made in 2014, 0 cycles. The capacity, charge and voltage it reports are right. The Surface controller (SAM) has the pack's own data, which is where Windows reads it, but the kernel leaves SAM's battery unregistered on this laptop, since two batteries make UPower report double. So the kernel's battery stays as it is, and a timer reads the missing part from SAM on the side:
  - `surface-laptop-7-battery-info.timer` runs `surface-laptop-7-battery-info` a minute after boot and once a day. It sends SAM one read-only request, the static-information read `surface_battery` uses on other Surfaces (category `0x02`, command `0x02`), through `surface_aggregator_cdev`, and writes the cycle count, capacities, maker and model to `/run/microsoft-surface-laptop-7-support/battery`. The serial number is left out. It sends nothing that sets or changes state.
  - `surface-laptop-7-battery` prints that with what Linux already has, and needs no root:

    ```
    Charge          66% (Discharging)
    Health          94% of design (59.78 of 63.83 Wh)
    Cycles          204
    Pack            SMP LION, model 1271364010
    Charge limit    start below 75%, stop at 80%
    ```

  UPower and the bar's battery tooltip still show 0 cycles, because they read the kernel. Fixing that there takes a change in both `qcom_battmgr` and the Surface drivers: a power-supply extension can't supply a property the battery already has.
- **Front camera as a webcam.** The front camera (OmniVision OV02C10) is a raw sensor that only libcamera can run, through its simple pipeline and software ISP. Apps that read only V4L2 cameras, such as Monologue and anything built on Qt Multimedia's FFmpeg backend, found no camera. As Omarchy's IPU7 camera does with icamerasrc, the package relays it to a regular V4L2 device:
  - `v4l2loopback` creates `/dev/video50`, "Front Camera" (`/usr/lib/modprobe.d/surface-laptop-7-camera.conf`).
  - `v4l2-relayd@surface-laptop-7`, enabled by the package, fills it from `libcamerasrc` while an app has it open. The pipeline is in `/etc/v4l2-relayd.d/surface-laptop-7.conf`. 1080p is scaled to 720p, which averages out much of the software ISP's noise, a 5-pixel median takes out the speckle left, and contrast 1.25 and saturation 1.4 make up for the untuned sensor's flat picture. Its drop-in runs it only on the two Surface Laptop 7 trees, and adds the DMA heap and udmabuf devices the software ISP allocates its buffers from, which the relay's sandbox doesn't list.
  - `/usr/share/libcamera/ipa/simple/ov02c10.yaml` gives the software ISP the sensor's black level (64 at 10 bits). Without it libcamera guessed one and the picture came out grey. It also runs an identity colour matrix, so the Saturation control takes effect.
  - Indoors, auto-exposure runs out of exposure (33 ms at 30 fps) and analogue gain (15.5x), and libcamera 0.7's simple pipeline neither lengthens frames nor uses the sensor's digital gain. So the picture stays dark. `surface-laptop-7-camera-gain` sets a fixed 2x digital gain before the relay starts; in bright light auto-exposure lowers the analogue gain to match.
  - On a 13.8", indoors: the darkest tenth of the picture went from 53 to 32 of 255 with the black level, and average brightness from 73 to 128 with the digital gain, at 18.8 fps throughout. The 15" has the same camera on the same bus and hasn't been tested.
- **Camera pickers**: a WirePlumber rule that leaves "Front Camera" as the only camera. It hides the monochrome infrared sensor (ST VD55G0, 15"), the front camera's own libcamera entry, which the relay owns, and the camera subsystem's 16 raw `qcom-camss` nodes (bus path `platform-acb7000.isp`), none of them a usable camera. The libcamera rules name the sensors by their device tree paths, so they do nothing on a tree without them.

The battery timer and its service check for the `microsoft,romulus15` device tree and do nothing elsewhere. The 13.8" model has the same controller and most likely the same placeholder battery data, but it hasn't been tested, so it isn't included.

## Retirement

- Battery: drop once the kernel's battery reports the pack's cycle count and identity.
- Camera relay: drop once the apps Omarchy ships read cameras through PipeWire or libcamera. Drop the digital gain once libcamera's simple pipeline uses it, or lengthens frames, and the tuning file once libcamera ships one for the OV02C10.
- Camera pickers: keep while the laptop's tree describes the infrared sensor, and while the relay owns the front camera.
