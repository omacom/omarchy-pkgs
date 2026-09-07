# Container engine helpers for Omarchy package build system

container_engine_supported() {
  [[ "$CONTAINER_ENGINE" == "docker" || "$CONTAINER_ENGINE" == "podman" ]]
}

if [[ -z "${CONTAINER_ENGINE:-}" ]]; then
  for engine in docker podman; do
    if command -v "$engine" >/dev/null 2>&1 && "$engine" info >/dev/null 2>&1; then
      CONTAINER_ENGINE="$engine"
      break
    fi
  done
fi
export CONTAINER_ENGINE

# Rootless Podman otherwise maps the image's builder uid 1000 to a subordinate
# host uid. keep-id makes files written through bind mounts belong to the user
# who invoked the build.
CONTAINER_RUN_ARGS=()
if [[ "$CONTAINER_ENGINE" == "podman" ]]; then
  CONTAINER_RUN_ARGS+=("--userns=keep-id:uid=1000,gid=1000")
fi

check_engine() {
  if [[ -n "$CONTAINER_ENGINE" ]] && ! container_engine_supported; then
    print_error "Unsupported CONTAINER_ENGINE: $CONTAINER_ENGINE (use docker or podman)"
    exit 1
  fi

  if [[ -z "$CONTAINER_ENGINE" ]]; then
    print_error "No working container engine found (tried Docker, then Podman)"
    if command -v docker >/dev/null 2>&1; then
      print_warning "Docker is installed but unavailable. Start it with: sudo systemctl start docker"
    elif command -v podman >/dev/null 2>&1; then
      print_warning "Podman is installed but 'podman info' failed"
    else
      print_warning "Install Docker or Podman"
    fi
    exit 1
  fi

  if ! command -v "$CONTAINER_ENGINE" >/dev/null 2>&1; then
    print_error "$CONTAINER_ENGINE is not installed"
    exit 1
  fi

  if ! "$CONTAINER_ENGINE" info >/dev/null 2>&1; then
    if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
      print_error "Docker daemon is not running or is not accessible"
      print_warning "Start Docker with: sudo systemctl start docker"
    else
      print_error "Podman is not available to the current user"
    fi
    exit 1
  fi
}

docker_native_arch() {
  case "$(uname -m)" in
    x86_64) echo x86_64 ;;
    aarch64 | arm64) echo aarch64 ;;
    *) return 1 ;;
  esac
}

setup_qemu() {
  local target_arch="${1:-aarch64}"

  if [[ "$CONTAINER_ENGINE" == "podman" ]]; then
    local registration="/proc/sys/fs/binfmt_misc/qemu-$target_arch"
    local packaged_registration="/usr/lib/binfmt.d/qemu-$target_arch-static.conf"
    local flags=""

    if [[ -r "$registration" ]]; then
      flags=$(sed -n 's/^flags: //p' "$registration")
    fi

    if [[ "$flags" == *F* && "$flags" == *C* ]]; then
      print_success "QEMU $target_arch emulation is registered"
      return 0
    fi

    print_error "Rootless Podman requires QEMU binfmt registration with the F and C flags"
    print_info "F keeps the emulator available inside containers; C lets container sudo preserve credentials."
    print_info "Configure it once with:"
    echo "    sudo pacman -S --needed qemu-user-static qemu-user-static-binfmt"
    echo "    sudo mkdir -p /etc/binfmt.d"
    echo "    sed 's/:FP$/:FPC/' $packaged_registration | sudo tee /etc/binfmt.d/qemu-$target_arch-static.conf >/dev/null"
    echo "    sudo systemctl restart systemd-binfmt"
    exit 1
  fi

  # Register emulators for builds whose target differs from the host.
  if ! "$CONTAINER_ENGINE" run --rm --privileged docker.io/multiarch/qemu-user-static --reset -p yes --credential yes >/dev/null 2>&1; then
    print_error "Failed to set up QEMU emulation"
    exit 1
  fi
  print_success "QEMU emulation enabled"
}

build_docker_image() {
  local build_dir="$1"
  local arch="${2:-x86_64}"
  local mirror="${3:-edge}"
  local platform=""
  local image_tag="omarchy-pkg-builder:latest-$arch-$mirror"

  
  case "$arch" in
    x86_64)  platform="linux/amd64" ;;
    aarch64) platform="linux/arm64" ;;
    *)
      print_error "Unsupported architecture: $arch"
      exit 1
      ;;
  esac
  
  print_info "Building container image for $arch ($platform) using $mirror mirror..."

  if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
    "$CONTAINER_ENGINE" buildx build \
      --platform "$platform" \
      --build-arg MIRROR="$mirror" \
      --load \
      -t "$image_tag" \
      -f "$build_dir/Dockerfile" \
      "$build_dir"
  else
    "$CONTAINER_ENGINE" build \
      --platform "$platform" \
      --build-arg MIRROR="$mirror" \
      -t "$image_tag" \
      -f "$build_dir/Dockerfile" \
      "$build_dir"
  fi
}

get_platform_arg() {
  local arch="$1"
  case "$arch" in
    x86_64)  echo "--platform=linux/amd64" ;;
    aarch64) echo "--platform=linux/arm64" ;;
    *)       return 1 ;;
  esac
}

make_dir_writable() {
  local dir="$1"
  if (( EUID == 0 )); then
    chmod -R 777 "$dir"
  else
    # chown can succeed on part of the tree and fail on the rest (files a
    # previous container left behind as another uid); the old `|| chmod`
    # fallback only ran when chown failed outright, leaving those files
    # unwritable. Always follow with chmod so the whole tree is usable.
    sudo chown -R "$(id -u):$(id -g)" "$dir" 2>/dev/null || true
    chmod -R 777 "$dir"
  fi
}
