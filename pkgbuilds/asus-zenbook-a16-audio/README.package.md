# asus-zenbook-a16-audio

Speakers and microphones for the ASUS Zenbook A16 (UX3607OA, Snapdragon X2 Elite / Glymur).

Without it the `snd-x1e80100` card fails to probe:

```
qcom-apm gprsvc:service:2:1: tplg firmware loading qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin failed -2
snd-x1e80100 sound: ASoC: failed to instantiate card -2
```

so there is no ALSA card and PipeWire only offers a dummy output.

The board's device tree has the same two audio links as Qualcomm's Glymur CRD: four WSA884x speakers (woofer and tweeter, left and right) on `WSA_CODEC_DMA_RX_0`, and two DMICs on `VA_CODEC_DMA_TX_0`. Those are exactly the backends the CRD topology defines, and the CRD UCM profile drives four WSA884x speakers. This package points the board names at the CRD files:

- `/usr/lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin` → `GLYMUR-CRD-tplg.bin` (linux-firmware-qcom)
- `/usr/share/alsa/ucm2/conf.d/glymur/ASUSTeKCOMPUTERINC.-ZenbookA16UX3607OA-1.0-UX3607OA.conf`: the CRD profile (`Qualcomm/glymur/GLYMUR-CRD.conf`, alsa-ucm-conf) restated, plus a `FixedBootSequence` that sets the four WSA digital volumes to `100%`, the kernel's ceiling, on every boot: 84 (0 dB) with linux-omarchy-aarch64's Zenbook A16 limit, 81 (-3 dB) on a kernel without it. The CRD profile sets them only in a `BootSequence`, which runs when the card has no saved state, so a level saved under the kernel's earlier -3 dB ceiling would otherwise stick, and with software volume nothing else moves them.

The kernel requests the topology by the device tree's model, while UCM looks the profile up by the card's long name, which the kernel builds from DMI (`board_vendor-product_name-product_version-board_name`, stripped of spaces).

## SoundWire clock stop

The four amplifiers sit on two SoundWire buses, the left pair on `6c80000.soundwire` and the right pair on `6ca0000.soundwire`. Both controllers runtime-suspend 3 s after the speakers go idle by stopping the bus clock, and resume by restarting it. On this board that resume leaves one bus's amplifiers unattached, or attached with every register reading `0x21`, about two times in three (10 of 15 idle/play cycles). The amplifier driver's PA recovery then reports `PA fault ... 0x21` and leaves that pair disabled, so half the speakers are silent until the next stop. A full controller reset and enumeration, as at boot, has always brought all four up.

`60-asus-zenbook-a16-soundwire.rules` sets `power/control=on` on the two controllers, for this board only (DMI board `UX3607OA`), so the bus clock never stops. With it all four amplifiers stayed attached through every idle/play cycle, and idle battery draw rose by under 0.1 W (6.52 W to 6.61 W, averaged over 40 s windows).

## Volume

UCM merges the four amplifiers' `PA Volume` controls into one `Speakers Volume`, which PipeWire uses as the speakers' hardware volume and fills out with software attenuation below it. On this board `PA Volume` does not change the output: measured with the built-in microphones, a woofer gave the same level (within 0.1 dB) at PA 6 and 12, with the amplifier's compander on and off, on fresh streams and at -20 and -1 dBFS, although the register write reaches the amplifier. So the part of the volume range the PA covers did nothing, about the top 30% with the upstream 0 dB PA ceiling.

`60-asus-zenbook-a16-soft-volume.conf` is a WirePlumber rule that sets `api.alsa.soft-mixer` for this card (matched on its long name), so PipeWire does all of the volume in software and leaves the amplifiers at the levels UCM sets.

## Retirement

- Topology and UCM: drop once linux-firmware ships a Zenbook A16 topology and alsa-ucm-conf a Zenbook A16 profile; the files would conflict.
- udev rule: drop once the Qualcomm SoundWire driver resumes v3.1.0 controllers reliably, for example by resetting and re-enumerating instead of exiting clock stop.
- WirePlumber rule: drop once `PA Volume` changes the output on this board, or UCM stops using it as the speakers' volume.
