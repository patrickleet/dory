#!/bin/bash
# Dory — one-click(ish) local Kubernetes via k3s inside an Apple `container` Linux machine.
# Boots infrastructure and writes ~/.kube/config; review before running. Needs admin for ports.
#
# Undo:
#   container machine run -n dory-k8s -- sh -c '/usr/local/bin/k3s-uninstall.sh' || true
#   container machine delete dory-k8s
set -euo pipefail

CONTAINER_BIN="$(command -v container || echo /opt/homebrew/bin/container)"
MACHINE="dory-k8s"

echo "==> Creating Linux machine '$MACHINE' (if absent)…"
if ! "$CONTAINER_BIN" machine ls --format json 2>/dev/null | grep -q "\"$MACHINE\""; then
  "$CONTAINER_BIN" machine create ubuntu:24.04 --name "$MACHINE"
fi

echo "==> Installing k3s inside the machine…"
"$CONTAINER_BIN" machine run -n "$MACHINE" -- sh -c 'curl -sfL https://get.k3s.io | sh -'

echo "==> Exporting kubeconfig to ~/.kube/dory-config…"
MACHINE_IP="$("$CONTAINER_BIN" machine ls --format json | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["ipAddress"])')"
mkdir -p "$HOME/.kube"
KUBECONFIG_PATH="$HOME/.kube/dory-config"
"$CONTAINER_BIN" machine run -n "$MACHINE" -- cat /etc/rancher/k3s/k3s.yaml \
  | sed "s/127.0.0.1/$MACHINE_IP/" > "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

echo "Done. Dory's Kubernetes screen will show live pods."
echo "For kubectl on the command line, point it at the Dory kubeconfig (this never touches your default ~/.kube/config):"
echo "    export KUBECONFIG=\"$KUBECONFIG_PATH\""
echo "    kubectl get pods -A"
