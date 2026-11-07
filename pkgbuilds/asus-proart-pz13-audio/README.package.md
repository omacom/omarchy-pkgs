# asus-proart-pz13-audio

The speaker and microphone topology for the ASUS ProArt PZ13 (HT5306QA, Snapdragon X Plus X1P-42-100).

Its device tree, carried in `linux-omarchy-aarch64`, names the sound card `X1P42100-ASUS-ProArt-PZ13`, so the kernel asks for `qcom/x1e80100/X1P42100-ASUS-ProArt-PZ13-tplg.bin`. linux-firmware doesn't have it, and without it the card doesn't register.

The tablet wires its audio as the Surface Pro 12in does: two WSA8845 speakers on `WSA_CODEC_DMA_RX_0` and the DMICs on `VA_CODEC_DMA_TX_0`. Alex Grucza, who wrote the tree, builds Linaro's Surface Pro 12in description under the tablet's name, and so does this package, from linux-msm/audioreach-topology. The build checks the result against the Surface Pro 12in topology linux-firmware ships, which it matches byte for byte.

The file is installed xz-compressed: the kernel tries the plain name, then `.zst`, then `.xz`, so a copy linux-firmware may ship later is the one it loads, and the two packages never install the same path.

The UCM profile, Alex's, is in this repository's `alsa-ucm-conf`, matched by the tablet's DMI. Sound on monitors needs his DisplayPort fixes in msm and a topology with DisplayPort graphs, which aren't carried.

## Retirement

Drop this package once linux-firmware ships a ProArt PZ13 topology.
