# Akamai K8s Lab — Bare-Metal-Style Kubernetes from Scratch

A four-node Kubernetes cluster built with `kubeadm` on plain Linux VMs on Akamai Cloud (Linode),
deliberately configured **without** cloud primitives — no managed control plane, no cloud
controller manager, no cloud load balancer, no cloud CSI — so it behaves like an on-premises
bare-metal cluster.

Built to close the hands-on gaps for the AHEAD Kubernetes Infrastructure Engineer role
(see [`docs/gap-analysis.md`](docs/gap-analysis.md)).

## Start here

| Document | What's in it |
|---|---|
| [`PROJECT-PLAN.md`](PROJECT-PLAN.md) | The 7-day plan: design rationale, cluster footprint, costs, 8 stages with proofs |
| [`docs/gap-analysis.md`](docs/gap-analysis.md) | JD requirement → existing evidence → gap → stage that closes it |
| [`scripts/`](scripts/) | `provision.sh`, `destroy.sh`, `node-prep.sh` — drafts; making them work is Stage 0 |
| `runbooks/` | Written during Stages 5-7: upgrade, etcd restore, node add/remove, troubleshooting |
| `manifests/` | Calico, MetalLB, ingress-nginx, storage classes, test workloads |
| `results/` | Break/fix drill logs and evidence |

## Architecture

```
                   Internet
                      │  (Cloud Firewall: SSH from my IP only, everything else dropped)
        ┌─────────────┴──────────────┐
        │  public interface (eth0)   │
   ┌────┴─────┐  ┌──────┐  ┌──────┐  ┌───────┐
   │ k8s-cp1  │  │ w1   │  │ w2   │  │ nfs   │
   │ 2vCPU/4G │  │1/2G  │  │1/2G  │  │1/1G   │
   └────┬─────┘  └──┬───┘  └──┬───┘  └───┬───┘
        └───────────┴─────────┴──────────┘
              VLAN "k8slab" — 10.10.0.0/24 (eth1)
              L2 segment: all cluster traffic + MetalLB's ARP lives here

   cp1  control plane (kubeadm, stacked etcd, static pods)
   w1/w2 workers — containerd, Calico CNI, local PVs
   nfs  outside the cluster: NFS server + private registry
```

The VLAN is doing real work: it gives the nodes L2 adjacency, which is what lets **MetalLB run in
layer-2 mode** exactly as it would in a rack. That's what makes this an honest bare-metal analogue
rather than a cloud cluster wearing a costume.

## Quick start

```bash
pip install linode-cli && linode-cli configure
cd ~/akamai-k8s-lab/scripts
./provision.sh          # expect to debug the VLAN --interfaces syntax; that's Stage 0
# attach a Cloud Firewall (see provision.sh output) — do not skip this
# then, on each node, as root:
K8S_MINOR=1.xx ./node-prep.sh   # one minor behind stable, on purpose
```

Then follow [`PROJECT-PLAN.md`](PROJECT-PLAN.md) from Stage 1.

## Cost

~$0.08/hr for all four nodes, ~$13 if left running the full week. Credit: $99.91, expires
2026-11-01. Cost is not the constraint here — don't spend sprint time optimizing it.
