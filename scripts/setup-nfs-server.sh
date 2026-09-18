#!/usr/bin/env bash
# Turn k8s-nfs into an NFS server for the cluster. Run as root ON k8s-nfs (10.10.0.20) — this
# node is deliberately outside the Kubernetes cluster (see PROJECT-PLAN.md architecture).
set -euo pipefail

EXPORT_PATH="${EXPORT_PATH:-/srv/nfs/k8s}"
VLAN_CIDR="${VLAN_CIDR:-10.10.0.0/24}"

echo "== Installing nfs-kernel-server"
apt-get update -qq
apt-get install -y -qq nfs-kernel-server

echo "== Export directory: $EXPORT_PATH"
mkdir -p "$EXPORT_PATH"
chown nobody:nogroup "$EXPORT_PATH"
chmod 777 "$EXPORT_PATH"   # lab-only — a real deployment would scope this far tighter

echo "== Configuring /etc/exports"
grep -q "$EXPORT_PATH" /etc/exports 2>/dev/null || \
  echo "$EXPORT_PATH $VLAN_CIDR(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
# no_root_squash matters here: without it, root on an NFS client (including the provisioner pod
# and kubelet's fsGroup-based chown at mount time) gets mapped to "nobody" and permission fixups
# silently fail — Postgres then can't write to its data directory. A common, confusing gotcha if
# you don't know to look for it.

exportfs -ra
systemctl enable --now nfs-kernel-server

echo
echo "== Exports:"
exportfs -v
echo
echo "Server ready at 10.10.0.20:${EXPORT_PATH}. VLAN firewall already allows all traffic on"
echo "10.10.0.0/24, so no additional firewall changes are needed for NFS (port 2049)."
