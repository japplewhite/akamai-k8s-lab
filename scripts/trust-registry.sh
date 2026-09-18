#!/usr/bin/env bash
# Make ONE cluster node (cp1, w1, or w2) trust and resolve the private registry on k8s-nfs.
# Run as root. Expects ca.crt already copied to this node (see runbook stage4).
set -euo pipefail

REGISTRY_HOST="${REGISTRY_HOST:-k8s-nfs}"
REGISTRY_IP="${REGISTRY_IP:-10.10.0.20}"
CA_SRC="${CA_SRC:-$HOME/ca.crt}"

[[ -f "$CA_SRC" ]] || { echo "Expected CA cert at $CA_SRC — scp it from k8s-nfs first." >&2; exit 1; }

echo "== /etc/hosts entry so '${REGISTRY_HOST}:5000' resolves to the VLAN address"
grep -q "$REGISTRY_HOST" /etc/hosts || echo "${REGISTRY_IP} ${REGISTRY_HOST}" >> /etc/hosts

HOSTS_DIR="/etc/containerd/certs.d/${REGISTRY_HOST}:5000"
mkdir -p "$HOSTS_DIR"
cp "$CA_SRC" "$HOSTS_DIR/ca.crt"

cat > "$HOSTS_DIR/hosts.toml" <<EOF
server = "https://${REGISTRY_HOST}:5000"

[host."https://${REGISTRY_HOST}:5000"]
  capabilities = ["pull", "resolve", "push"]
  ca = "${HOSTS_DIR}/ca.crt"
EOF

echo
echo "== Wrote ${HOSTS_DIR}/hosts.toml — this covers TLS trust and routing ONLY."
echo "   It does NOT carry credentials. Pod pulls need a Kubernetes imagePullSecret;"
echo "   manual 'crictl pull' needs --creds user:pass on the command line."
echo
echo "REMAINING MANUAL STEP: confirm /etc/containerd/config.toml has the CRI registry plugin's"
echo "config_path pointed at /etc/containerd/certs.d, then restart containerd. The exact plugin"
echo "key name has moved across containerd versions, so check what THIS node's install actually"
echo "uses rather than assuming — see stage4-registry-helm.md for the exact command."
