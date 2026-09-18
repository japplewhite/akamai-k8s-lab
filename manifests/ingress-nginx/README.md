# ingress-nginx — Stage 2

Installed from the upstream "cloud" provider manifest — its Service is `type: LoadBalancer` by
default, which is exactly what makes it interesting here: with no cloud provider present, that
Service would normally sit `<pending>` forever. **MetalLB** is what actually satisfies it, handing
out an IP from the pool in `manifests/metallb/ipaddresspool.yaml` and ARPing for it on the VLAN.
That handoff — MetalLB fulfilling a stock `LoadBalancer` Service with no cloud API involved — is
the thing worth being able to explain out loud.

```bash
# pick the current stable tag: https://github.com/kubernetes/ingress-nginx/releases
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=120s

kubectl get svc -n ingress-nginx ingress-nginx-controller
```

The `EXTERNAL-IP` column should show an address from the MetalLB pool (`10.10.0.100-.120`), not
`<pending>`. If it stays pending, MetalLB isn't installed yet or its `L2Advertisement` isn't
applied — check `manifests/metallb/README.md` first.
