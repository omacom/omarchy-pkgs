# ct720-display-light

Userspace auto-brightness for the MacBook Air (M1, 2020) J313 panel.
The package installs a systemd unit and does not enable it.

## Sensor

There is one ambient-light sensor on t8103. The Asahi device tree node
`aop_als` in `t8103.dtsi` is that sensor. This daemon does not assume
`iio:device0`. It scans `/sys/bus/iio/devices/*/name` for `aop-sensors-als`
and reads that device's `in_illuminance_input`.

## What macOS documents, and what it does not

Jamf Nation's CoreBrightness plist thread shows auto-brightness stored as
nits: `BrightnessLevelNits` and an `AutoBrightnessCurve` dictionary in
`com.apple.CoreBrightness.plist`. The contents of that dictionary are not
documented. How macOS treats a manual brightness change is not documented
either. People report that auto resumes once the light changes. Nothing
public describes a learning algorithm, so learned points here are off
unless `--learn` is passed, and they are not saved.

## Curve

These anchors are guesses, not measurements and not Apple's curve:

| lux | nits |
| --- | --- |
| 0 | 8 |
| 5 | 30 |
| 20 | 70 |
| 50 | 110 |
| 150 | 170 |
| 400 | 250 |
| 1000 | 330 |
| 2500 and above | 394 |

Lux is smoothed for about 1.5 seconds. A change smaller than 10% in
log lux is ignored. Between positive anchors the curve is linear in
log lux. From 0 to 5 lux it is linear in lux, because log lux is not
defined at 0. The level is

`nits = clamp(curve(lux) * 2^offset_stops, min 3, max 394)`.

It never goes fully black. The minimum is 3 nits.

## Mapping onto the panel

`/sys/class/backlight/apple-panel-bl/brightness` is not linear nits.
linux-aurora #224 maps that sysfs level through CIE 1931 lightness into
nits (`dcp_perceptual_nits` / `dcp_level_from_nits`). #225 caps this
panel at 394 nits. This daemon uses that same integer map and
`max_brightness` from sysfs. It reads manual changes from
`actual_brightness`.

A level this daemon did not write, and not one written mid-ramp, sets

`offset_stops = log2(user_nits / curve(lux))`

and pauses automatic writes for about 3 seconds. The offset is stored in
`/var/lib/ct720-display-light/state` (`StateDirectory=ct720-display-light`),
at most every 30 seconds and on exit, by a temp file and rename.

The ramp from the current nits to the target takes 3.5 seconds.
Nothing is written while eDP DPMS is off or the lid is closed.

`--no-auto` holds the manual nits and does not follow the curve.
`--dry-run` does not write the panel or the state file.

## Follow-up for the keyboard lamp

`ct720-kbd-light` (omarchy-pkgs #1619) fades the keyboard when the panel
falls by more than 12% from its latched level. A slow automatic panel
change can eventually cross that line and dim the keys. That interaction
is not handled here. It needs a follow-up in #1619 so automatic panel
moves do not look like a user turning the display down.
