## Summary

- Add the optional `p16-critical-battery-policy` package with a UPower drop-in that sets `CriticalPowerAction=PowerOff`.
- Preserve UPower's existing critical threshold and GNOME's battery and charge settings. The package changes no percentage or charge-limit values; the tested host's existing action threshold is 2%.
- Make the system-wide UPower action explicit: it applies to UPower-managed batteries and UPS devices, so installation is opt-in.
- Mark the package `sync: false` so it is not automatically installed. Applying the setting requires a manual UPower service restart after installation.
- Attribute the configuration to Johann Hartmann's merged PR #4 and retain its MIT provenance.

## Validation

- `makepkg --cleanbuild`: package built and its `check()` suite passed.
- `makepkg --printsrcinfo`: package metadata generated.
- `python -m unittest -v test_verify_critical_action`: `PowerOff` accepted; `Sleep` and D-Bus failure rejected.
- On the local running UPower 1.91.5 daemon, `GetCriticalAction` reports `PowerOff`; this branch's package was not installed and no service was restarted during this work.

## Hardware QA

UPower's existing action threshold is 2% on the validated system and is unchanged by this package. A battery-depletion test was not performed because it could force shutdown and risk data loss. Please validate after opting in and restarting UPower; do not infer physical battery behavior from the package build alone.
