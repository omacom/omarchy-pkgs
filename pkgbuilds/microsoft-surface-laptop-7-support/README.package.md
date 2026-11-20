# microsoft-surface-laptop-7-support

Hardware support for the Microsoft Surface Laptop 7 15" with Snapdragon X Elite (`microsoft,romulus15`) that no upstream package carries yet. Omarchy's Surface Laptop 7 hardware setup (`install/hardware/microsoft/surface-laptop-7.sh`) installs it.

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
- **Cameras**: a WirePlumber rule that hides the monochrome infrared sensor (ST VD55G0) from camera pickers, so apps see only the front camera. It names the sensor by its device tree path, so it does nothing until the laptop's tree describes the sensor.

The timer and its service check for the `microsoft,romulus15` device tree and do nothing elsewhere. The 13.8" model (`microsoft,romulus13`) has the same controller and most likely the same placeholder battery data, but it hasn't been tested, so it isn't included.

## Retirement

- Battery: drop once the kernel's battery reports the pack's cycle count and identity.
- Cameras: keep while the laptop's tree describes the infrared sensor.
