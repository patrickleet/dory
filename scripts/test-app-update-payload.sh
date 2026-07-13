#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-update-payload.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/Dory.app"
RESOURCES="$APP/Contents/Resources"
HELPERS="$APP/Contents/Helpers"
NETWORK_DAEMON_DIR="$APP/Contents/Library/LaunchDaemons"
NETWORK_DAEMON_PLIST="$NETWORK_DAEMON_DIR/dev.dory.network-helper.plist"
mkdir -p "$RESOURCES" "$HELPERS" "$NETWORK_DAEMON_DIR"
cp Config/dev.dory.network-helper.plist "$NETWORK_DAEMON_PLIST"

ASSETS=(
  dory-agent-linux-arm64
  dory-hv-kernel-arm64
  dory-hv-kernel-arm64.lzfse
  dory-engine-rootfs-arm64.ext4.lzfse
  dory-machine-rootfs-arm64.ext4
  dory-vm-kernel-arm64.lzfse
  dory-vm-initfs-arm64.ext4.lzfse
)
for asset in "${ASSETS[@]}"; do
  printf 'fixture\n' > "$RESOURCES/$asset"
done

HELPER_ASSETS=(
  doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy dory-hv
  gvproxy docker docker-buildx docker-compose kubectl dory dory-doctor
)
for helper in "${HELPER_ASSETS[@]}"; do
  printf '#!/bin/sh\nexit 0\n' > "$HELPERS/$helper"
  chmod 0755 "$HELPERS/$helper"
done

scripts/validate-app-update-payload.sh "$APP" arm64 >/dev/null
for asset in "${ASSETS[@]}"; do
  rm "$RESOURCES/$asset"
  if scripts/validate-app-update-payload.sh "$APP" arm64 >/dev/null 2>&1; then
    echo "app-update payload test failed: missing $asset was accepted" >&2
    exit 1
  fi
  printf 'fixture\n' > "$RESOURCES/$asset"
done
for helper in "${HELPER_ASSETS[@]}"; do
  rm "$HELPERS/$helper"
  if scripts/validate-app-update-payload.sh "$APP" arm64 >/dev/null 2>&1; then
    echo "app-update payload test failed: missing $helper was accepted" >&2
    exit 1
  fi
  printf '#!/bin/sh\nexit 0\n' > "$HELPERS/$helper"
  chmod 0755 "$HELPERS/$helper"
done

rm "$NETWORK_DAEMON_PLIST"
if scripts/validate-app-update-payload.sh "$APP" arm64 >/dev/null 2>&1; then
  echo "app-update payload test failed: missing privileged network daemon plist was accepted" >&2
  exit 1
fi
cp Config/dev.dory.network-helper.plist "$NETWORK_DAEMON_PLIST"

cp "$NETWORK_DAEMON_PLIST" "$TMP/network-helper.plist"
/usr/libexec/PlistBuddy -c 'Set :BundleProgram Contents/Helpers/not-dory-network-helper' "$NETWORK_DAEMON_PLIST"
if scripts/validate-app-update-payload.sh "$APP" arm64 >/dev/null 2>&1; then
  echo "app-update payload test failed: invalid privileged network daemon BundleProgram was accepted" >&2
  exit 1
fi
cp "$TMP/network-helper.plist" "$NETWORK_DAEMON_PLIST"

echo "app-update payload tests passed"
