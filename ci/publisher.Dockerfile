# The image the publishing jobs run their tools in (gpg, repo-add, bsdtar,
# rclone): Arch's base image and packages from Arch's repositories, without
# the build toolchain and repositories the builder image (build/Dockerfile)
# carries.
#
#   docker build -t omarchy-publisher -f ci/publisher.Dockerfile ci
FROM ghcr.io/archlinux/archlinux:base
RUN pacman -Syu --noconfirm --needed jq rclone zstd && pacman -Scc --noconfirm
