# Espanso on Wayland

Builds Espanso from its release source for x86-64 and ARM64, including native
search and forms (`modulo`). This is the Wayland variant; use an X11 build
instead on an X11 desktop.

After installation, register and start the service as the desktop user:

```sh
espanso service register
espanso start
```

The Omarchy Espanso plugin can also perform service registration. This package
provides `/usr/bin/espanso`; it does not install the plugin or personal matches.

## Input permissions

The install hook applies upstream's `cap_dac_override+p` to the root-owned
executable, reapplying it on upgrades. Espanso raises this capability while
opening evdev/uinput devices, then drops it. This grants access to keyboard
input and virtual input devices; install only if that access is acceptable.

## Carried patches

- `0001-hyprland-keyboard-layout.patch`: reads the main keyboard's active layout,
  variant, and options from `hyprctl -j devices`. The existing watcher updates
  the worker after layout changes. Explicit Espanso keyboard settings take
  precedence; other compositors retain upstream detection.
- `0002-query-evdev-modifiers.patch`: obtains held modifiers and lock LEDs from
  already-open input devices with EVIOCGKEY/EVIOCGLED. It replaces the visible
  RGB Wayland sync window, which can block worker startup while awaiting focus.

Both patches are local downstream fixes, not yet merged upstream. Reevaluate
and remove them when an upstream release includes equivalent fixes. The ioctl
encoding used here targets Linux x86-64 and ARM64, the architectures built by
this recipe.

Upstream tag v2.4.1 still declares binary version 2.4.0 in Cargo.toml.
