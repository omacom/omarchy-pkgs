# asus-zenbook-14-ux3480qa-audio

Speakers and microphones for the ASUS Zenbook 14 UX3480QA (Snapdragon X X1-26-100, Purwa).

The card registers and loads linux-firmware's `qcom/x1e80100/X1E80100-ASUS-Zenbook-A14-tplg.bin`, but UCM finds no profile for it. alsa-ucm-conf picks an X1 laptop's profile by a DMI regex over `board_vendor-product_family-board_name`. That regex covers the Zenbook A14 as `ASUSTeK COMPUTER.*ASUS (Zenbook A14|...)`, while this model reads

```
ASUSTeK COMPUTER INC.-Zenbook 14-UX3480QA
```

so UCM has no configuration for the card:

```
ALSA lib main.c:1814:(snd_use_case_mgr_open) [error.ucm] failed to import hw:0 (empty configuration)
```

and PipeWire offers no speakers, microphones or headset.

The board has the A14's audio layout: two WSA884x speakers, two DMICs on the VA macro, a WCD938x headset jack and three DP/HDMI outputs.

- `/usr/share/alsa/ucm2/conf.d/x1e80100/ASUSTeKCOMPUTERINC.-Zenbook14UX3480QA-1.0-UX3480QA.conf` (and the matching `UX3480QAB` path): the ThinkPad T14s profile (`Qualcomm/x1e80100/LENOVO-T14s.conf`, alsa-ucm-conf, Syntax 6) restated, plus a `FixedBootSequence` that sets `WSA WSA_RX0 Digital Volume` and `WSA WSA_RX1 Digital Volume` to `100%`, the kernel's ceiling, on every boot: `84` (`0 dB`) with `linux-omarchy-aarch64`'s raised limit, `81` (`-3 dB`) without it. A level saved under an older, lower kernel ceiling would otherwise stick in `/var/lib/alsa/asound.state`, and with software volume nothing else moves them.
- `/usr/share/wireplumber/wireplumber.conf.d/60-asus-zenbook-14-ux3480qa-soft-volume.conf`: sets `api.alsa.soft-mixer = true` for this card.

## Volume

UCM merges the two amplifiers' `PA Volume` controls into `Speakers Volume`, which PipeWire uses as the speakers' hardware volume and fills out with software attenuation below it. On this board `PA Volume` does not change the output: measured with the built-in DMICs at 1 kHz, levels matched within `0.04 dB` across PA `1`, `3`, and `6` (`-36.80` / `-36.77` / `-36.76 dBFS`), and within `0.01 dB` with the compander disabled, while a 3 dB digital step (`81 -> 78`) dropped output by `2.96 dB`. Roughly the top 30% of the volume slider therefore did nothing. Switching the card to `api.alsa.soft-mixer = true` lets PipeWire scale the full range smoothly in software while UCM holds the WSA digital path at the kernel's ceiling.

## Retirement

- UCM profile: drop once `alsa-ucm-conf` matches `Zenbook 14-UX3480QA` / `UX3480QAB` and sets the WSA digital volumes on every boot.
- WirePlumber rule: drop once `PA Volume` changes the output on this board, or UCM stops using it as the speakers' volume.
