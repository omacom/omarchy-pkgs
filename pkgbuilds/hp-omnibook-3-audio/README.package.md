# hp-omnibook-3-audio

The speaker and microphone topology for the HP OmniBook 3 14 (14-hz0xxx, board 8EF1, Snapdragon X X1-26-100).

Its device tree, from `linux-omarchy-dtbs`, names the sound card `X1E80100-HP-OMNIBOOK-3`, so the kernel asks for `qcom/x1e80100/X1E80100-HP-OMNIBOOK-3-tplg.bin`. linux-firmware doesn't have it, and without it the card doesn't register: PipeWire offers only a Dummy Output.

The laptop wires its audio as the ThinkPad T14s does. It has two WSA884x speakers on `WSA_CODEC_DMA_RX_0`, the WCD9385 headset codec on the RX and TX codec DMA ports, the lid microphones on `VA_CODEC_DMA_TX_0`, and DisplayPort on the three DisplayPort ports. This package builds Linaro's T14s description under the laptop's name, from linux-msm/audioreach-topology, and checks the result against linux-firmware's `X1E80100-Romulus-tplg.bin`, which is built from the same description and is the file tested on a 14-hz0288nr (omacom/omarchy-pkgs#2754).

The file is installed xz-compressed. The kernel tries the plain name, then `.zst`, then `.xz`, so a copy linux-firmware may ship later is the one it loads, and the two packages never install the same path.

No UCM change is needed: alsa-ucm-conf's X1 dispatcher already sends `HP.*Omnibook.*` to the T14s profile, and the laptop's DMI string (`HP-103C_5335KV HP OmniBook 3-8EF1`) matches it.

The OmniBook 3 16 uses the 14's dtsi and the same card name, so it should load the same file, but it hasn't been tested.

## Retirement

Drop this package once linux-firmware ships an OmniBook 3 topology.
