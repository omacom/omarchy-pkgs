# surface-snapdragon-addresses

Wi-Fi and Bluetooth addresses for Snapdragon Microsoft Surface devices. Neither the Surface Pro 11 nor the Surface Laptop 8 gets a usable address from Linux on its own. Both keep one base address in the `MacAddressEmulationAddress` UEFI variable and lay the others out the same way around it, as Windows' registry shows on each:

| Address | Value |
| --- | --- |
| Wi-Fi | variable − 2 |
| Bluetooth | variable − 1 |
| Surface Dock Ethernet | the variable itself |

Tested on the Surface Pro 11; the Surface Laptop 8 uses the same layout but has not run this package yet.

Everything here acts only when the DMI system vendor is `Microsoft Corporation` and the variable exists. It does not check the device tree, so the Surface Laptop 8's still-changing compatible string does not matter.

## Contents

- **Bluetooth**: the WCN7850 stays an unconfigured controller until given a public address. A udev rule starts `surface-bluetooth-address@<hci>.service` for each Qualcomm UART controller (`hci_uart_qca`), and the service sets the variable minus one through `btmgmt`. That is the identity Windows uses and that keyboards such as the Surface Pro Flex Keyboard bond to. Override it with `SURFACE_BLUETOOTH_PUBLIC_ADDRESS` in `/etc/surface-bluetooth-address.conf`.
- **Wi-Fi**: ath12k reports a Qualcomm placeholder (`00:03:7f:…`) as the WCN7850's permanent address, a different one on each boot. A udev rule runs `surface-wifi-address` as each ath12k Wi-Fi interface (`ath12k_pci` or `ath12k_wifi7_pci`) is added, before NetworkManager takes it, and sets the variable minus two. It leaves an interface that is already up alone. The permanent address the kernel reports stays the placeholder, and NetworkManager's per-network cloned addresses still apply on top. Override it with `SURFACE_WIFI_ADDRESS` in `/etc/surface-wifi-address.conf`.

## Retirement

- Bluetooth: drop once the device trees provide `local-bd-address` or the firmware supplies a public address.
- Wi-Fi: drop once ath12k takes the address from the device tree (`local-mac-address`) and the device trees get one.

## Licence

MIT.
