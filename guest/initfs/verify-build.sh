#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

case "${1:-arm64}" in
  arm64|aarch64) ARCH=arm64 ;;
  amd64|x86_64) ARCH=amd64 ;;
  *) echo "usage: $0 [arm64|amd64]" >&2; exit 64 ;;
esac

OUT="${DORY_INITFS_OUT_DIR:-guest/out}"
AGENT="$OUT/dory-agent-$ARCH"
IMAGE="$OUT/initfs-$ARCH.ext4"
STAMP="$OUT/initfs-build-$ARCH.stamp"

fail() {
  echo "initfs verification failed: $*" >&2
  exit 1
}

stamp_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STAMP"
}

find_debugfs() {
  local candidate
  for candidate in \
    "$(command -v debugfs 2>/dev/null || true)" \
    /opt/homebrew/opt/e2fsprogs/sbin/debugfs \
    /usr/local/opt/e2fsprogs/sbin/debugfs; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

for path in "$AGENT" "$IMAGE" "$STAMP"; do
  [ -s "$path" ] || fail "missing or empty $path; rebuild with guest/initfs/build.sh $ARCH"
done

EXPECTED_INPUT="$(guest/initfs/input-fingerprint.sh "$ARCH")"
[ "$(stamp_value schema)" = "2" ] || fail "$STAMP has an unsupported schema"
[ "$(stamp_value arch)" = "$ARCH" ] || fail "$STAMP was built for another architecture"
[ "$(stamp_value input_sha256)" = "$EXPECTED_INPUT" ] \
  || fail "$IMAGE is stale relative to the current initfs/guest-agent sources"
[ "$(stamp_value agent_sha256)" = "$(shasum -a 256 "$AGENT" | awk '{print $1}')" ] \
  || fail "$AGENT does not match its build stamp"
[ "$(stamp_value image_sha256)" = "$(shasum -a 256 "$IMAGE" | awk '{print $1}')" ] \
  || fail "$IMAGE does not match its build stamp"

file "$AGENT" | grep -q 'ELF 64-bit' || fail "$AGENT is not a 64-bit Linux ELF binary"
case "$ARCH" in
  arm64) file "$AGENT" | grep -Eq 'ARM aarch64|arm64' || fail "$AGENT is not arm64" ;;
  amd64) file "$AGENT" | grep -Eq 'x86-64|x86_64' || fail "$AGENT is not amd64" ;;
esac

DEBUGFS="$(find_debugfs)" || fail "debugfs is required to validate the initfs contents (install e2fsprogs)"
for required in \
  /bin/sh \
  /sbin/init \
  /usr/bin/dory-agent \
  /usr/local/bin/containerd \
  /usr/local/bin/crun \
  /usr/local/bin/docker \
  /usr/local/bin/dockerd \
  /usr/local/bin/runc \
  /usr/sbin/iptables; do
  "$DEBUGFS" -R "stat $required" "$IMAGE" 2>&1 | grep -q '^Inode:' \
    || fail "$IMAGE is missing required guest path $required"
done

AGENT_DUMP="$(mktemp /tmp/dory-agent-verify.XXXXXX)"
cleanup() {
  rm -f "$AGENT_DUMP"
}
trap cleanup EXIT
"$DEBUGFS" -R "dump /usr/bin/dory-agent $AGENT_DUMP" "$IMAGE" >/dev/null 2>&1 \
  || fail "could not extract /usr/bin/dory-agent from $IMAGE"
[ "$(shasum -a 256 "$AGENT_DUMP" | awk '{print $1}')" = "$(shasum -a 256 "$AGENT" | awk '{print $1}')" ] \
  || fail "$IMAGE embeds a different dory-agent than $AGENT"

echo "verified $ARCH initfs input fingerprint $EXPECTED_INPUT"
