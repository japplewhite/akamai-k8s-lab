# Runbook — Cluster Bootstrap (Stage 1)

Bootstraps `k8s-cp1` as the control plane and joins `k8s-w1`/`k8s-w2` as workers. Assumes
`scripts/node-prep.sh` has already run successfully on all three nodes (containerd healthy,
kubelet/kubeadm/kubectl installed and held) and the VLAN addresses from `PROJECT-PLAN.md` are up:
`cp1=10.10.0.10`, `w1=10.10.0.11`, `w2=10.10.0.12`.

Fill in the `[ ]` checkboxes and the `RESULT:` blanks as you go — this file doubles as your
execution log and your interview prep notes. Anything that goes differently than described here,
write it down; the deviation is usually more useful than the happy path.

---

## 1. Pre-flight checks (on cp1)

```bash
kubeadm version -o short
containerd --version
cat /etc/containerd/config.toml | grep SystemdCgroup
swapon --summary          # must print nothing
lsmod | grep -E 'overlay|br_netfilter'
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
ip addr show eth1         # confirm 10.10.0.10/24 is present — this is the VLAN interface
```

- [ ] `SystemdCgroup = true`
- [ ] `swapon --summary` empty
- [ ] both kernel modules loaded
- [ ] both sysctls = 1
- [ ] eth1 shows the VLAN address

If `eth1` isn't the VLAN interface name, check `ip link` — Linode's naming isn't always
predictable. RESULT: _______________

## 2. `kubeadm init`

Bind the API server to the **VLAN address**, not the public IP — the public interface is meant to
carry only your SSH access through the firewall. Pod CIDR must match what Calico expects
(`192.168.0.0/16` is Calico's own default, which is why it's used here — no reason to fight it).

```bash
sudo kubeadm init \
  --apiserver-advertise-address=10.10.0.10 \
  --pod-network-cidr=192.168.0.0/16 \
  --upload-certs
```

`--upload-certs` isn't needed for a single control-plane node, but it's what you'd add for the HA
build in the post-sprint track — worth typing once now so the flag isn't new later.

**Save the two things `kubeadm init` prints:**
- The `kubeadm join ... --token ... --discovery-token-ca-cert-hash ...` command (for workers)
- Confirmation it printed `Your Kubernetes control-plane has initialized successfully!`

RESULT: _______________

If it fails, `kubeadm init` leaves partial state — don't just re-run it. Use
`kubeadm reset -f && rm -rf /etc/cni/net.d` first, fix the underlying issue, then retry. Note what
failed: _______________

## 3. kubectl access

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes
```

Expect `cp1` listed but `NotReady` — that's correct, there's no CNI yet, and kubelet won't report
Ready until pod networking exists.

- [ ] `cp1` shows up, status `NotReady`

## 4. Inspect the static pods

This is the thing to actually look at, not skip past — it's where "control plane components"
stops being an abstraction:

```bash
ls /etc/kubernetes/manifests/
sudo cat /etc/kubernetes/manifests/etcd.yaml | head -30
crictl ps                 # kube-apiserver, kube-scheduler, kube-controller-manager, etcd
```

Note what you see — these four are **static pods**: the kubelet reads these manifests directly off
disk and runs them without the apiserver being involved, which is exactly why they can come up
before the apiserver itself is ready. RESULT: _______________

## 5. Install Calico

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/tigera-operator.yaml
kubectl apply -f manifests/calico/custom-resources.yaml
watch kubectl get pods -n calico-system
```

Check the pinned version against [Calico's release list](https://github.com/projectcalico/calico/releases)
before running — write the version you actually used here: RESULT: _______________

Wait for every pod in `calico-system` to be `Running`, then:

```bash
kubectl get nodes     # cp1 should now flip to Ready
```

- [ ] all calico-system pods Running
- [ ] cp1 status Ready

If cp1 stays `NotReady` after Calico looks healthy, check `kubectl describe node cp1` for the
kubelet condition message first — don't start guessing. Common cause: `--pod-network-cidr` didn't
match the CIDR Calico's install expects (fix it in `manifests/calico/custom-resources.yaml`, not by
passing calico a CIDR that doesn't match kubeadm). RESULT: _______________

## 6. Join the workers

On **w1** and **w2**, run the join command saved from step 2 (as root):

```bash
sudo kubeadm join 10.10.0.10:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

Token expired (>24h since init)? Generate a fresh one from cp1:

```bash
kubeadm token create --print-join-command
```

- [ ] w1 joined
- [ ] w2 joined

RESULT: _______________

## 7. Final verification (on cp1)

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl run test-shell --rm -it --image=busybox:1.36 --restart=Never -- sh -c \
  "nslookup kubernetes.default.svc.cluster.local; wget -qO- http://kubernetes.default 2>&1 | head -1"
```

Use the **fully-qualified name** (`kubernetes.default.svc.cluster.local`), not the short form. BusyBox's
resolver (musl libc) doesn't reliably walk the pod's `search`/`ndots` list the way glibc does — the
short name (`kubernetes.default`) commonly comes back `NXDOMAIN` from a BusyBox pod even when
CoreDNS, the `kube-dns` Service, and cluster networking are all completely healthy. This is a
documented BusyBox/Alpine quirk, not a cluster bug — confirmed by checking, in order: `kubectl get
svc/endpoints -n kube-system kube-dns` (backing pod IPs present), CoreDNS logs (clean), then the
short-name-vs-FQDN split, which isolates it to the client's resolver rather than the server. Good
war story for the DNS-troubleshooting interview question — don't be thrown by it happening again in
Stage 6's break/fix drills; it isn't one of the deliberate breaks.

- [X ] all 3 nodes `Ready`
- [X] all system pods `Running`
- [X ] test pod resolves the FQDN and reaches the apiserver ClusterIP

Optional deeper check: `wget -qO- --no-check-certificate https://kubernetes.default.svc.cluster.local:443`
from inside the pod. Expect a **TLS alert** (e.g. `alert code 47 / illegal_parameter`) rather than a
clean HTTP response — that's success, not failure: it means the TCP connection reached the
apiserver and the apiserver's TLS stack responded, it's just that BusyBox's minimal TLS client
can't negotiate parameters Go's `crypto/tls` requires. A real failure here is "connection refused"
or a timeout, not a TLS alert.

**Proof for this stage (per PROJECT-PLAN.md):** `kubectl get nodes` — three `Ready`, save the
output. Cluster is ready for Stage 2 (MetalLB + ingress).

---

## Things that went differently than the script (fill in during the real run)

- Version actually installed (`K8S_MINOR`): _______________
- Anything node-prep.sh needed manual fixing for: _______________
- Anything above that took more than one attempt, and why: _______________
