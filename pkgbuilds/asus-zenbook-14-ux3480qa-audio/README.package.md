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

The board has the A14's audio layout: two WSA884x speakers, two DMICs on the VA macro, a WCD938x headset jack and three DP/HDMI outputs. This package installs a profile for the card's long name that includes the ThinkPad T14s profile, the one alsa-ucm-conf gives the A14:

- `/usr/share/alsa/ucm2/conf.d/x1e80100/ASUSTeKCOMPUTERINC.-Zenbook14UX3480QA-1.0-UX3480QA.conf` → `Qualcomm/x1e80100/LENOVO-T14s.conf` (alsa-ucm-conf)
- `/usr/share/alsa/ucm2/conf.d/x1e80100/ASUSTeKCOMPUTERINC.-Zenbook14UX3480QAB-1.0-UX3480QAB.conf`, the same profile for the UX3480QAB, whose product and board names end in B

UCM looks up `conf.d/<driver>/<long name>.conf` before the driver's own profile. The kernel builds the long name from DMI (`board_vendor-product_name-product_version-board_name`, stripped of spaces).

## Retirement

Drop once alsa-ucm-conf's x1e80100 DMI match covers the UX3480QA.
