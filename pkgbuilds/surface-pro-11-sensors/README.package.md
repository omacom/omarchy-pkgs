# surface-pro-11-sensors

Ambient light for the Microsoft Surface Pro 11 with Snapdragon X Elite. The AMS TCS3430 colour sensor is run by the Qualcomm sensor core on the ADSP, which needs its configuration served from the host before it reports anything:

```
TCS3430 -> sensor core on the ADSP <- hexagonrpcd (serves config and registry)
        -> QRTR/QMI -> libssc -> iio-sensor-proxy -> desktop auto-brightness
```

## Contents

- `hexagonrpcd` and `libhexagonrpc` from `linux-msm/hexagonrpc`, pinned, with a patch that lets the daemon write the registry the DSP generates.
- `libssc` from `DylanVanAssche/libssc`, pinned, with a patch that reads illuminance from Microsoft's `color` sensor, because the standard `ambient_light` sensor reports zero on this model. It is installed privately under `/usr/lib/surface-pro-11-sensors/` and used only by iio-sensor-proxy, through a drop-in.
- `surface-pro-11-sensors.service`, which runs hexagonrpcd sandboxed against `/var/lib/surface-pro-11-sensors/root`. It starts when the ADSP's FastRPC device appears, so a missing or failed DSP never holds up boot, and it runs only on the `microsoft,denali-oled` device tree.
- A sleep hook that stops iio-sensor-proxy across suspend: an open light stream otherwise wakes the SoC shortly into every deep suspend.
- `surface-pro-11-sensors-extract`.

## Sensor configuration

The configuration is Microsoft and Qualcomm's and is not redistributable, so the package contains none. `surface-pro-11-sensors-extract` copies it from the machine's own Windows installation (`DriverStore/FileRepository/surfacepro_snscfgcrd8380.inf_arm64_*`, read-only): the sensor JSON files and `json.lst`, `sns_reg_config` without carriage returns, and the platform identifiers. The SoC ID and revision come from the running system, because the Windows values do not match the ADSP. Omarchy runs it during installation. Afterwards, `sudo surface-pro-11-sensors-extract` rescans, or `-d DIR` takes a mounted driver store. BitLocker volumes cannot be read.

The DSP generates its registry on first use. Validate after a full reboot, not by restarting the ADSP: `busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy net.hadess.SensorProxy LightLevel` should change sharply between a covered sensor and a bright light.

## Retirement

Drop once hexagonrpc is packaged with registry write support and libssc falls back to the `color` sensor.

- hexagonrpc: registry writes are tracked in linux-msm/hexagonrpc issue 19 (pull request 21 proposes a writable copy under `/var`). Upstream `main` has since rewritten the method definitions, so this patch needs a rebase before it can be offered there.
- libssc: the `color` fallback has not been submitted yet.
