#!/usr/bin/env bash
# Tear down every lab node. The VLAN disappears on its own once nothing is attached.
# Rebuilding from zero is the point — do it a few times, it's how you know the build is real.
set -euo pipefail

PREFIX="${PREFIX:-k8s}"

# Note: no mapfile / readarray here — macOS still ships bash 3.2.
IDS=""
while read -r id label; do
  IDS="${IDS}${id} ${label}"$'\n'
done < <(linode-cli linodes list --text --no-headers --format "id,label" \
  | awk -v p="^${PREFIX}-" '$2 ~ p {print $1, $2}')

[ -n "$IDS" ] || { echo "No linodes matching ${PREFIX}-*"; exit 0; }

printf '%s' "$IDS"
count=$(printf '%s' "$IDS" | grep -c .)
printf 'Delete these %s linodes? [y/N] ' "$count"
read -r ans
[ "$ans" = "y" ] || exit 0

printf '%s' "$IDS" | while read -r id label; do
  echo "Deleting $label ($id)"
  linode-cli linodes delete "$id"
done
