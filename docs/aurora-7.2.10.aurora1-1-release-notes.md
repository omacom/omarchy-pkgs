# Aurora kernel 7.2.10.aurora1-1 edge update

This update follows the unified 7.2.10 kernel on `integration/aurora`.
The build merges the kernel's shared `asahi.config` over the existing distro
base and validates every requested setting after Kconfig resolution.
All supported Macs, including Neo, use this same hardware fragment.
The package has no private driver list or dedicated Neo build profile.

- Neo NOR, PMU RTC and MAX98360A speaker amplifier support are included.
- Internal Force Touch trackpad haptics and J613/J615 PMP telemetry are modules.
  External Magic Trackpads continue to use the existing magicmouse driver;
  Neo has a mechanical trackpad.
- ISP webcam support remains enabled.
- Intel IGB and IGC PCIe Ethernet adapters and the shared Asahi USB4 drivers
  are enabled on matching hardware.
- SEP uses the shared module default, with trusted keys and key retention enabled.

The dedicated J700 config fragments and snapshot are removed from the kernel.
Their device-specific debug and boot-policy overrides are not applied to the
shared kernel. Reboot after the update. Normal audio protection services and
firmware/calibration remain required.

This update targets edge. Record M1/M2 cold-boot qualification before promotion
to rc or stable; config checks alone are not hardware qualification.
