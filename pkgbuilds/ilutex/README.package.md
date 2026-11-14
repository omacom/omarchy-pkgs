# ilutex

Backlight control for the AERO X16 keyboard (USB HID LampArray, `0414:8104`).

The keyboard is a LampArray device, so the colour is set through HID feature
reports rather than an LED class node. The CLI talks to `/dev/hidrawN` with
`ioctl` (`HIDIOCGFEATURE`/`HIDIOCSFEATURE`) and depends on nothing beyond libc:
no daemon, no udev helper, no crate.

## One writer

Every command that writes takes the same `flock` on
`/run/ilutex/writer.lock` before it touches the device, so two invocations —
or the window and an animation — can never interleave reports. The file comes
from `tmpfiles.d` (`0660 root:ilutex`, directory `0770`), and the binary
refuses to write if the directory or the file has any other shape. There is no
fallback to `/var/tmp`.

That is also why installing is not authorising. `sysusers.d` creates the
`ilutex` group and the package installs the udev rule that grants the session
user access to the node, but nothing adds anyone to the group. On a shared
machine, the account that installed the package is not silently handed the
keyboard:

```bash
sudo usermod -aG ilutex "$USER"
# then a new session, or: newgrp ilutex
```

## The window

`ilutex-gui` is a GTK4/libadwaita window (needs libadwaita 1.5 or newer) that
only ever runs the CLI as a subprocess: it never opens hidraw itself. It
follows the Omarchy accent from `~/.local/state/omarchy/current/theme/colors.toml`
and the Omarchy language from `~/.config/omarchy/language`, both watched live,
and offers `Ctrl+1…9`, `+`/`−`, `?` for the shortcut sheet, `Q` to leave and
Enter/Space to apply. The flags for the optional dependencies are the window's
and the tray indicator's (`libayatana-appindicator` + `python-cairo`).

## State

The colour and brightness live in `~/.local/state/ilutex/state`, written
atomically (a temporary file and a rename). The state written by the earlier
names of this package, `kbd-rgb` and `keybackcon`, is still read, so upgrading
does not lose the colour.

`ilutex.service` is a user unit that restores the saved colour at login;
`ilutex-animation@.service` runs an animation as a unit.

## Hardware

Only the AERO X16 is known to work. `ilutex info` reports what the descriptor
declares; `ilutex info --json` is the stable form the window reads. A keyboard
whose descriptor lacks the `LampArray` usage page (`0x59`) is not seen at all,
which is why more models need their firmware signature added rather than a
config change.
