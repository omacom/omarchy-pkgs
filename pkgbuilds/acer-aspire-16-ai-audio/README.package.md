# acer-aspire-16-ai-audio

The speaker and microphone topology for the Acer Aspire 16 AI (A16-11M, Snapdragon X X1-26-100).

Its device tree, from `linux-omarchy-dtbs`, names the sound card `X1P42100-ACER-Aspire-16-AI`, so the kernel asks for `qcom/x1e80100/X1P42100-ACER-Aspire-16-AI-tplg.bin`. linux-firmware doesn't have it, and without it the card doesn't register.

The laptop wires its audio as the ThinkPad T14s does. It has two WSA8845 speakers on `WSA_CODEC_DMA_RX_0`, the WCD9385 headset codec on the RX and TX codec DMA ports, the lid microphones on `VA_CODEC_DMA_TX_0`, and DisplayPort on the three DisplayPort ports. This package builds Linaro's T14s description under the laptop's name, from linux-msm/audioreach-topology. The build checks the result against the Surface Laptop 7's topology in linux-firmware, which is built from the same description and which GenericCPU tested on an A16-11M (omacom/omarchy#17555).

The file is installed xz-compressed. The kernel tries the plain name, then `.zst`, then `.xz`, so a copy linux-firmware may ship later is the one it loads, and the two packages never install the same path.

The UCM profile, GenericCPU's, is in this repository's `alsa-ucm-conf`, matched by the laptop's DMI.

## Retirement

Drop this package once linux-firmware ships an Aspire 16 AI topology.
