# Dell Inspiron 14 Plus 7441 backlight

This temporary package enables display brightness control on the Snapdragon
Dell Inspiron 14 Plus 7441 (`x1e80100-dell-inspiron-14-plus-7441`).

The AUO B140QAX01.H panel advertises PWM brightness control in its DPCD
(`0x702 = 0x91`), so the kernel skips AUX brightness and registers
`dp_aux_backlight` with `max_brightness` 0. The stock device tree has no PWM
backlight node, which leaves the brightness keys and `brightnessctl` with
nothing to drive. Firmware already routes PMK8550 GPIO5 to `func3`; the missing
pieces are the PMK8550 PWM provider and a `pwm-backlight` attached to the eDP
panel.

The fix has been proposed upstream as
[an RFC on linux-arm-msm](https://ratatoskr.run/linux-devicetree/2026/09/17556186).
Until the Arch Linux ARM kernel ships it, this package applies the equivalent
device tree overlay:

- `pmk8550_pwm` enabled
- PMK8550 GPIO5 in `func3` as the backlight pinctrl state
- `pwm-backlight` on channel 0 with a 500000 ns (2 kHz) period, 101 linear
  levels, default level 80, powered by `vreg_edp_3p3`
- the eDP panel's `backlight` property pointing at it

The 2 kHz period matches the PMK8550 setup of the
`x1p42100-lenovo-thinkbook-16`. It has been tested on the panel for full-range
brightness without visible flicker, but the waveform has not been measured.

## How it works

`linux-aarch64` owns `/boot/dtbs/qcom/x1e80100-dell-inspiron-14-plus-7441.dtb`
and the UKI selects it from SMBIOS, so the overlay must be merged into that file
and re-merged whenever the kernel package replaces it.

`dell-inspiron-7441-backlight-apply`:

- saves the stock DTB to `/var/lib/dell-inspiron-7441-backlight/stock.dtb`
- writes the merged DTB atomically with `fdtoverlay` and records its checksum
- on later runs, re-merges from the saved stock copy when the DTB on disk is
  still the one it wrote, so package upgrades replace the overlay rather than
  stacking it
- leaves the DTB alone when the kernel already wires a panel backlight, so the
  package becomes a no-op once the upstream fix lands

`85-dell-inspiron-7441-backlight.hook` runs it after every install or upgrade
of that DTB, before `90-mkinitcpio-install` rebuilds the UKI. Installing or
upgrading this package runs it and rebuilds the boot images directly.

Because the DTB is modified in place, `pacman -Qkk linux-aarch64` reports it as
changed while this package is installed.

## Verification

After installing and rebooting:

```bash
brightnessctl -l
```

should list a `backlight` device with `Max brightness: 100`, and the brightness
keys should work across the full range.

## Removal

Once every kernel you intend to boot wires the panel backlight, remove the
workaround and reboot:

```bash
sudo pacman -Rns dell-inspiron-7441-backlight
systemctl reboot
```

Removing the package restores the saved stock DTB (only if the DTB on disk is
still the one it wrote) and rebuilds the boot images.
