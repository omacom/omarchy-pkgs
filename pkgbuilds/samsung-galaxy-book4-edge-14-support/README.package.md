# samsung-galaxy-book4-edge-14-support

Hardware support for the Samsung Galaxy Book4 Edge 14 (NP940XMA, NP944XMA; Snapdragon X Elite X1E-80-100) that no upstream package carries yet. Omarchy's hardware setup installs it on that laptop only.

The battery, charger, USB-C ports, keyboard backlight and fan come from linux-omarchy's `samsung-galaxybook-ec` and `samsung-emuec` drivers (Antheas Kapenekakis's). This package has what stays in userspace.

| File | What it does |
| --- | --- |
| `61-…-keyboard.rules` | The keyboard's HID descriptor has buttons in the BTN_0 range and ABS_VOLUME, so `input_id` also tags it as a tablet pad and libinput opens it as one. No key reaches the compositor. The rule clears those tags on the keyboard and its parent input node. From Jonny Heggheim's board package (github.com/hegjon/omarchy-galaxy-book4-edge). A systemd `60-input-id.hwdb` entry for `0cf2:9050` would make it unnecessary. |
| `63-…-bluetooth.rules`, `bdaddr`, `…-bdaddr@.service` | The WCN7850's NVM has no Bluetooth address (Windows supplies one), so the controller stays unconfigured. This sets a stable locally administered address made from the machine ID. From the same package. |
| `X1E80100-GalaxyBook4Edge-tplg.bin` | The name the tree gives the sound topology, linked to linux-firmware's `X1E80100-CRD-tplg.bin`: the card's DAI links match the CRD's. From Nicola Nicodemo's notes (github.com/n1c0la84/book4-edge-linux). The UCM profile, Nicola Nicodemo's, is in Omarchy's alsa-ucm-conf. |
