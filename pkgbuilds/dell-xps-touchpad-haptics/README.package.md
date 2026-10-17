# dell-xps-touchpad-haptics

This package installs the Dell XPS Synaptics haptic touchpad daemon, its
systemd service, and a small CLI for switching between Omarchy's preset haptic
levels.

What it installs:

- `/usr/bin/dell-xps-touchpad-haptics`
- `/usr/bin/dell-xps-touchpad-haptics-daemon`
- `/usr/lib/systemd/system/dell-xps-touchpad-haptics.service`
- `/usr/lib/udev/rules.d/99-dell-xps-touchpad-haptics.rules`

What the pacman install hook does:

- picks a desktop user and writes `/etc/dell-xps-touchpad-haptics.env`
- creates `~/.config/omarchy/dell-haptic.conf` if needed
- enables the service and restarts it when a running systemd manager is available

Usage:

```bash
dell-xps-touchpad-haptics get
dell-xps-touchpad-haptics set low
dell-xps-touchpad-haptics set mid
dell-xps-touchpad-haptics set high
```

Preset levels:

- `low` = `10`
- `mid` = `50`
- `high` = `100`

Debugging:

- level changes are logged by the service when it notices the config change and
  attempts HID gain readback
- set `DELL_XPS_TOUCHPAD_HAPTICS_DEBUG=1` in `/etc/dell-xps-touchpad-haptics.env`
  to log each press and release report to `journalctl -u dell-xps-touchpad-haptics.service`
