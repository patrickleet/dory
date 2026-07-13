#!/bin/bash
# Creates the checksummed, SSH-signed manifest consumed by `dory machine create` custom images.
set -euo pipefail

KERNEL=""
ROOTFS=""
KEY=""
SIGNER=""
OUTPUT=""

usage() {
  cat <<'EOF'
Usage: scripts/sign-machine-image-manifest.sh \
  --kernel PATH --rootfs PATH --key SSH_PRIVATE_KEY --signer ID --output manifest.json

Outputs:
  manifest.json                 canonical SHA-256 manifest
  manifest.json.sig             detached OpenSSH signature (namespace dory-machine-image)
  manifest.json.allowed_signers one-entry trust file for local verification

Keep the private key outside the image directory. Review and distribute the manifest, signature,
and allowed-signers policy through a trusted channel; the large kernel/rootfs files may travel via
an ordinary artifact store because Dory verifies their exact signed digests before machine create.
EOF
}

die() { echo "machine-image-sign: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kernel) need_value "$1" "$#"; KERNEL="$2"; shift 2 ;;
    --rootfs) need_value "$1" "$#"; ROOTFS="$2"; shift 2 ;;
    --key) need_value "$1" "$#"; KEY="$2"; shift 2 ;;
    --signer) need_value "$1" "$#"; SIGNER="$2"; shift 2 ;;
    --output) need_value "$1" "$#"; OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -f "$KERNEL" ] || die "kernel not found: $KERNEL"
[ -f "$ROOTFS" ] || die "rootfs not found: $ROOTFS"
[ -f "$KEY" ] || die "SSH private key not found: $KEY"
[ -n "$SIGNER" ] || die "--signer is required"
[ -n "$OUTPUT" ] || die "--output is required"
case "$SIGNER" in *[!A-Za-z0-9_.@+-]*) die "signer contains unsupported characters" ;; esac
command -v ssh-keygen >/dev/null || die "ssh-keygen is required"
command -v shasum >/dev/null || die "shasum is required"
command -v python3 >/dev/null || die "python3 is required"
[ ! -e "$OUTPUT" ] && [ ! -e "$OUTPUT.sig" ] && [ ! -e "$OUTPUT.allowed_signers" ] \
  || die "refusing to overwrite an existing manifest/signature/policy"
mkdir -p "$(dirname "$OUTPUT")"

kernel_sha="$(shasum -a 256 "$KERNEL" | awk '{print $1}')"
rootfs_sha="$(shasum -a 256 "$ROOTFS" | awk '{print $1}')"
python3 - "$OUTPUT" "$kernel_sha" "$rootfs_sha" <<'PY'
import json, sys
path, kernel, rootfs = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "schema": "dev.dory.machine-image",
        "version": 1,
        "kernel": {"sha256": kernel},
        "rootfs": {"sha256": rootfs},
    }, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
ssh-keygen -Y sign -f "$KEY" -n dory-machine-image "$OUTPUT" >/dev/null
public_key="$(ssh-keygen -y -f "$KEY")"
printf '%s %s\n' "$SIGNER" "$public_key" > "$OUTPUT.allowed_signers"
ssh-keygen -Y verify -f "$OUTPUT.allowed_signers" -I "$SIGNER" -n dory-machine-image \
  -s "$OUTPUT.sig" < "$OUTPUT" >/dev/null
echo "signed machine image manifest: $OUTPUT"
