# Test plan: hp-elitebook-x-g2i-camera 2.0.0 (CamHAL engine)

Scope: first install of the v2 pair on this machine. Everything here is
root-gated and reversible. Do not run any step while a call is in progress.

Safety rule carried over from every CamHAL session: **never rmmod/modprobe
`intel_ipu7*` or `ov05c10` to recover**. If the stack wedges, reboot. Each
wedged start leaves residue; do not loop failing starts.

## 0. Preconditions

- Artifacts, built 2026-08-30:
  - `pkgbuilds/hp-elitebook-x-g2i-camhal-runtime/hp-elitebook-x-g2i-camhal-runtime-20260327_1-1-x86_64.pkg.tar.zst`
  - `pkgbuilds/hp-elitebook-x-g2i-camera/hp-elitebook-x-g2i-camera-2.0.0-1-x86_64.pkg.tar.zst`
  - Rollback: `pkgbuilds/hp-elitebook-x-g2i-camera/hp-elitebook-x-g2i-camera-1.2.0-1-x86_64.pkg.tar.zst` (keep on disk before starting)
- `systemctl is-active hp-elitebook-x-g2i-camera` is `active` (the 1.2.0
  daemon), camera works in one app. If not, fix that first; v2 conclusions
  mean nothing on a broken baseline.

## 1. Install order

The camera package depends on the runtime, so:

```
sudo pacman -U pkgbuilds/hp-elitebook-x-g2i-camhal-runtime/hp-elitebook-x-g2i-camhal-runtime-20260327_1-1-x86_64.pkg.tar.zst
sudo pacman -U pkgbuilds/hp-elitebook-x-g2i-camera/hp-elitebook-x-g2i-camera-2.0.0-1-x86_64.pkg.tar.zst
```

No reboot needed for the upgrade itself (the DKMS module, modprobe drop-ins
and udev rules are unchanged from 1.2.0); post_upgrade try-restarts the
service. Verify the restart happened:

```
journalctl -u hp-elitebook-x-g2i-camera -b --since -5min
```

## 2. Engine selection

Expected journal lines from the fresh start:

```
engine: camhal (runtime /usr/lib/hp-elitebook-x-g2i-camhal, sensor ov05c10-uf), softisp fallback armed
ready — writer attached to /dev/video50 (capture-only advertised), sensor off
```

Then open the camera (Chrome, or `ffplay /dev/video50`), and expect:

```
consumer present — camhal engine started (pid N): icamerasrc device-name=ov05c10-uf ! video/x-raw,format=NV12,width=1920,height=1080 ! fdsink fd=3 (sensor on, LED on), nr_strength=-60
```

Checks, all live:

- Picture is the hardware ISP: visibly cleaner than 1.2.0 in a dim room.
- `cat /run/hp-elitebook-x-g2i-camera/status` shows `engine=camhal`,
  `engine_fallback=no`, `camhal_failures=0`, `fps=` near 30.
- LED on while the app is open.
- Close the app; within ~5 s (IDLE_STOP):
  `no consumers for 5s — camhal engine stopped, sensor off (LED off), feeding black`
  and the LED is off. This is the same idle contract as 1.x.
- Reopen the app: engine starts again, first frame within ~2 s.
- Second consumer while active (e.g. OBS + Chrome) still works: the loopback
  fans out, the engine does not restart.

## 3. Fallback verification (break the runtime path)

Two layers to verify: the missing-runtime guard and the two-strikes fallback.

Missing runtime (cheap, no wedge risk):

```
sudo mv /usr/lib/hp-elitebook-x-g2i-camhal/lib/gstreamer-1.0/libgsticamerasrc.so{,.off}
sudo systemctl restart hp-elitebook-x-g2i-camera
journalctl -u hp-elitebook-x-g2i-camera -b --since -1min
```

Expect:

```
camhal runtime incomplete (/usr/lib/hp-elitebook-x-g2i-camhal/lib/gstreamer-1.0/libgsticamerasrc.so missing) — is hp-elitebook-x-g2i-camhal-runtime installed? Using the SoftISP engine.
```

Open the camera: it must work (softisp path), status file shows
`engine=softisp`. Restore:

```
sudo mv /usr/lib/hp-elitebook-x-g2i-camhal/lib/gstreamer-1.0/libgsticamerasrc.so{.off,}
sudo systemctl restart hp-elitebook-x-g2i-camera
```

Two-strikes runtime fallback (engine starts but cannot deliver). Break the
config dir so icamerasrc starts and dies:

```
sudo mv /usr/lib/hp-elitebook-x-g2i-camhal/etc/camera/ipu75xa/gcss{,.off}
sudo systemctl restart hp-elitebook-x-g2i-camera
```

Open the camera and watch the journal. Expected sequence (timing: one attempt,
~10 s CAMHAL_START_TIMEOUT or an immediate subprocess exit, one retry after
backoff, then):

```
camhal engine failure 1 (fallback at 2): ...
camhal engine failure 2 (fallback at 2): ...
ENGINE FALLBACK: CamHAL failed twice in a row — using the SoftISP engine for the rest of this boot. Re-arm: rm /run/hp-elitebook-x-g2i-camera.camhal-fallback and restart the service, or set HPCAM_ENGINE=camhal.
```

Then the same consumer must get softisp frames without reopening the app
being required more than once. Status file: `engine=softisp-fallback`,
`engine_fallback=yes`. Confirm the flag survives a service restart (systemd
Restart cycle must not re-wedge CamHAL):

```
sudo systemctl restart hp-elitebook-x-g2i-camera
journalctl -u hp-elitebook-x-g2i-camera -b --since -1min | grep fallback
```

Expect `camhal fallback flag ... present — starting on the SoftISP engine`.
Restore and re-arm:

```
sudo mv /usr/lib/hp-elitebook-x-g2i-camhal/etc/camera/ipu75xa/gcss{.off,}
sudo rm /run/hp-elitebook-x-g2i-camera.camhal-fallback
sudo systemctl restart hp-elitebook-x-g2i-camera
```

Verify camhal is back (section 2 lines reappear). If this test wedged the
IPU7 (SOF timeouts in the journal, no frames on either engine), reboot before
drawing conclusions.

## 4. AIQB override verification

The packaged tuning is the stock HAL-repo `OV05C10_CJFPE50_PTL.aiqb`
(779,910 bytes). The Windows-extracted tuning (1,099,805 bytes, measures
better NR) is deliberately NOT packaged — provenance/licensing — and is
dropped in locally:

```
sudo cp /home/mdick85/Projects/hp-elitebook-x-g2i/extracted-windows/camera-ov05c10/ov05c10_CJFPE50_PTL.aiqb \
        /etc/hp-elitebook-x-g2i/OV05C10_CJFPE50_PTL.aiqb
```

No restart needed: the override is checked at every sensor start. Close and
reopen the camera app, then expect in the journal:

```
AIQB OVERRIDE: /etc/hp-elitebook-x-g2i/OV05C10_CJFPE50_PTL.aiqb (1099805 bytes) replaces the stock OV05C10_CJFPE50_PTL.aiqb for this session, staged in /run/hp-elitebook-x-g2i-camera/camera-cfg
```

Checks:

- Frames still arrive (the override loads; a corrupt file here would show as
  a camhal failure and, after two strikes, fallback — which is the designed
  containment).
- `ls -l /run/hp-elitebook-x-g2i-camera/camera-cfg/OV05C10_CJFPE50_PTL.aiqb`
  shows the override's size.
- Remove the override (`sudo rm /etc/hp-elitebook-x-g2i/OV05C10_CJFPE50_PTL.aiqb`),
  close/reopen the app: the AIQB OVERRIDE line no longer appears, stock
  tuning is back. Drop-in and removal both take effect without a restart.

## 5. NR strength knob

Shipped default is `HPCAM_NR_STRENGTH=-60` in `/etc/hp-elitebook-x-g2i-camera.conf`
(measured 2026-08-30: ~28% less within-frame dark-scene noise; -120 gives
~45%). Verify the plumbing end to end:

```
grep NR /etc/hp-elitebook-x-g2i-camera.conf        # -60
journalctl -u hp-elitebook-x-g2i-camera -b | grep nr_strength   # nr_strength=-60 on engine start
```

Then edit the conf to `-120`, `sudo systemctl restart hp-elitebook-x-g2i-camera`,
reopen the camera: the start line must show `nr_strength=-120` and a dim-room
image should be visibly smoother. `0` restores the HAL's untouched behaviour.
Leave it at `-60` until -120 has passed a daylight detail check.

## 6. Rollback

If v2 has to come out (either package misbehaving):

```
sudo pacman -U pkgbuilds/hp-elitebook-x-g2i-camera/hp-elitebook-x-g2i-camera-1.2.0-1-x86_64.pkg.tar.zst
sudo pacman -R hp-elitebook-x-g2i-camhal-runtime
sudo systemctl restart hp-elitebook-x-g2i-camera
```

pacman will warn about the version downgrade; that is the point. The 1.2.0
daemon ignores the v2 conf file and the /etc/hp-elitebook-x-g2i directory
(both become orphans owned by nothing after the downgrade — harmless, remove
by hand if tidiness matters). Verify the 1.2.0 baseline: service active,
camera works, LED follows use. No reboot is required in either direction;
kernel-side pieces are identical across 1.2.0 and 2.0.0.

## 7. 2.0.2: GPU temporal denoise and AE clamps

Artifact: `hp-elitebook-x-g2i-camera-2.0.2-1-x86_64.pkg.tar.zst`. New knobs:
`HPCAM_DENOISE` (default 8), `HPCAM_EXPOSURE_RANGE`, `HPCAM_GAIN_RANGE`.
The reader's chunk size follows the filter, so tearing or green/magenta bands
in either mode is a reader bug, not a tuning problem — report it, do not tune
around it.

Filter active (the default). Open the camera, then:

```
journalctl -u hp-elitebook-x-g2i-camera -b | grep 'camhal engine started' | tail -1
```

Expect the vapostproc stage in the pipeline and the value at the end:

```
... icamerasrc device-name=ov05c10-uf ! video/x-raw,format=NV12,width=1920,height=1080 ! vapostproc denoise=8 ! video/x-raw,format=NV12,width=1920,height=1080 ! fdsink fd=3 (sensor on, LED on), nr_strength=-120 denoise=8
```

Cross-check the real child cmdline while the camera is open (the journal line
is built from the same tokens, but this is the ground truth):

```
tr '\0' ' ' </proc/$(pgrep -f 'gst-launch-1.0 -q icamerasrc')/cmdline; echo
```

Live checks: frames arrive (status file `fps=` near 30), noise blobs in a dim
room visibly calmer than 2.0.1, CPU of the gst child still near zero
(the filter runs on the GPU's VEBOX block), no ghost trails when waving a
hand (at denoise=8; higher values may ghost).

Bypass drill (denoise=0 must be byte-identical to 2.0.1):

```
# set HPCAM_DENOISE=0 in /etc/hp-elitebook-x-g2i-camera.conf
sudo systemctl restart hp-elitebook-x-g2i-camera
```

Reopen the camera. The start line must show the 2.0.1 pipeline — no
vapostproc element — ending `denoise=0`, and the image must be clean, no
tearing: this exercises the padded-chunk reader path. Then restore the
default (comment the line out) and restart; the filter line returns.

AE knob drill:

```
# set HPCAM_EXPOSURE_RANGE=100~50000 in the conf
sudo systemctl restart hp-elitebook-x-g2i-camera
```

Reopen the camera and expect both the dedicated line and the property in the
pipeline:

```
AE knob: exposure-time-range=100~50000 us applied to icamerasrc
... icamerasrc device-name=ov05c10-uf exposure-time-range=100~50000 ! ...
```

In a dim room the status file `fps=` may drop below 30 and motion blurs —
that is the documented trade, not a fault. Validation drill: set
`HPCAM_EXPOSURE_RANGE=abc`, restart, reopen; expect
`HPCAM_EXPOSURE_RANGE=abc is not min~max — ignoring` in the journal and a
pipeline without the property. Same drill applies to `HPCAM_GAIN_RANGE`.
Unset both and restart to finish.
