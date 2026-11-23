# dell-xps-13-9345-sensors

Ambient light for the Dell XPS 13 9345 (Snapdragon X Elite). The AMS TCS3530 is run by the Qualcomm sensor core on the ADSP, which needs its configuration served from the host before it reports anything:

```
TCS3530 -> sensor core on the ADSP <- hexagonrpcd (serves config and registry)
        -> QRTR/QMI -> libssc -> iio-sensor-proxy -> auto-brightness consumers
```

The package follows `microsoft-surface-pro-11-sensors`, with two differences: the XPS uses the standard `ambient_light` type (the Surface's `color` type reports nothing here), and its sensor has to be re-armed for every sample.

## Contents

- `hexagonrpcd` and `libhexagonrpc` from `linux-msm/hexagonrpc`, pinned, with the Surface package's patch for a writable sensor registry.
- `libssc` from `DylanVanAssche/libssc`, pinned, with a patch that re-arms the light sensor every two seconds while it is open. The TCS3530 advertises on-change reporting, but with `is_dri=0` sends one sample per enable. The library is private to this package and used by iio-sensor-proxy through a drop-in.
- `dell-xps-13-9345-sensors.service`, which runs hexagonrpcd sandboxed, only on `dell,xps13-9345`.
- A sleep hook that stops iio-sensor-proxy across suspend, because libssc asks the DSP to wake the SoC for each report.
- `dell-xps-13-9345-sensors-extract`.

## Setup

The configuration is Dell and Qualcomm's and is not redistributable, so the package contains none. With Windows still on the disk and not locked by BitLocker:

```
sudo dell-xps-13-9345-sensors-extract
sudo systemctl enable dell-xps-13-9345-sensors.service
```

Then reboot. The extractor reads Windows read-only and copies the sensor configuration from the driver store, along with the registry Windows parsed from it. The service restores that registry on every start. `-d DIR` takes a mounted Windows volume, or a saved copy holding `config/` and `registry/`.

`monitor-sensor --light` should then follow a hand over the webcam and a light shone at it.

## Known issues

- iio-sensor-proxy 3.9 takes its bus name before it has found the sensor. A client that claims the light sensor in that window, as `monitor-sensor` does when the proxy returns after suspend, is recorded without the sensor starting, and no later claim starts it until every client has released. Reclaiming once `HasAmbientLight` is true works around it. The fix is under review upstream in [iio-sensor-proxy!415](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/merge_requests/415).
- At boot, hexagonrpcd can start a moment before the ADSP is ready and exit with `Could not attach to FastRPC node`. The service restarts it two seconds later.

## Retirement

Drop once hexagonrpc is packaged with registry write support and libssc handles on-change sensors that report once per enable.
