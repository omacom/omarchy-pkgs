# iptsd

Userspace touch and pen processing for Microsoft Surface digitizers, built from pinned upstream `linux-surface/iptsd` against Arch Linux libraries. Arch Linux ARM does not package it, and the AUR carries only an unmaintained `iptsd-git`.

On the Surface Pro 11 (Snapdragon X Elite), the HID-over-SPI digitizer delivers touch through the kernel, but the pen only works once iptsd processes the raw digitizer reports into its virtual stylus and touchscreen devices. It is installed by Omarchy's `install/hardware/microsoft/surface-pro-11.sh`.

Upstream's udev rule runs `iptsd-check-device` on every hidraw device and starts `iptsd@<device>.service` only for supported Surface digitizers. The package is aarch64-only: Intel Surfaces get iptsd from the linux-surface repository, and publishing it for x86_64 here would collide with that package.

The packaged udev rule also runs on "change" events. Upstream's runs only on "add", so the udev reload pacman performs whenever a package ships udev rules stopped iptsd until the next boot (linux-surface/iptsd issue 163).

On the Surface Laptop 7 15" (Snapdragon X Elite), the touchpad needs iptsd for two-finger scroll, pinch and two-finger tap. It resets during resume and comes back in its mouse mode, and a running iptsd doesn't notice, so `iptsd-romulus15-resume.service` restarts iptsd after a suspend. It does nothing on any other machine.

On some boots of the same laptop the pad stops answering for a few seconds just as its HID device is re-bound to hid-multitouch. iptsd's udev rule then finds it silent and never starts iptsd, so the pad stays in its mouse mode until the rule runs again. `iptsd-romulus15-boot.service` checks twice a second whether iptsd runs for the touchpad once the pad is on hid-multitouch, and re-runs the rule every two seconds until it does, for up to a minute. Seen on 3 of 7 boots on one laptop. It runs beside the boot rather than ahead of `multi-user.target`: as a oneshot it held that target and `graphical.target` for 15 s on a 13.8". It does nothing on any other machine.

The Surface Laptop 7 13.8" (`microsoft,romulus13`) has the same touchpad (`045E:0C77`) on the same bus, and a touchscreen (`045E:0C6E`) wired like the 15"'s. On resume both log "Spontaneous FW reset!" and come back in their mouse mode, as on the 15", so both helpers run on it too, despite their names.

That touchpad has no moving parts: it measures force and reports its click in a report (type `0x96`) upstream iptsd does not read, so pressing it did nothing. `0001-ipts-Handle-the-button-report-of-force-touchpads.patch` reads it, which brings back press to click, press and drag, and two-finger press for a right click. Sent upstream as linux-surface/iptsd#237; drop the patch when the pinned commit includes it.

Its touchscreen took light taps for drags: the reported position of a tap shifts by up to 2 mm while the finger lands, about as far as applications allow before a touch becomes a drag. `0002-contacts-Add-a-position-slop-for-new-contacts.patch` adds a `PositionSlop` option that keeps a new contact where it first appeared until it has moved that far, and `surface-laptop-7-15.conf`, installed to `/usr/share/iptsd`, sets it to 2.5 mm for that touchscreen only (HID `045E:0C6F`). `surface-laptop-7-13.conf` does the same for the 13.8" touchscreen (HID `045E:0C6E`), which iptsd also drives and whose screen size it reads from the device. Written from the 15"'s evidence and the same digitizer family, not yet confirmed with a finger on the 13.8". No other device is affected. Upstream has no tests, so `check()` runs `test-position-slop.cpp` against the patched stabilizer. Sent upstream as linux-surface/iptsd#238; drop the patch and the test when the pinned commit includes it.

The touchpad (`045E:0C77`, both sizes) stuttered and then jumped on fast swipes. iptsd marks a contact unstable, and skips its frame, when its orientation changes by more than `OrientationThresholdMax` (15 degrees) between frames. A fingertip on this pad is nearly round, so its orientation flips between 0 (aspect below 1.1) and about 110 degrees, and in a fast swipe a frame was dropped and the next one moved twice as far, which pointer acceleration then threw further. `surface-laptop-7-touchpad.conf`, installed to `/usr/share/iptsd`, raises that threshold to 180 for this touchpad only, since the pointer doesn't use orientation. On a 13.8", held frames inside fast motion went from 27 in 1656 to 2 in 643.

## Retirement

Drop once Arch Linux ARM packages iptsd, or once the Surface Pro 11's pen and the Surface Laptop 7's touchpad work through the kernel alone.
