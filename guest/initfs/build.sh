#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INITFS_DIR="$ROOT/guest/initfs"
OUT_DIR="$ROOT/guest/out"
CACHE_DIR="${DORY_INITFS_CACHE:-$ROOT/guest/.cache/initfs}"
PINS="$INITFS_DIR/PINS"
SIZE_MB="${DORY_INITFS_SIZE_MB:-1024}"

mkdir -p "$OUT_DIR" "$CACHE_DIR"

ACTIVE_STAGING=""
ACTIVE_ROOTFS=""
ACTIVE_LINK_TMP=""
cleanup_build() {
  [ -z "$ACTIVE_STAGING" ] || rm -rf "$ACTIVE_STAGING"
  [ -z "$ACTIVE_ROOTFS" ] || rm -rf "$ACTIVE_ROOTFS"
  [ -z "$ACTIVE_LINK_TMP" ] || rm -f "$ACTIVE_LINK_TMP"
}
trap cleanup_build EXIT

find_mke2fs() {
  for cand in "${DORY_MKE2FS:-}" \
              "$(command -v mke2fs 2>/dev/null || true)" \
              "$(command -v mkfs.ext4 2>/dev/null || true)" \
              "$HOME/Library/Android/sdk/platform-tools/mke2fs" \
              /opt/homebrew/opt/e2fsprogs/sbin/mke2fs \
              /usr/local/opt/e2fsprogs/sbin/mke2fs; do
    [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

pin_field() {
  local key="$1" field="$2"
  awk -v key="$key" -v field="$field" '
    $1 == key {
      if (field == "url") print $2
      else if (field == "sha256") print $3
      exit
    }
  ' "$PINS"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

fetch_pin() {
  local key="$1" url expected name path actual
  url="$(pin_field "$key" url)"
  expected="$(pin_field "$key" sha256)"
  [ -n "$url" ] && [ -n "$expected" ] || { echo "missing pin for $key" >&2; exit 1; }
  name="$(basename "$url")"
  path="$CACHE_DIR/$name"
  if [ ! -f "$path" ] || [ "$(sha256_file "$path")" != "$expected" ]; then
    rm -f "$path"
    curl -fL --retry 3 "$url" -o "$path"
  fi
  actual="$(sha256_file "$path")"
  [ "$actual" = "$expected" ] || { echo "sha256 mismatch for $name: expected $expected got $actual" >&2; exit 1; }
  printf '%s\n' "$path"
}

normalize_arch() {
  case "${1:-}" in
    arm64|aarch64) printf '%s\n' arm64 ;;
    amd64|x86_64) printf '%s\n' amd64 ;;
    *) echo "usage: guest/initfs/build.sh [arm64|amd64|all]" >&2; exit 2 ;;
  esac
}

rust_target_for_arch() {
  case "$1" in
    arm64) printf '%s\n' aarch64-unknown-linux-musl ;;
    amd64) printf '%s\n' x86_64-unknown-linux-musl ;;
  esac
}

linux_linker_for_target() {
  local target="$1" cand
  if command -v rust-lld >/dev/null 2>&1; then
    command -v rust-lld
    return 0
  fi
  case "$target" in
    aarch64-unknown-linux-musl)
      for cand in "${DORY_AARCH64_LINUX_MUSL_CC:-}" aarch64-linux-musl-gcc; do
        [ -n "$cand" ] && command -v "$cand" >/dev/null 2>&1 && { command -v "$cand"; return 0; }
      done
      zig_target="aarch64-linux-musl"
      ;;
    x86_64-unknown-linux-musl)
      for cand in "${DORY_X86_64_LINUX_MUSL_CC:-}" x86_64-linux-musl-gcc; do
        [ -n "$cand" ] && command -v "$cand" >/dev/null 2>&1 && { command -v "$cand"; return 0; }
      done
      zig_target="x86_64-linux-musl"
      ;;
    *)
      return 1
      ;;
  esac
  echo "no linker found for $target; install rust-lld or a ${target%-unknown-linux-musl}-linux-musl-gcc toolchain" >&2
  return 1
}

build_rust_agent() {
  local arch="$1" destination="$2" target agent linker env_name rustflags
  target="$(rust_target_for_arch "$arch")"
  linker="$(linux_linker_for_target "$target")"
  env_name="CARGO_TARGET_$(printf '%s' "$target" | tr '[:lower:]-' '[:upper:]_')_LINKER"
  rustflags="${RUSTFLAGS:-}"
  if [ "$(basename "$linker")" = "rust-lld" ]; then
    rustflags="$rustflags -C linker-flavor=ld.lld"
  fi
  rustup target add "$target" >/dev/null
  ( cd "$ROOT/dory-core" && env "$env_name=$linker" RUSTFLAGS="$rustflags" cargo build --locked -p dory-agent --release --target "$target" )
  agent="$ROOT/dory-core/target/$target/release/dory-agent"
  [ -x "$agent" ] || { echo "Rust dory-agent was not produced for $target" >&2; exit 1; }
  install -m0755 "$agent" "$destination"
}

extract_tar() {
  local tarball="$1" dest="$2"
  tar -xzf "$tarball" -C "$dest" --exclude './dev/*' --exclude 'dev/*'
}

install_docker_static() {
  local tarball="$1" dest="$2" tmp
  tmp="$(mktemp -d)"
  tar -xzf "$tarball" -C "$tmp"
  mkdir -p "$dest/usr/local/bin"
  for name in runc ctr containerd docker-proxy docker-init docker dockerd containerd-shim-runc-v2; do
    if [ -f "$tmp/docker/$name" ]; then
      install -m0755 "$tmp/docker/$name" "$dest/usr/local/bin/$name"
    fi
  done
  rm -rf "$tmp"
}

# crun is a single static ELF (no shared-lib deps); install it beside runc as dockerd's
# default-runtime. runc stays available so `docker run --runtime runc` still works.
install_crun() {
  local arch="$1" dest="$2" bin
  bin="$(fetch_pin "crun_${arch}")"
  mkdir -p "$dest/usr/local/bin"
  install -m0755 "$bin" "$dest/usr/local/bin/crun"
}

extract_apk() {
  local apk="$1" dest="$2"
  tar -xzf "$apk" -C "$dest" \
    --exclude '.SIGN*' \
    --exclude '.PKGINFO' \
    --exclude '.post-*' \
    --exclude '.pre-*'
}

install_ext4_tools() {
  local arch="$1" dest="$2" pkg apk
  for pkg in libeconf libuuid libcom_err libblkid e2fsprogs-libs e2fsprogs; do
    apk="$(fetch_pin "${pkg}_${arch}")"
    extract_apk "$apk" "$dest"
  done
}

# dockerd builds the default bridge's NAT/filter chains through the `iptables` userspace; without it
# it aborts at init ("iptables not found") and never serves. The apk ships /usr/sbin/iptables ->
# xtables-nft-multi (nft backend) plus its libmnl/libnftnl deps. Deps first so the symlinks resolve.
install_iptables() {
  local arch="$1" dest="$2" pkg apk
  for pkg in libmnl libnftnl libxtables iptables; do
    apk="$(fetch_pin "${pkg}_${arch}")"
    extract_apk "$apk" "$dest"
  done
}

write_runtime_files() {
  local rootfs="$1" agent="$2"
  mkdir -p "$rootfs"/{dev,proc,sys,run,tmp,var/log,var/run,var/lib/docker,usr/bin,usr/local/bin,etc,sbin}
  rm -f "$rootfs/sbin/init"
  cp "$INITFS_DIR/init" "$rootfs/sbin/init"
  chmod 0755 "$rootfs/sbin/init"
  if [ -x "$agent" ]; then
    install -m0755 "$agent" "$rootfs/usr/bin/dory-agent"
  else
    echo "WARNING: $agent not found; guest/initfs/build.sh should have built the Rust dory-agent" >&2
  fi
  cat > "$rootfs/etc/resolv.conf" <<'EOF'
nameserver 192.168.127.1
nameserver 1.1.1.1
EOF
  cat > "$rootfs/etc/hostname" <<'EOF'
dory-engine
EOF
}

build_arch() {
  local arch="$1" alpine_key docker_key alpine_tar docker_tar rootfs image mke2fs
  local input_fingerprint final_fingerprint agent final_agent final_image final_stamp stamp stamp_tmp staging
  if [ "${DORY_INITFS_SKIP_RUST_AGENT_BUILD:-0}" = "1" ]; then
    echo "DORY_INITFS_SKIP_RUST_AGENT_BUILD cannot produce a provenance-verified initfs; use a DORY_INITFS_* release override together with DORY_ALLOW_UNVERIFIED_GUEST_ASSETS=1 for an explicit development-only escape" >&2
    exit 64
  fi
  input_fingerprint="$($INITFS_DIR/input-fingerprint.sh "$arch")"
  staging="$(mktemp -d "$OUT_DIR/.initfs-build-$arch.XXXXXX")"
  ACTIVE_STAGING="$staging"
  agent="$staging/dory-agent-$arch"
  image="$staging/initfs-$arch.ext4"
  build_rust_agent "$arch" "$agent"
  alpine_key="alpine_$arch"
  docker_key="docker_$arch"
  alpine_tar="$(fetch_pin "$alpine_key")"
  docker_tar="$(fetch_pin "$docker_key")"
  rootfs="$(mktemp -d)"
  ACTIVE_ROOTFS="$rootfs"
  mke2fs="$(find_mke2fs)" || { echo "mke2fs not found; install e2fsprogs or Android platform-tools" >&2; exit 1; }

  extract_tar "$alpine_tar" "$rootfs"
  install_ext4_tools "$arch" "$rootfs"
  install_iptables "$arch" "$rootfs"
  install_docker_static "$docker_tar" "$rootfs"
  install_crun "$arch" "$rootfs"
  write_runtime_files "$rootfs" "$agent"

  truncate -s "${SIZE_MB}m" "$image"
  "$mke2fs" -q -F -t ext4 -L dory-initfs -d "$rootfs" "$image"
  rm -rf "$rootfs"
  ACTIVE_ROOTFS=""
  final_fingerprint="$($INITFS_DIR/input-fingerprint.sh "$arch")"
  [ "$final_fingerprint" = "$input_fingerprint" ] || {
    echo "initfs inputs changed during the $arch build; refusing to publish a mixed-source artifact" >&2
    exit 1
  }
  final_agent="$OUT_DIR/dory-agent-$arch"
  final_image="$OUT_DIR/initfs-$arch.ext4"
  stamp="$staging/initfs-build-$arch.stamp"
  final_stamp="$OUT_DIR/initfs-build-$arch.stamp"
  stamp_tmp="$(mktemp "$staging/.initfs-build-$arch.XXXXXX")"
  {
    printf 'schema=2\narch=%s\ninput_sha256=%s\n' "$arch" "$input_fingerprint"
    printf 'agent_sha256=%s\n' "$(sha256_file "$agent")"
    printf 'image_sha256=%s\n' "$(sha256_file "$image")"
  } > "$stamp_tmp"
  mv -f "$stamp_tmp" "$stamp"
  DORY_INITFS_OUT_DIR="$staging" "$INITFS_DIR/verify-build.sh" "$arch"
  # Publish each immutable artifact with a same-filesystem rename, and the stamp last. A concurrent
  # verifier can see the old valid set or fail closed during the two-renames window; it can never
  # accept a new artifact under an old stamp.
  mv -f "$agent" "$final_agent"
  mv -f "$image" "$final_image"
  mv -f "$stamp" "$final_stamp"
  rmdir "$staging"
  ACTIVE_STAGING=""
  if [ "$arch" = arm64 ]; then
    ACTIVE_LINK_TMP="$OUT_DIR/.dory-agent-link-$$"
    ln -sfn dory-agent-arm64 "$ACTIVE_LINK_TMP"
    mv -f "$ACTIVE_LINK_TMP" "$OUT_DIR/dory-agent"
    ACTIVE_LINK_TMP=""
  fi
  "$INITFS_DIR/verify-build.sh" "$arch"
  echo "built $final_image ($(du -h "$final_image" | awk '{print $1}'))"
}

case "${1:-all}" in
  all)
    build_arch arm64
    build_arch amd64
    ;;
  *)
    build_arch "$(normalize_arch "$1")"
    ;;
esac
