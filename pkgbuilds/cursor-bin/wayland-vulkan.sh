
# Chromium's Wayland backend does not support Vulkan, and with it the GPU
# process can die and take Cursor down with SIGTRAP (omacom/omarchy#16139).
# Omarchy runs Electron on Wayland, so keep Vulkan off unless X11 was chosen.
# Add it to a --disable-features list from the flags files rather than
# passing a second one, which would replace the first.
if [[ " ${electronflags[*]} ${codeflags[*]} " != *" --ozone-platform=x11 "* &&
  " ${electronflags[*]} ${codeflags[*]} " != *" --ozone-platform-hint=x11 "* ]]; then
    vulkan_listed=0
    for i in "${!electronflags[@]}"; do
        if [[ ${electronflags[i]} == --disable-features=* ]]; then
            [[ ,${electronflags[i]#*=}, == *,Vulkan,* ]] || electronflags[i]+=",Vulkan"
            vulkan_listed=1
        fi
    done
    for i in "${!codeflags[@]}"; do
        if [[ ${codeflags[i]} == --disable-features=* ]]; then
            [[ ,${codeflags[i]#*=}, == *,Vulkan,* ]] || codeflags[i]+=",Vulkan"
            vulkan_listed=1
        fi
    done
    (( vulkan_listed )) || electronflags+=("--disable-features=Vulkan")
fi

