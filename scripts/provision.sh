#!/usr/bin/env bash
# Provision the lab cluster on Akamai Cloud (Linode).
#
# VLAN interface syntax validated 2026-09-03 against linode-cli v5.68.0 (spec 4.229.1) with a
# live disposable test node in us-iad: --interface_generation must be set explicitly to
# "legacy_config" (the account/region also supports the newer "Linode Interfaces" model, which
# uses different nested --interfaces.vlan.* flags — legacy_config is what the flat flags below
# match). Re-verify with `linode-cli linodes create --help` if this stops working after a CLI
# upgrade.
#
# Prereqs:  brew install linode-cli && linode-cli configure
set -euo pipefail

REGION="${REGION:-us-iad}"
IMAGE="${IMAGE:-linode/ubuntu24.04}"     # verify: linode-cli images list
VLAN_LABEL="${VLAN_LABEL:-k8slab}"
VLAN_CIDR="${VLAN_CIDR:-24}"
SSH_PUB="${SSH_PUB:-$HOME/.ssh/id_ed25519.pub}"
PREFIX="${PREFIX:-k8s}"

# node label : linode type : VLAN address
NODES=(
  "cp1:g6-standard-2:10.10.0.10"
  "w1:g6-standard-1:10.10.0.11"
  "w2:g6-standard-1:10.10.0.12"
  "nfs:g6-nanode-1:10.10.0.20"
)

[[ -f "$SSH_PUB" ]] || { echo "No SSH public key at $SSH_PUB — set SSH_PUB." >&2; exit 1; }
command -v linode-cli >/dev/null || { echo "linode-cli not installed." >&2; exit 1; }

PUBKEY="$(cat "$SSH_PUB")"
# `|| true` neutralizes the SIGPIPE tr gets when head closes the pipe after 32 bytes —
# under `set -o pipefail` that 141 would otherwise propagate through $(...) and kill the script.
ROOT_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^_+=' </dev/urandom | head -c 32 || true)"
echo "Generated root password (SSH key auth is what you'll actually use): $ROOT_PASS"

for entry in "${NODES[@]}"; do
  IFS=: read -r name type vlan_ip <<<"$entry"
  label="${PREFIX}-${name}"

  existing="$(linode-cli linodes list --label "$label" --text --no-headers 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    echo "== $label already exists, skipping"
    continue
  fi

  echo "== Creating $label ($type, VLAN ${vlan_ip}/${VLAN_CIDR})"
  linode-cli linodes create \
    --label "$label" \
    --type "$type" \
    --region "$REGION" \
    --image "$IMAGE" \
    --root_pass "$ROOT_PASS" \
    --authorized_keys "$PUBKEY" \
    --interface_generation legacy_config \
    --interfaces.purpose public \
    --interfaces.purpose vlan \
    --interfaces.label "$VLAN_LABEL" \
    --interfaces.ipam_address "${vlan_ip}/${VLAN_CIDR}" \
    --tags "$PREFIX" \
    --text --no-headers
done

echo
echo "== Nodes"
linode-cli linodes list --text --format "label,status,ipv4,type" | grep -E "label|$PREFIX"

cat <<'EOF'

NEXT — do this before anything else (see PROJECT-PLAN.md, "two notes that will bite otherwise"):

  Attach a Cloud Firewall to all four nodes:
    - Inbound policy: DROP
    - Allow TCP 22 from YOUR_IP/32 only
    - Allow ALL from 10.10.0.0/24 (the VLAN — all cluster traffic rides this)
    - Outbound policy: ACCEPT

  The linode-cli syntax for firewall rules is JSON-in-a-flag and fiddly; doing this once in
  Cloud Manager takes two minutes and is not the skill being tested. Automate it later if you
  want. Do not skip it — an exposed 6443 or 10250 is found by scanners within hours.

Then, on each node:  scripts/node-prep.sh
EOF
