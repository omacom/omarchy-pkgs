# Experimental Latitude 7320 Detachable camera stack

This opt-in package assembles the front and rear camera stack tested on one
Dell Latitude 7320 Detachable running Linux 7.2.5-3-omarchy. It supplies:

- Five DKMS modules for TPS68470 board data, OVTI5678/OV5675, IPU bridge,
  OV8856, and DW9714. The front stream path owns the privacy indicator:
  capture fails if indicator enable/readback fails, and the indicator is
  cleared only after sensor standby or verified reset/power-down.
- A private libcamera v0.7.0 build under /opt/latitude7320-camera, with a CPU
  4x4 RGB-IR conversion, 10-bit statistics/LUT handling, bounded analogue
  gain, noise processing, rear lens lifetime handling, and GStreamer callback
  disconnection when capture stops. Distribution libcamera remains intact.
- Permanent named YUYV 1280x720/30 virtual feeds at video0/video1. The
  producer starts physical capture on loopback consumer STREAMON, releases
  the sensor when the final consumer stops, and clears idle frames to black.
- Service-only access to raw IPU6 nodes, capability refresh after the writers
  start, and a private PipeWire V4L2 enumerator with 128 slots. PipeWire 1.6.8
  otherwise consumes its 64 slots on raw nodes before discovering the feeds.
  Capture still uses the stock V4L2 plugin. WirePlumber pauses idle sources.
- Front/rear desktop launchers and contrast-based rear focus adjustment.

## Installation and activation

Build with makepkg, then install the resulting package and matching
linux-omarchy headers. This package is a draft, not a production recommendation.
Do not install it alongside the previous camera-dell7320/rear-camera-dell7320
DKMS packages: they replace the same modules. Migrate/remove that local setup
first. Any existing custom v4l2loopback numbering needs manual reconciliation.

Installing does not enable the camera service or change PAM/Howdy. To activate:

```
sudo latitude-camera-setup enable
sudo limine-mkinitcpio linux-omarchy
```

Reboot deliberately after checking DKMS built all five modules for the target
kernel. The PMIC and bridge probe once at boot; live hot-reloading is avoided.
The helper checks exact Dell DMI and refuses existing conflicting configuration.
The service runs as a dedicated unprivileged user. Raw IPU6 nodes are private
to that user's group; the two processed nodes retain desktop session access.
Do not add interactive users to latitude-camera.

Ordinary applications should offer Latitude Front Camera and Latitude Rear
Camera. Fully restart applications that cache discovery. Cam Stream needs
its loopback busy-check fix (tomdavenport/cam-stream#12). To use Howdy, point
its existing configuration at video0; enrollment and lock-screen/PAM policy
are intentionally separate and are not installed by this package.

## Colour and limitations

The profile has an analogue gain ceiling of 2 and automatic white balance.
The local test machine used lighting-specific fixed white-balance gains;
those personal calibration values are not shipped. Overrides belong in
/etc/latitude7320-camera/camera.env, for example RGBIR_WB_RED/RGBIR_WB_BLUE.
Default colours need evaluation under other lighting and on more units.
The tuning matrix is the tested conferencing profile, not a calibrated
laboratory colour reference. No raw-frame dumping is enabled.

This is downstream experimentation. The OVTI5678 sensor is presented through
OV5675 using a Bayer-labelled transport followed by explicit RGB-IR conversion;
upstream media maintainers have requested a dedicated driver and proper raw
format support. The bridge and software ISP changes are not a claim of an
accepted upstream design. Full kernel build, a clean package-install boot,
suspend/resume, multi-user camera access, and other kernel/PipeWire versions
still need testing. The enumerator code is from PipeWire 1.6.8 and should be
removed when upstream discovery handles this device count. No IR illuminator
or proximity sensor is enabled. Standard root/device-level bypass is outside
the sensor-stream privacy policy.

## Validation and rollback

makepkg check compiles all five modules against linux-omarchy headers, runs
the RGB-IR threading identity test, and checks Python/shell syntax. The
validation scripts in this directory exercise real V4L2/PipeWire feeds and
sensor runtime power states. check-howdy-demand.py requires an existing Howdy
installation; its use does not configure authentication.

The equivalent local stack passed independent and simultaneous front/rear
capture, reopening one camera while the other stays active, live PipeWire
capture from both named sources, normal-user denial of raw nodes, and Howdy
capture. Both sensors suspend when idle. This validates the local components;
it does not substitute for boot-testing this newly assembled package.

```
sudo latitude-camera-setup disable
sudo pacman -R latitude7320-camera
sudo limine-mkinitcpio linux-omarchy
```

Reboot to restore the stock modules; restart user WirePlumber to remove its
discovery override. Keep a known-good boot entry before testing. The removal
hook disables the service and removes its own activation links if still enabled.

## Provenance

libcamera base: b7854fd07d42168f099b5ce30d1702e0e0875bf5 (v0.7.0).
RGB-IR conversion: Sahan Nissanka's latitude-7320-camera project, with local
processing/lifecycle changes. Kernel source originals retain their authors
and SPDX headers; board data derives from Sahan Nissanka and Charles Drolet's
v2 submission, https://lore.kernel.org/platform-driver-x86/20260816070108.9308-1-adee.sahan@gmail.com/.
Related in-tree power/privacy proposal: omacom/omarchy-pkgs#787.
PipeWire enumerator/header: https://github.com/PipeWire/pipewire/tree/1.6.8/spa/plugins/v4l2;
MAX_DEVICES alone is changed from 64 to 128. System headers supply the SPA ABI.
Source material: https://github.com/githomeserver/latitude-7320-camera.
AI-assisted changes and packaging; original attributions are retained.
No personal images, biometric models, credentials, or host-specific paths
are part of this package.
