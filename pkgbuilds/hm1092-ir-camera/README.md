# Himax HM1092 IR camera

This package makes the Windows Hello IR camera that Dell fits next to the IPU7
RGB camera usable for face authentication. It ships:

- the `hm1092` sensor driver as a DKMS module, taken from release 1.0.5 of
  [svp7500-camera-fix-pack](https://github.com/jibsta210/svp7500-camera-fix-pack)
- `hm1092-relay`, a service that converts the sensor's 10-bit stream to 8-bit
  grey on `/dev/video-hm1092-ir` and drives the IR flood LED while something
  reads it
- a udev rule that keeps that device root's alone
- a WirePlumber rule that hides it from PipeWire

Face authentication itself, Howdy and its PAM, lock screen and polkit
integration, is not part of this package.

## Support matrix

### Machines

A machine has the sensor when `/sys/bus/acpi/devices/HIMX1092:00` exists. The
units do not start without it.

| Machine | Platform | Status | Notes |
|---|---|---|---|
| Dell XPS 14 DA14260 | Panther Lake | Verified | Sensor on CSI-2 port 2, one lane. Streams, Howdy matches, the RGB camera keeps working next to it. |
| Dell XPS 16 DA16260 | Panther Lake | Expected | The fix pack's author streams the sensor and unlocks with Howdy on this model, with their own build. Not run with this package. |
| Dell Pro 14 PB14250 | Lunar Lake, as reported | Untested | Fix pack reports put the sensor on CSI-2 port 1; the relay follows the media graph, so the port is no obstacle. Reported with an OV05C10 RGB sensor, which `intel-ipu7-camera` does not support. |
| Dell XPS 13 9350 | Lunar Lake | Unknown | No evidence that it carries an HM1092. Its RGB sensor is an OV02C10, which `intel-ipu7-camera` does not support. |
| Dell XPS 13 DX13260 | Panther Lake | Unknown | No evidence yet that it carries an HM1092. |
| Meteor Lake and Arrow Lake machines | IPU6 | Unsupported | `intel-ipu7-camera` builds only for IPU7 (Lunar Lake) and IPU7.5 (Panther Lake). |

### Software

| Component | Requirement | Verified with | Notes |
|---|---|---|---|
| `linux-omarchy-bore`, `-eevdf`, `-muqss` | 7.2.8-2 or later | 7.2.8-8 bore | These carry the sensor's ipu-bridge entry in `0543-media-laptop-cameras.patch`. eevdf and muqss carry the same patch but have not run the camera. |
| Mainline Linux | 7.3 or later | | ipu-bridge lists the sensor from 7.3 on. |
| Arch `linux` and `linux-lts` before 7.3, older `linux-omarchy` | Unsupported | | Without the ipu-bridge entry the sensor never binds. |
| `intel-ipu7-camera` | Required | 1.0.6-3 | Takes camera ownership through `intel_cvs`; the sensor module loads only after its `camera-init`. |
| `v4l2loopback-dkms` | Required | 0.15.4 | The relay learns when a reader starts and stops from its client usage events. |
| Architecture | `x86_64` | | The hardware exists only on Intel. |

### What the camera offers

| | Sensor and driver | `/dev/video-hm1092-ir` |
|---|---|---|
| Resolution | 648×368: the 1280×720 array binned 2×2, plus overscan. Dell's Windows driver also knows 1296×736, but production firmware streams only 648×368, and the driver exposes only that. | 648×368 |
| Frame rate | 30 fps. Windows also knows 648×368 at 60 fps; the driver does not expose it. | Every frame the sensor delivers |
| Samples | 10-bit mono in 16-bit containers, labelled SGRBG10 | 8-bit GREY. Each reader session is scaled so the brightest unsaturated 1 % lands near 235; `FIXED_SCALE=1` drops the two low bits instead. |
| Access | Root, on the IPU7 ISYS capture node, after the media graph is linked | Root only, one reader at a time |
| IR flood LED | A separate LED class device that the INT3472 driver registers; the sensor driver cannot drive it | Lit while a reader streams, within the limits below |

## Known limitations

### Hardware and kernel

- Only the XPS 14 DA14260 has run this package.
- The package does not block kernels without the ipu-bridge entry; the release
  channel keeps them apart. On such a kernel the relay fails at boot with "the
  media graph has no complete hm1092 -> csi2 -> capture path".
- A driver for the HM1092 is under review on linux-media. Once a kernel ships
  it, the DKMS module still takes precedence, and the relay does not yet accept
  that driver's Y10 format.
- DKMS builds the module unsigned. It loads only where module signatures are
  not enforced, and taints the kernel.

### Image

- 648×368 at 30 fps is the only mode.
- The device carries 8 bits. When the brightest 1 % of the scene sits above
  about 235 of 1023, neighbouring 10-bit values merge, up to the two low bits.
- Frames are not measurements: the scale changes between sessions and while
  the first frames of a session settle.
- The 10-bit samples exist only on the ISYS capture node, which the relay holds
  while it streams. A second raw reader has to share the node and the LED with
  the relay.

### Readers

Howdy 2.6.1, which reads through OpenCV, and `ffmpeg` have read the device on
the XPS 14.

- Only root can open the device. A session process that could open it could
  watch the IR camera, or, while the relay restarts, take the producer side
  and feed authentication its own frames.
- One reader at a time. While one streams, a second gets `EBUSY`.
- PipeWire does not offer the device, so browsers and video calls cannot use
  it.
- OpenCV must open it by `/dev/video-hm1092-ir`. That name makes OpenCV hand
  the path to FFmpeg; OpenCV's own V4L2 reader fails on the loopback's buffers.
- A new reader first gets the black frame the previous session left behind,
  with that session's timestamp. Tools that cut by stream time stop at once
  unless they stamp frames with the wall clock, for example
  `ffmpeg -use_wallclock_as_timestamps 1`.

### IR flood LED

The LED emits invisible near-infrared, so the blink reflex gives no
protection. `/etc/hm1092-ir-camera.conf` sets its limits:

- A reader gets light for at most 8 s (`MAX_ILLUMINATION_MS`) from when the LED
  first lights for it. After that it gets black frames, five a second, until it
  lets go of the device. A reader with a longer timeout fails on dark frames;
  Howdy's default timeout is 4 s.
- Across readers, the LED is lit for at most 50 % (`DUTY_FRACTION`) of any
  60 s window (`DUTY_WINDOW_S`).
- The relay refuses to start on a value that would void either limit.
- Every frame is lit. There are no frames with the LED off, so readers cannot
  subtract ambient light or compare lit and unlit frames against spoofing, as
  Windows Hello does.

### Lifecycle

- Before suspend, the sleep hook stops the relay and turns the LED off; after
  resume it starts the relay again, and the next reader gets light as usual.
- An upgrade neither restarts the relay nor reloads the module. Reboot after
  upgrading.
- After removal the loopback device stays until the next reboot.

## Checking a machine

```bash
ls /sys/bus/acpi/devices | grep HIMX1092
sudo /usr/lib/hm1092-ir-camera/hm1092-relay --probe
journalctl -b -u hm1092-relay
```

`--probe` prints the media device, the sensor, its CSI-2 receiver, the capture
node, the loopback and the flood LED it finds. It fails when the path from the
sensor to a capture node or the LED is missing.
