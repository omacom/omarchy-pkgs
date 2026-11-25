# Only the build runner is under test; source-free fixtures need no Omarchy
# bootstrap, signing key, mirror, or production repository.
FROM ghcr.io/archlinux/archlinux:base-devel
# Match the production image, which does not retain pacman's private key.
RUN pacman -Syu --noconfirm --needed jq sudo && \
    useradd -m -u 1000 builder && \
    echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder && \
    printf '#!/bin/bash\nexec /usr/bin/pacman --ask 4 "$@"\n' > /usr/local/bin/pacman-for-makepkg && \
    chmod +x /usr/local/bin/pacman-for-makepkg && \
    mkdir /src && chown builder:builder /src && \
    rm -rf /etc/pacman.d/gnupg/private-keys-v1.d /var/cache/pacman/pkg/*
USER builder
WORKDIR /src
