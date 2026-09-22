# DGX Dashboard on Arch Linux ARM

Repackages NVIDIA's DGX Dashboard 0.25.11 arm64 .deb for DGX Spark, with the
Debian maintainer actions translated to sysusers, tmpfiles and systemd units.
This is a temporary compatibility integration until NVIDIA supports Arch
natively; it will be removed once a native replacement is validated.

## Updates

The admin service's `apt` queries are answered by read-only adapters that
refresh a temporary copy of the pacman sync database. Nothing is installed and
the live database is not changed. To see the full result:

```sh
sudo dgx-arch-package-status --refresh
```

Install updates with `omarchy update`. The vendor's combined Ubuntu
update-and-reboot D-Bus method is denied, and the Updates page shows
`omarchy update` guidance in place of its Update button. Firmware updates are
handled separately.

## Notebooks

The vendor's pinned notebook stack does not install on Python 3.14. On first
launch, creating `~/jupyterlab/.venv` uses `uv` to download a managed Python
3.12 and then several GiB of vendor wheels, so internet access is required.
These files live outside pacman. An existing `.venv` is never replaced.

## Limitations

- The Updates page can show an empty list when a query fails; the JSON command's
  exit status and timestamp are authoritative.
- Packages outside the configured repositories are listed but not checked for
  updates.
- Device settings have not been validated.
- The vendor PyTorch build warns about GB10 compute capability 12.1.
