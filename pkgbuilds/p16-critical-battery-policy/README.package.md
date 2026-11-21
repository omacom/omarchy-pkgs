# Critical battery power-off policy

This optional package configures UPower to power off when its existing critical
battery action threshold is reached. The setting is system-wide for batteries
and UPS devices managed by UPower; install the package only where this policy is
wanted. On systems with no hibernation, UPower's automatic critical action can
resolve to sleep; suspend-to-idle continues to draw power and may let a
critically low battery run flat.

The package changes only `CriticalPowerAction`. It does not set or change
`PercentageLow`, `PercentageCritical`, or `PercentageAction`, and does not
modify GNOME battery or charge settings. The action threshold remains owned by
UPower; on the tested system it is 2%. No battery-depletion test was performed
because that would risk a forced shutdown and data loss.

The configuration is installed at
`/etc/UPower/UPower.conf.d/50-p16-critical.conf`. Pacman preserves local edits
to the drop-in through the `backup` entry. UPower reads configuration when its
daemon starts. After installing or upgrading this package, restart it manually
to apply the policy:

```sh
sudo systemctl restart upower.service
sudo /usr/lib/p16-critical-battery-policy/verify-critical-action.py
```

The verifier calls UPower's `GetCriticalAction` system D-Bus method and exits
with an error unless the running daemon reports `PowerOff`.

## Provenance and license

The drop-in is copied unchanged from Johann Hartmann's P16 Linux repository,
merged in [PR #4](https://github.com/johannhartmann/asus-proart-p16-rtx-spark-linux/pull/4)
at commit `40a88e842e7dd9616b6892dd875635c1e21b9c59`. Its SHA-256 is
`dfc02d0f211cdf595fa6762f2636447e2fb52d0aea448c62383ac84f8fe10cbc`.
The upstream `LICENSES.md` identifies configuration files as MIT licensed.
Package metadata, verifier, and tests are also MIT licensed; the license text
is installed with the package.
