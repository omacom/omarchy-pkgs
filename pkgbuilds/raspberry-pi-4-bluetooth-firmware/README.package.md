This package supplies the Bluetooth patch firmware for the Raspberry Pi 4 Model B's CYW43455 (BCM4345C0). `btbcm` loads it when `hci_uart` brings the controller up. Without it the controller runs its ROM firmware and reports the placeholder address `AA:AA:AA:AA:AA:AA`.

The file comes from Raspberry Pi's `bluez-firmware`, which Raspberry Pi OS ships. It is installed under the board-specific name `brcm/BCM4345C0.raspberrypi,4-model-b.hcd`. `btbcm` tries that name first, so other boards with the same chip do not pick it up. Upstream `linux-firmware` does not carry this file.

The licence is the Cypress end-user licence that covers the Wi-Fi firmware of the same chip, taken from `linux-firmware`.

Arch Linux ARM's `firmware-raspberrypi` also carries this file. It also installs Wi-Fi firmware into `/usr/lib/firmware/updates`, which replaces the newer `linux-firmware` 43455 firmware. This package carries the Bluetooth file only.

Bluetooth also needs the controller on the PL011 UART with hardware flow control. Under pftf UEFI this means the firmware card's `config.txt` and `tryboot.txt` must not load `dtoverlay=miniuart-bt`.

`"sync": false`: upstream has no releases or tags. A newer file arrives through a pinned-commit bump.
