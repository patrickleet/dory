#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source PINS

ARCH="${1:-arm64}"
OUT="$(pwd)/../out"
mkdir -p "$OUT"

case "$ARCH" in
  arm64)
    PLATFORM="linux/arm64"
    MAKE_ARCH="arm64"
    CONFIGS="/src/dory.config /src/dory-arm.config"
    TARGETS="Image"
    ;;
  amd64|x86_64)
    PLATFORM="linux/amd64"
    MAKE_ARCH="x86_64"
    CONFIGS="/src/dory.config /src/dory-x86.config"
    TARGETS="vmlinux bzImage"
    ;;
  *)
    echo "usage: $0 [arm64|amd64]" >&2
    exit 64
    ;;
esac

if [ "${DORY_EXPERIMENTAL_GPU:-0}" = "1" ]; then
  CONFIGS="$CONFIGS /src/dory-gpu.fragment"
fi

docker run --rm --platform "$PLATFORM" \
  -e ARCH="$MAKE_ARCH" \
  -e DORY_KERNEL_ARCH="$ARCH" \
  -e DORY_KERNEL_CONFIGS="$CONFIGS" \
  -e DORY_KERNEL_TARGETS="$TARGETS" \
  -e DORY_KERNEL_GPU="${DORY_EXPERIMENTAL_GPU:-0}" \
  -v "$PWD":/src \
  -v "$OUT":/out \
  -w /build \
  debian:12-slim bash -euxc '
  apt-get update
  apt-get install -y build-essential flex bison bc libssl-dev libelf-dev xz-utils zstd curl python3
  curl -fsSL '"$KERNEL_URL"' -o linux.tar.xz
  echo "'"$KERNEL_SHA256"'  linux.tar.xz" | sha256sum -c -
  tar xf linux.tar.xz --strip-components=1
  make defconfig
  scripts/kconfig/merge_config.sh -m .config $DORY_KERNEL_CONFIGS
  make olddefconfig
  KSUFFIX=""; [ "$DORY_KERNEL_GPU" = 1 ] && KSUFFIX="-gpu"
  cp .config "/out/config-$DORY_KERNEL_ARCH$KSUFFIX"
  make -j$(nproc) $DORY_KERNEL_TARGETS
  if [ "$DORY_KERNEL_ARCH" = arm64 ]; then
    cp arch/arm64/boot/Image "/out/Image$KSUFFIX"
    zstd -19 -f "/out/Image$KSUFFIX" -o "/out/Image$KSUFFIX.zst"
  else
    cp vmlinux "/out/vmlinux-x86$KSUFFIX"
    zstd -19 -f "/out/vmlinux-x86$KSUFFIX" -o "/out/vmlinux-x86$KSUFFIX.zst"
    cp arch/x86/boot/bzImage "/out/bzImage-x86$KSUFFIX"
  fi
'
