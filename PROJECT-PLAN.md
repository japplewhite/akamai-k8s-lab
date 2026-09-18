# Project Plan — Bare-Metal-Style Kubernetes on Akamai Cloud

**Goal:** demonstrate, from memory and from artifacts, personally built and operated experience with
a Kubernetes cluster built from scratch on Linux nodes — no managed control plane, no cloud
primitives — the kind of hands-on depth that's easy to lose track of once you're running an
infrastructure org instead of typing the commands yourself.

**Timeline:** 7 days, intense (~28 hrs). **Budget:** ~$0.08/hr, credit expires 2026-11-01.

---

## The one design decision everything else follows from

**Use plain Linode Compute Instances and kubeadm. Do not use LKE.**

Bare-metal-style deployment — as opposed to a managed cloud service — is the entire point of this
exercise. LKE would hand you a control plane you did not build, which proves nothing about your own
hands-on ability. Worse, reaching for cloud-managed primitives out of habit is exactly the reflex
this lab exists to unlearn.

So the lab deliberately amputates the cloud primitives an on-prem cluster does not have:

| Cloud convenience | Why it's disabled | What replaces it | Stage |
|---|---|---|---|
| Cloud controller manager | On-prem has none | Nothing — `kubeadm init` without `--cloud-provider` | 1 |
| NodeBalancer / `type: LoadBalancer` | On-prem has no cloud LB | **MetalLB** in L2 mode over a Linode VLAN | 2 |
| Linode Block Storage CSI | On-prem storage is yours to run | **NFS server VM** + **local PVs** | 3 |
| Docker Desktop / Docker Engine | Cluster runtime is containerd | containerd + `crictl` directly | 1, 4 |
| Managed registry | On-prem runs its own | Self-hosted registry on the NFS node | 4 |

The Linode **VLAN** matters more than it looks: it gives you a real L2 segment across your nodes,
which is what makes MetalLB's layer-2 mode work the same way it does in a rack. That single
detail is what makes this lab an honest bare-metal analogue rather than a cloud cluster in a
costume — and it is a good thing to be able to explain out loud.

---

## Cluster footprint

| Node | Linode type | vCPU / RAM | Role | ~$/hr |
|---|---|---|---|---|
| `k8s-cp1` | `g6-standard-2` | 2 / 4 GB | Control plane (kubeadm requires ≥2 vCPU) | 0.036 |
| `k8s-w1` | `g6-standard-1` | 1 / 2 GB | Worker | 0.018 |
| `k8s-w2` | `g6-standard-1` | 1 / 2 GB | Worker | 0.018 |
| `k8s-nfs` | `g6-nanode-1` | 1 / 1 GB | NFS server + private registry (not in cluster) | 0.0075 |

**≈ $0.08/hr, ≈ $1.90/day, ≈ $13 for the full week left running 24/7.** Prices are approximate —
confirm with `linode-cli linodes types`. Against $99.91 expiring 11/01, cost is a non-issue; do
**not** waste sprint hours optimizing it. Region: pick the one nearest you (`us-east` / `us-iad`)
and keep every node in it — cross-region VLANs do not work.

Two notes that will bite otherwise:

- **Lock down the public interface on day one.** Every Linode has a public IP, and an exposed
  `6443` or `10250` gets scanned within hours. Use a Linode Cloud Firewall (free): allow SSH from
  your IP only, allow all traffic on the VLAN interface, drop the rest inbound. All cluster traffic
  should ride the VLAN.
- **`--pod-network-cidr` must match your CNI config.** Mismatching it is the single most common
  reason a fresh cluster comes up with every pod stuck in `ContainerCreating`.

---

## Stages

Each stage ends with a **proof** (the thing you can show) and an **interview answer** (the thing
you can say). Do not move on without both.

### Stage 0 — Provisioning automation · ~2-3 hrs
Get `linode-cli` installed and authenticated, then make `scripts/provision.sh` and
`scripts/destroy.sh` actually work end to end: 4 instances, a VLAN with static IPAM addresses, a
cloud firewall, your SSH key on all of them. The drafts in `scripts/` are a starting point, not a
finished tool — **debugging them is the stage**, particularly the `--interfaces` VLAN syntax.

> **Proof:** `./provision.sh && ./destroy.sh` runs clean twice in a row.
> **Interview answer:** "How do you stand up nodes repeatably?" — you rebuilt this cluster from
> zero several times this week, which is also how you know the build is reproducible.

### Stage 1 — Bootstrap the cluster from scratch · ~4-5 hrs · **highest value stage**
Node prep by hand at least once before you script it: disable swap, load `overlay` and
`br_netfilter`, set `net.bridge.bridge-nf-call-iptables=1` and `net.ipv4.ip_forward=1`, install
containerd and set `SystemdCgroup = true`, add the `pkgs.k8s.io` apt repo, install and **hold**
kubelet/kubeadm/kubectl.

Install **one minor version behind current stable** on purpose — that is what gives you a real
upgrade to perform in Stage 5. Check what's current at `pkgs.k8s.io` rather than trusting a
version number written down last month.

Then `kubeadm init` bound to the VLAN address, install **Calico**, join both workers, and confirm
the control plane. Read `/etc/kubernetes/manifests/` and understand that the
apiserver, scheduler, controller-manager, and etcd are static pods on disk.

> **Proof:** `kubectl get nodes` — three `Ready`. All core pods running.
> **Interview answer:** the full bootstrap walkthrough, including *why* swap is off and *what*
> `SystemdCgroup` misconfiguration looks like (kubelet flapping, pods stuck).

### Stage 2 — Networking with no cloud LB · ~3-4 hrs
Install **MetalLB** in L2 mode with an address pool drawn from unused VLAN IPs. Install
**ingress-nginx** and let MetalLB assign it an external IP. Expose two apps by hostname through
one ingress. Then write a `NetworkPolicy` that default-denies a namespace and open only what's
needed. Break CoreDNS deliberately and watch what fails.

> **Proof:** two apps reachable by hostname through one ingress IP; policy blocking cross-namespace
> traffic.
> **Interview answer:** "A pod can't resolve DNS — walk me through it." You will have actually
> done it: `kubectl run` a debug pod, `nslookup kubernetes.default`, check CoreDNS pods/logs,
> check `kube-dns` service endpoints, check the node's `/etc/resolv.conf`, check the CNI.

### Stage 3 — Storage with no cloud CSI · ~3-4 hrs
Stand up NFS on `k8s-nfs`, install the NFS subdir external provisioner as a dynamic
`StorageClass`, and separately create **local PVs** on a worker with a
`volumeBindingMode: WaitForFirstConsumer` StorageClass. Run a StatefulSet (Postgres is a good
choice) on each and compare behavior. Delete a PVC under each reclaim policy and watch what
happens to the PV.

> **Proof:** StatefulSet with data surviving a pod delete/reschedule on both classes.
> **Interview answer:** "PVC is stuck `Pending` — why?" (no matching class, no provisioner, access
> mode mismatch, `WaitForFirstConsumer` waiting on a schedulable pod, node affinity on a local PV).

### Stage 4 — Images, registry, and Helm authoring · ~3-4 hrs
Run a private registry on `k8s-nfs` with TLS and basic auth. Build a small image, push it, pull it
into the cluster with an `imagePullSecret`. Configure containerd's registry settings and drive it
with `crictl` (`crictl ps`, `crictl images`, `crictl logs`) — not `docker`.

Then **write a Helm chart from scratch** for that app: `values.yaml`, templates, `_helpers.tpl`,
and debug it with `helm template` and `--dry-run`. Installing charts is not the gap; authoring one
is.

> **Proof:** `helm install myapp ./charts/myapp` deploying your own image from your own registry.
> **Interview answer:** image lifecycle end to end, and why `crictl` is the tool on a node where
> Docker isn't installed.

### Stage 5 — Day-2 lifecycle · ~4-5 hrs · **second-highest value stage**
This is where a Director-shaped answer gets exposed, so do all four:

1. **Upgrade** one minor version: `kubeadm upgrade plan`, unhold/upgrade/hold `kubeadm`,
   `kubeadm upgrade apply`, then kubelet and kubectl; then workers via `kubeadm upgrade node`,
   drain, upgrade, uncordon. Watch a running app stay up.
2. **etcd snapshot and restore.** `etcdctl` against the certs in `/etc/kubernetes/pki/etcd/`.
   Then actually destroy something — delete a namespace — and restore from the snapshot.
3. **Scale:** add a third worker to the existing cluster with a fresh join token
   (`kubeadm token create --print-join-command` — the original token expires in 24h, which is
   itself a classic interview gotcha).
4. **Decommission:** drain, `kubectl delete node`, `kubeadm reset` on the node, and clean up the
   leftover CNI interfaces and iptables rules that `reset` doesn't remove.

> **Proof:** [`runbooks/`](runbooks/) entries for upgrade, etcd restore, node add, node removal.
> **Interview answer:** "How do you upgrade a cluster with no downtime?" and "etcd is corrupt —
> what now?" — with the actual command sequence and the parts that surprised you.

### Stage 6 — Observability and break/fix drills · ~4-5 hrs
Install `kube-prometheus-stack` via Helm, get Grafana up behind your ingress, confirm node and pod
metrics. Then spend the back half of this stage **breaking things and fixing them under a timer**,
writing down symptom → diagnosis → fix each time:

- Stop kubelet on a worker. Fill a node's disk until it hits `DiskPressure` and eviction.
- Corrupt containerd's config and restart it. Delete the CNI config from a node.
- Apply a bad NetworkPolicy that blackholes a service. Expire and regenerate a join token.
- Roll out a Deployment with a bad image tag and diagnose from `kubectl describe` alone.

> **Proof:** [`runbooks/troubleshooting.md`](runbooks/) with a table of symptoms and diagnoses.
> **Interview answer:** three or four specific war stories from *this* cluster, this week. These
> are what separate "I've read about it" from "I've done it," and they are the highest-leverage
> hours in the whole plan.

### Stage 7 — Documentation and narrative · ~2-3 hrs
Your NetApp TME and Red Hat PM background makes this the cheapest stage to do well — documentation
and runbooks are a real strength, worth showing off rather than treating as an afterthought. Write
the top-level `README.md` (architecture diagram, what's deployed, why no cloud primitives), clean
up the runbooks, and draft `docs/interview-demo.md` — a 10-minute walkthrough script, mirroring
what you already did for `llm-serving-lab`.

> **Proof:** a repo worth sharing on its own merits.

---

## If the week compresses

Ruthless priority order if you get fewer hours than planned:

1. **Stage 1** (bootstrap) — non-negotiable, it's the foundation everything else sits on
2. **Stage 5** (upgrade + etcd restore) — the deepest questions come from here
3. **Stage 2** (CNI + MetalLB) — the bare-metal networking differentiator
4. **Stage 3** (NFS + local PV) — the bare-metal storage differentiator
5. Stage 6 break/fix, then Stage 4, then Stage 7

Stages 4 and 6 are where to spend a half-day rather than a full one. Skipping Stage 1 or 5 to make
room for anything else is the wrong trade.

## After the sprint 
Don't tear it down on day 8 — you have ~8 more weeks of runway. In rough value order:
**HA control plane** (3 control-plane nodes, stacked etcd, kube-vip for the endpoint — this is
the biggest remaining bare-metal gap), then a real CI/CD pipeline building and deploying to the
cluster, then Ansible playbooks replacing the bash node-prep (your resume claims Ansible), then
cert-manager, then a Cilium build alongside Calico so you can compare them from experience.
