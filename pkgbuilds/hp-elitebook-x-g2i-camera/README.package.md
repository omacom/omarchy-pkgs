# HP EliteBook X G2i webcam

OmniVision **OV05C10** sensor on an Intel **IPU7** ISP. This package makes the
camera work in Chrome, Firefox, OBS and the Omarchy screen recorder.

## 2.0.0: two engines, hardware ISP by default

Since 2.0.0 the daemon has two frame engines behind one unchanged contract
(permanent `/dev/video50` writer, black frames while idle, LED only while an
app uses the camera):

- **camhal** (default): Intel's hardware ISP through the pinned runtime in
  `/usr/lib/hp-elitebook-x-g2i-camhal` (release set `20260327_1`, the pairing
  intel/ipu7-camera-hal issue #48 reports working — newer tags are the broken
  ones, see "Why CamHAL is not used" below for the history). Proper AIQ
  processing with HP's tuning, near-zero CPU. Two consecutive failures switch
  the boot to softisp, loudly, recorded in
  `/run/hp-elitebook-x-g2i-camera.camhal-fallback`.
- **softisp**: the 1.x libcamera SoftISP path described by the rest of this
  README, kept unchanged as the fallback.

Knobs live in `/etc/hp-elitebook-x-g2i-camera.conf`: `HPCAM_ENGINE=camhal|softisp`,
`HPCAM_NR_STRENGTH` (ISP noise reduction, shipped at -120), and the 1.x tuning
variables. A local AIQ tuning file at
`/etc/hp-elitebook-x-g2i/OV05C10_CJFPE50_PTL.aiqb` overrides the packaged one
at the next sensor start.

Since 2.0.2 the camhal pipeline can add a GPU temporal denoise stage:
`HPCAM_DENOISE` (default 8, range 0-64) inserts
`vapostproc denoise=N` — the Intel GPU's VEBOX motion-adaptive temporal
filter, from the system gst-plugin-va, near-zero CPU — between icamerasrc and
the frame pipe. It targets the residual noise the ISP leaves: temporally
white 4-16px blobs, which within-frame NR cannot remove. `HPCAM_DENOISE=0`
removes the element and the pipeline is byte-identical to 2.0.1. Two optional
AE clamps, `HPCAM_EXPOSURE_RANGE` and `HPCAM_GAIN_RANGE` (`min~max`, passed
to icamerasrc verbatim), can widen the exposure ceiling so AE stops riding
12.5-15.5x analog gain at the 33ms/30fps pin; longer exposure trades fps and
motion blur for noise. All three are documented in the conf file.

Everything below this line is the 1.x record. It stays because the softisp
engine is still exactly that code, and because the diagnosis explains why the
CamHAL runtime must stay pinned.

**The softisp engine is a bypass of Intel's CamHAL, not a fix.** Read
"Trade-offs" before assuming it behaves like a normal webcam stack.

## Why CamHAL is not used

Observed with `cameraDebug=0xFF` on `v4l2-relayd`:

```
GraphConfig: <out w="2944" h="1632">
PlatformData: Isp raw crop [0, 88, -56, 88], wxh [2944 x 1632]
```

psys is **not** broken — it processes frames happily (`frame id N is done`) and
the output is uniformly black.

**The cause is not established.** That log line reads like a readout mismatch and
is not one. The four numbers are edge *insets*, not a rectangle: a right inset of
-56 means "read 56 columns past the sensor width", giving 2888 + 56 = 2944 and
1808 - 88 - 88 = 1632. Nothing is negative-sized, and the HAL performs no
arithmetic here — `GraphConfig::getIspRawCropInfo` copies the value verbatim out
of the static graph.

Every sensor Intel ships uses the same idiom, including ones that work:

| Sensor | Input | Right inset | Output |
|---|---|---|---|
| OV08X40 | 3856 | -48 | 3904 |
| IMX471 | 1928 | -57 | 1984 |
| OV13B10 | 4208 | -16 | 4224 |
| OV05C10 | 2888 | -56 | 2944 |

The rule is always `out = ALIGN(in, 64)`. HP's Windows graph settings contain the
identical record for this sensor. Both Intel's and HP's binaries declare exactly
one sensor geometry, 2888x1808 — neither contains a 2944-wide mode.

Tested August 2026 against `intel-ipu7-camera-hal-git` r84, whose graph binary is
byte-identical to current upstream. Not retested since. CamHAL is an open problem
on this machine, not a proven dead end, and Intel issues #48, #52, #70 and #71
covering IPU7 black frames are all open and unanswered.

## The route out of this: libcamera, not CamHAL

CamHAL is not the only way to reach the ISP. libcamera 0.7.2's `simple` pipeline
handler already lists `intel-ipu7`, and it drives this sensor end to end today.
Tested on this machine, streaming to a v4l2loopback sink the same way this
package does:

| | this package (ffmpeg) | libcamera `simple` |
|---|---|---|
| CPU | 437% (4.4 cores) | 79.8% (0.8 cores) |
| Debayer | libswscale, CPU | GPU via EGL, 6.7 ms/frame |

Two things are needed and neither is in the tree yet:

1. **A `CameraSensorHelper` for `ov05c10`.** Without one libcamera logs
   `Failed to create camera sensor helper for ov05c10` and AGC runs on a default
   gain model, so exposure hunts and settles wrong. The sensor's real model is
   linear, `V4L2_CID_ANALOGUE_GAIN` in 1/16 steps —
   `AnalogueGainLinear{ 1, 0, 0, 16 }` — which turns libcamera's reported range
   from `gain 16-248 (1)` into `gain 1-15.5 (0.145)`. This belongs upstream in
   libcamera, not here.
2. **Idle handling.** Everything under "Two coupled requirements" below still
   applies. A libcamera version of this daemon has to hold the loopback open,
   feed black frames when nothing is reading, and switch source on a frame
   boundary. That is most of the code in this package and none of it is
   libcamera's problem to solve.

Two constraints found while testing, recorded so they are not rediscovered:

- **Request the native mode.** Ask for 1920x1080 and libcamera selects sensor
  mode 2800x1576, which never delivers a buffer and wedges the ISYS node.
  2888x1808 works; scale afterwards.
- **`blackLevel: 4096` is correct.** Measured, not assumed: at minimum exposure
  and minimum analogue gain the median is exactly 64 in all four Bayer channels
  and 64 << 6 = 4096. There is no per-channel pedestal.

## What this package does instead

```
ov05c10 -> CSI2 -> ISYS (raw Bayer) -> debayer + AE + WB -> v4l2loopback
```

The kernel path underneath is healthy — raw capture from `/dev/video0` yields
real images on demand. Only psys/CamHAL is skipped.

## Trade-offs

- **No HP ISP tuning.** Colour, denoise and sharpening come from a plain
  debayer, not Intel's AIQ with HP's `.aiqb`. Noticeably softer and noisier,
  most visible in low light.
- **Simple 3A.** Auto-exposure is a proportional loop over exposure, then
  analogue gain, then digital gain. White balance is static gray-world gains
  (`WB_R`/`WB_B`) because this sensor exposes no
  `V4L2_CID_RED_BALANCE`/`BLUE_BALANCE`.
- **Continuous CPU cost.** One ffmpeg runs whenever the service is up.
- **The service must stay enabled.** See below.

## Two coupled requirements

**1. `exclusive_caps=1` + a permanent writer.** Chrome only enumerates V4L2
devices advertising CAPTURE without OUTPUT. With `exclusive_caps=0` the loopback
reports `Capture+Output` and Chrome omits the camera entirely — while Firefox and
OBS work fine, which makes this confusing to diagnose. `exclusive_caps=1` reports
capture-only *while a writer is attached*, so the service holds `/dev/video50`
open permanently. Disabling the service without reverting
`/usr/lib/modprobe.d/99-hp-elitebook-x-g2i-v4l2loopback.conf` leaves every reader
failing with `VIDIOC_STREAMON: Input/output error`.

**2. Frame-aligned source switching.** The privacy LED follows the *sensor*, so
the sensor is powered down when nothing is using the camera. To keep a writer
attached anyway, one persistent ffmpeg reads NV12 from a FIFO whose *source*
switches between black frames and the sensor. Because that FIFO carries raw
frames with no boundary markers, a feeder killed mid-frame desyncs the stream
permanently — every later frame splits across two, showing as a torn image with
green/magenta bands (Y and UV misaligned). Both switch directions therefore stop
on a frame boundary: the idle feeder exits on a flag checked between whole
frames, and the sensor feeder gets SIGTERM plus a bounded wait.

## Behaviour

- Privacy LED lights only while an application is using the camera.
- Device appears as **Hardware ISP Camera**, `/dev/video50`, NV12 1920x1080@30.
- An app opening the camera sees black for 1–2s while the sensor spins up.

## Kernel modules

Three pieces are needed and they come from three different places, because
only one of them is genuinely out of tree:

| Piece | Where it comes from | Why there |
|---|---|---|
| `intel_ipu7`, `intel_ipu7_isys`, `ipu_acpi*`, `intel_cvs` | `intel-ipu7-drivers` | The IPU7 has no mainline driver at all. Shared with `intel-ipu7-camera`. |
| `ov05c10` sensor driver | this package, as DKMS | Intel's driver from `intel/ipu6-drivers`, taken unmodified at a pinned commit. It exists in neither mainline nor `intel-ipu7-camera`, so it overrides nothing. |
| `OVTI05C1` link frequencies, 480 MHz to 480 + 900 MHz | `linux-ptl`, patch `0032` | `ipu-bridge` is an in-tree file. A DKMS module rebuilding it would fork it and freeze every other sensor's entry in the table. The patch is Intel's own, carried verbatim. Without it, probing fails with `no link frequency 900000000 supported`. |

The daemon discovers the media device, sensor subdev, CSI-2 receiver and
capture node from the live graph rather than assuming `/dev/media0`,
`/dev/v4l-subdev4` and `/dev/video0`. Those numbers are enumeration artifacts,
and a kernel that probes in a different order renames all of them while the
topology stays the same.

**Never `rmmod`/`insmod` the `intel_ipu7*` stack on a running system** —
unloading `intel_ipu7_psys` while active hard-hangs the machine with no panic
logged. File-based install plus reboot only.

## Tuning

Environment variables in the unit: `AE_TARGET` (default 105), `WB_R` (1.50),
`WB_B` (1.25), `IDLE_STOP` (5s), `OUT_W`/`OUT_H` (1920x1080).
