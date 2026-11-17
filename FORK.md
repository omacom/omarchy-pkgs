# Contribution seams

New package directory: pkgbuilds/broadcom-wl-wpa3-dkms.
Workflow lint config: .github/jactionlint.yaml declares the workstation runner.
Local gate and focused workflow run the same metadata, source-pin and lint commands.
Source package and exact-kernel module builds are separate integration checks.
