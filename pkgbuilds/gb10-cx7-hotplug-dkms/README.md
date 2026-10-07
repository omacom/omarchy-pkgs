# Experimental GB10 CX7 hotplug driver

This package carries buildable driver sources for review and hardware qualification. It does not provide working automatic idle-power management. No userspace endpoint-removal/rescan coordinator, udev power handler, firmware update, or power-changing install hook is included.

The source is NVIDIA's GPL-2.0 driver at commit `dd99802c8b0c384169bb36293c9517fa67238e47`, originally added by [2154b62f0a38191d1de49245102d64daf8dcc98b](https://github.com/NVIDIA/NV-Kernels/commit/2154b62f0a38191d1de49245102d64daf8dcc98b). The pinned source checksum and local patch keep upstream provenance separate from the Omarchy changes.

## Defaults and build

DKMS autoinstall is disabled. A modprobe blacklist suppresses automatic loading, and probe returns before touching hardware unless the module parameter `experimental=1` is explicitly supplied. Even then `hotplug_enabled` starts at zero. Neither installation nor compilation enables power management.

Build against matching aarch64 kernel headers in a credential-free build container. After `makepkg --nobuild` prepares the source, compile with `make -C src KDIR=/path/to/matching/kernel/build W=1`. A successful compile does not qualify device binding or power transitions. The running Omarchy kernel needs its existing MediaTek GPIO/EINT ACPI support; this standalone module does not replace that support.

## Concurrency and lifetime

The driver registers a NULL primary IRQ handler; GPIO reads, allocations and uevents run only in threaded context. A per-device mutex serializes both GPIO threads with sysfs writes. Hardware paths acquire that mutex before `pci_lock_rescan_remove()`, keeping PCI endpoint checks and the corresponding hardware transition under the same topology lock. The PCI notifier can run under PCI enumeration locks and never acquires the transition mutex. It only reads the runtime enable flag and applies the upstream MPS configuration to matching NICs descending from the firmware-validated root ports.

Removal drains sysfs callbacks, disables transitions under the mutex, frees and synchronizes each requested IRQ, unregisters the PCI notifier, then releases the pinctrl handle before its mappings and the cached PCI references. Error paths after IRQ registration use the same IRQ cleanup. Mapping failures abort probe; firmware bit indices, register ranges, topology and GPIO roles are checked before use. Runtime-PM references taken for link training are balanced on success and failure.

The four BOOT, PRSNT, PERST and EN GPIOs are requested exclusively through a device-managed ACPI mapping. The driver checks that the resulting descriptors match the parsed controller and pins. `GPIOD_ASIS` with the ACPI no-direction-override quirk retains firmware direction and output levels during acquisition; runtime raw-value accesses preserve the vendor physical-level protocol. Clock-request pins remain under pinctrl. Firmware GPIO conflicts cause probe to fail rather than borrowing another consumer's lines.

## Interfaces and qualification gates

The upstream `pcie_hotplug/hotplug_enabled` and `debug_state` controls remain root-writable. The additional read-only `state` attribute reports the asynchronous hardware handshake: 0 ready, 1 unplug transition, 2 powered off, 3 plug transition, 4 powered on, 5 firmware startup, 6 link initialization, 7 unknown/error. Power-on requires powered-off state; a requested transition is not evidence that the PCI endpoints have been rescanned or links recovered. Disabling control does not restore a powered-off device. Power-off requests re-read the physical PRSNT GPIO under the transition and PCI locks, reject a cable-present indication, and propagate read errors before changing state or hardware. This rejects stale removal requests; it does not prevent a cable edge after the read, undo prior userspace endpoint removal, or protect active users.

Before any binding, independently review the patch and check Dell's ACPI `_DSD`/`_CRS` against the expected two-port, four-function ConnectX-7 topology. The presence of `MTKP0001` alone is insufficient. Before activating power control, provide a separately reviewed coordinator that verifies every managed endpoint was removed, preserves unrelated PCI devices, respects active RDMA/network/storage users, waits for the boot handshake, and rescans only the managed root ports. Do not copy the vendor shell handler's fixed sleeps or partial-removal success condition.

Physical qualification requires a supported QSFP112 cable, repeated unplug/replug cycles, all four NIC functions recovering at their expected link speed, throughput/RDMA checks, teardown and suspend/reboot testing, no new kernel warnings, and measured power savings. Do not import or autoload the unrelated `mstflint_access` module: [upstream issue 1786](https://github.com/Mellanox/mstflint/issues/1786) reports stale PCI references after hotplug.

No physical qualification or idle-power result is claimed by this package.
