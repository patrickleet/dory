#!/bin/bash
# Sparkle replaces Dory.app; an update must therefore remain bootable before the first engine boot
# and retain every asset needed to create a new machine after the old bundle is gone.
set -euo pipefail

APP="${1:?usage: validate-app-update-payload.sh <Dory.app> [guest-architectures]}"
ARCHES="${2:-arm64 amd64}"
RESOURCES="$APP/Contents/Resources"
HELPERS="$APP/Contents/Helpers"
NETWORK_DAEMON_PLIST="$APP/Contents/Library/LaunchDaemons/dev.dory.network-helper.plist"

fail() {
  echo "app-update payload error: $*" >&2
  exit 1
}

[ -d "$RESOURCES" ] || fail "missing $RESOURCES"
[ -d "$HELPERS" ] || fail "missing $HELPERS"
for helper in \
  doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy dory-hv \
  gvproxy docker docker-buildx docker-compose kubectl dory dory-doctor; do
  [ -x "$HELPERS/$helper" ] || fail "missing executable helper $helper"
done
[ -s "$NETWORK_DAEMON_PLIST" ] || fail "missing privileged network daemon plist"
plutil -lint "$NETWORK_DAEMON_PLIST" >/dev/null \
  || fail "privileged network daemon plist is invalid"
[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$NETWORK_DAEMON_PLIST" 2>/dev/null)" = \
  "Contents/Helpers/dory-network-helper" ] \
  || fail "privileged network daemon BundleProgram does not reference the bundled helper"
[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:dev.dory.network-helper' "$NETWORK_DAEMON_PLIST" 2>/dev/null)" = \
  "true" ] \
  || fail "privileged network daemon Mach service is missing"
for arch in $ARCHES; do
  for relative in \
    "dory-agent-linux-$arch" \
    "dory-hv-kernel-$arch" \
    "dory-hv-kernel-$arch.lzfse" \
    "dory-engine-rootfs-$arch.ext4.lzfse" \
    "dory-machine-rootfs-$arch.ext4" \
    "dory-vm-kernel-$arch.lzfse" \
    "dory-vm-initfs-$arch.ext4.lzfse"; do
    [ -s "$RESOURCES/$relative" ] || fail "missing $relative for $arch"
  done
done

echo "verified self-contained app-update payload for:$ARCHES"
