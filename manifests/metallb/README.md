# MetalLB — Stage 2

MetalLB isn't a raw manifest you hand-edit like Calico's CR — install it via its own release
manifest or Helm chart first, then apply the two CRs in this directory.

```bash
# pick the current stable tag: https://github.com/metallb/metallb/releases
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.0/config/manifests/metallb-native.yaml
kubectl wait --namespace metallb-system \
  --for=condition=ready pod --selector=app=metallb --timeout=90s

kubectl apply -f manifests/metallb/ipaddresspool.yaml
kubectl apply -f manifests/metallb/l2advertisement.yaml
```

`ipaddresspool.yaml` carves out `10.10.0.100-10.10.0.120` from the VLAN — unused addresses in the
`10.10.0.0/24` block that don't collide with the four node addresses (`.10`, `.11`, `.12`, `.20`).
`l2advertisement.yaml` is what makes this L2 mode: MetalLB will ARP for the assigned IP directly on
the VLAN interface, which is the same mechanism it'd use on a real rack switch — no cloud API
involved. That's the point of this stage.
