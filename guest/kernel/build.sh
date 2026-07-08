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
    CONFIGS="dory.config dory-arm.config"
    TARGETS="Image"
    ;;
  amd64|x86_64)
    PLATFORM="linux/amd64"
    MAKE_ARCH="x86_64"
    CONFIGS="dory.config dory-x86.config"
    TARGETS="vmlinux bzImage"
    ;;
  *)
    echo "usage: $0 [arm64|amd64]" >&2
    exit 64
    ;;
esac

if [ "${DORY_EXPERIMENTAL_GPU:-0}" = "1" ]; then
  CONFIGS="$CONFIGS dory-gpu.fragment"
fi

CONFIG_TARB64="$(COPYFILE_DISABLE=1 tar -czf - $CONFIGS | base64 | tr -d '\n')"

CID=""
cleanup() {
  if [ -n "$CID" ]; then
    docker rm -f "$CID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

CID="$(docker create --platform "$PLATFORM" \
  -e ARCH="$MAKE_ARCH" \
  -e DORY_KERNEL_ARCH="$ARCH" \
  -e DORY_KERNEL_CONFIGS="$CONFIGS" \
  -e DORY_KERNEL_CONFIG_TARB64="$CONFIG_TARB64" \
  -e DORY_KERNEL_TARGETS="$TARGETS" \
  -e DORY_KERNEL_GPU="${DORY_EXPERIMENTAL_GPU:-0}" \
  -w /build \
  debian:12-slim bash -euxc '
  set +x
  mkdir -p /tmp/dory-kernel-config
  printf "%s" "$DORY_KERNEL_CONFIG_TARB64" | base64 -d | tar -xzf - -C /tmp/dory-kernel-config
  set -x
  mkdir -p /out
  apt-get update
  apt-get install -y build-essential flex bison bc libssl-dev libelf-dev xz-utils zstd curl python3
  curl -fsSL '"$KERNEL_URL"' -o linux.tar.xz
  echo "'"$KERNEL_SHA256"'  linux.tar.xz" | sha256sum -c -
  tar xf linux.tar.xz --strip-components=1
  make defconfig
  CONFIG_PATHS=""
  for config in $DORY_KERNEL_CONFIGS; do
    CONFIG_PATHS="$CONFIG_PATHS /tmp/dory-kernel-config/$config"
  done
  scripts/kconfig/merge_config.sh -m .config $CONFIG_PATHS
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
')"

docker start -a "$CID"
docker cp "$CID:/out/." "$OUT/"
docker rm "$CID" >/dev/null
CID=""
trap - EXIT
