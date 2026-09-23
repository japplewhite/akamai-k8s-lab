#!/usr/bin/env bash
# Prepare an Ubuntu node to be a kubeadm control-plane or worker node.
#
# READ THIS FIRST: do these steps BY HAND on the first node before you run this script anywhere.
# Stage 1 of PROJECT-PLAN.md is the highest-value stage in the plan, and its value comes from
# having typed these commands and seen what each one is for. Use this script for nodes 2-4, and
# as a reference afterward.
#
# Run as root on each node.  Usage:  K8S_MINOR=1.xx ./node-prep.sh
set -euo pipefail

# Deliberately install ONE MINOR VERSION BEHIND current stable, so Stage 5 has a real upgrade
# to perform. Check what's current: https://kubernetes.io/releases/ and https://pkgs.k8s.io
: "${K8S_MINOR:?Set K8S_MINOR, e.g. K8S_MINOR=1.34 (one minor behind current stable)}"

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

echo "== Swap off (the kubelet refuses to start with swap enabled by default)"
swapoff -a
sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

echo "== Kernel modules: overlay (containerd storage), br_netfilter (bridged traffic to iptables)"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "== sysctl: let iptables see bridged traffic, and enable forwarding for pod routing"
cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "== containerd (no docker here) + nfs-common"
apt-get update -qq
apt-get install -y -qq containerd nfs-common apt-transport-https ca-certificates curl gpg
# nfs-common provides mount.nfs — without it, kubelet's NFS volume mounts fail with a cryptic
# "bad option; you might need a /sbin/mount.<type> helper program" error on any pod using an
# NFS-backed PV, with no indication the real problem is a missing package on the node.
#
# crictl (cri-tools) is installed further down, AFTER the pkgs.k8s.io repo is configured — it's
# NOT an Ubuntu package (not in main/universe/multiverse/backports), it ships from the same
# Kubernetes community repo as kubelet/kubeadm/kubectl. Installing it here, before that repo
# exists, fails with "E: Unable to locate package cri-tools" on any node that hasn't already had
# the repo configured some other way.

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
# The single most common bootstrap failure: kubelet uses the systemd cgroup driver, and if
# containerd doesn't match, the kubelet flaps and pods never stabilize.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || {
  echo "SystemdCgroup not set — containerd config format may have changed, fix by hand." >&2
  exit 1
}
systemctl restart containerd
systemctl enable containerd

echo "== kubelet, kubeadm, kubectl, crictl (v${K8S_MINOR})"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
# --batch --yes: without it, gpg interactively prompts "Overwrite?" on any re-run where the
# keyring file already exists — which silently eats whatever shell input comes next instead of
# just overwriting, a nasty one to debug from a pasted multi-line block.
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl cri-tools
# Hold them: an unplanned apt upgrade of these packages is how clusters break at 3am.
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet   # it will crashloop until kubeadm init/join runs — that's expected

echo
echo "== Ready. Versions:"
kubeadm version -o short
containerd --version
echo
cat <<EOF
Next:
  Control plane — bind the API server to the VLAN address, and match the pod CIDR to Calico:
    kubeadm init --apiserver-advertise-address=10.10.0.10 --pod-network-cidr=192.168.0.0/16

  Then install Calico, then join the workers with the printed join command.
  Join tokens expire in 24h — regenerate with: kubeadm token create --print-join-command
EOF
