# Runbook — Networking with No Cloud LB (Stage 2)

MetalLB (L2 mode over the VLAN) + ingress-nginx + a NetworkPolicy default-deny drill. Run
everything from `~/akamai-k8s-lab` on your Mac unless a step says otherwise — manifests get copied
to cp1 with `scp` the same way Calico's did in Stage 1.

Fill in `[ ]` and `RESULT:` as you go, same as Stage 1.

---

## 1. Install MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.0/config/manifests/metallb-native.yaml
kubectl wait --namespace metallb-system \
  --for=condition=ready pod --selector=app=metallb --timeout=90s
```

Copy the pool/advertisement CRs over and apply:

```bash
# from your Mac
scp manifests/metallb/ipaddresspool.yaml manifests/metallb/l2advertisement.yaml root@139.144.223.215:~/
# on cp1
kubectl apply -f ipaddresspool.yaml -f l2advertisement.yaml
kubectl get ipaddresspool,l2advertisement -n metallb-system
```

- [X] all `metallb-system` pods `Running`
- [X] `IPAddressPool` and `L2Advertisement` both show up

RESULT: ______success_________

## 2. Install ingress-nginx

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=120s
kubectl get svc -n ingress-nginx ingress-nginx-controller
```

**The important thing to watch here:** the Service is `type: LoadBalancer`. With no cloud provider,
that would normally sit `EXTERNAL-IP: <pending>` forever — MetalLB is what actually assigns it an
address from the pool (`10.10.0.100-.120`) and ARPs for it on the VLAN. Write down the IP you get:

RESULT (ingress external IP): ______10.10.0.100_________

- [ ] `EXTERNAL-IP` is a real address, not `<pending>`

If it stays `<pending>`, MetalLB's `L2Advertisement` isn't attached to the pool, or `speaker` pods
aren't running — check `kubectl get pods -n metallb-system` before anything else.

## 3. Deploy the two demo apps + Ingress

```bash
scp manifests/ingress-nginx/demo-apps.yaml root@139.144.223.215:~/
# on cp1
kubectl apply -f demo-apps.yaml
kubectl get pods -n demo
```

Test both hostnames through the one ingress IP (replace `<INGRESS_IP>` with what you wrote down
above — run this from cp1, or add both host entries to your Mac's `/etc/hosts` to test from your
laptop instead):

```bash
curl -H "Host: app-a.lab.local" http://<INGRESS_IP>/hostname
curl -H "Host: app-b.lab.local" http://<INGRESS_IP>/hostname
```

Use `/hostname`, not `/` — the root path on `agnhost netexec` just returns a timestamp (`NOW:
...`), which is identical either way and proves nothing about routing. `/hostname` returns the
actual pod name, so you should see two **different** pod names (`app-a-...` vs `app-b-...`) — that
difference is the actual proof the host-based routing is differentiating, not just hitting
whichever pod first.

- [X] both hostnames route to their own app through the same ingress IP

root@k8s-cp1:~# curl -H "Host: app-a.lab.local" http://10.10.0.100/hostname
app-a-b8d8b9c9d-tgpmvroot@k8s-cp1:~#
root@k8s-cp1:~#
root@k8s-cp1:~# curl -H "Host: app-b.lab.local" http://10.10.0.100/hostname
app-b-84b54865c4-rrbrlroot@k8s-cp1:~#
root@k8s-cp1:~#

## 4. Break it on purpose: default-deny

```bash
scp manifests/ingress-nginx/network-policy.yaml root@139.144.223.215:~/
# on cp1, apply ONLY the first policy first — comment out or split the file if you want to be
# strict about it, or just apply the whole file and watch it self-heal (steps happen fast):
kubectl apply -f network-policy.yaml
```

Immediately re-run the two `curl` commands from step 3.

- [ ] before the `allow-from-ingress-controller` policy takes effect (or if you commented it out),
      both curls hang or fail — **that's the point**, default-deny is working
- [ ] once all three policies are applied, both curls succeed again

RESULT: ____there was a lag but it eventually stabilizes___________

## 5. Prove the deny is real, not just "ingress happens to still work"

Drop a debug pod into the `demo` namespace that is **not** `app-a`, and confirm it can reach
`app-a`'s Service (no policy protects app-a→anything, this is a sanity check) but **cannot** reach
`app-b` on port 8080 (only `app-a` is allowed in):

```bash
kubectl run netpol-test -n demo --rm -it --image=busybox:1.36 --restart=Never -- sh
```
Inside:
```sh
wget -qO- --timeout=3 http://app-b.demo.svc.cluster.local/ ; echo "exit: $?"
```

- [ timed out] this **times out / fails** — a non-`app-a` pod cannot reach `app-b`

If it succeeds instead, the `allow-app-a-to-app-b` policy's `podSelector` isn't scoped as tightly
as it looks — go re-read it rather than assuming the test pod is wrong.

RESULT: _______________

## 6. Break CoreDNS on purpose

Pick one, on any node:

```bash
# Option A: scale CoreDNS to zero and watch what fails
kubectl scale deployment coredns -n kube-system --replicas=0
```

Re-run a `nslookup` from a debug pod (fully-qualified name, per the Stage 1 note on BusyBox's
resolver) and confirm it now fails outright — then:

```bash
kubectl scale deployment coredns -n kube-system --replicas=2
```

and confirm it recovers within a few seconds once both replicas are `Running` again.

- [X ] DNS fails while CoreDNS is scaled to 0
- [ X] DNS recovers once scaled back up

RESULT: _nslookup: write to '10.96.0.10': Connection refused
;; connection timed out; no servers could be reached______________

---

**Proof for this stage (per PROJECT-PLAN.md):** two apps reachable by hostname through one ingress
IP; NetworkPolicy blocking cross-namespace/cross-app traffic that isn't explicitly allowed, proven
with both a positive and a negative test.

**Interview answer this stage buys you:** the actual MetalLB→ingress-nginx→Service→Pod chain, in
your own words, plus a first-hand default-deny NetworkPolicy story with a real negative test —
most candidates can describe NetworkPolicy in the abstract; fewer can say "I proved the block with
a pod that should fail, not just assumed the allow list worked."

## Things that went differently than the script (fill in during the real run)

- MetalLB pool IP actually assigned: _______________
- Anything in demo-apps.yaml or network-policy.yaml that needed adjusting: _______________
- Anything above that took more than one attempt, and why: _______________
