---
title: "Free Akamai credits? Build a Kubernetes cluster!"
part: 1 of 2
---

# Free Akamai credits? Build a Kubernetes cluster!

Consulting has one occupational hazard nobody warns you about: the gap between what you *did*
two years ago at scale and what you can *still do* with your own two hands today. When you're
running a 27-person infrastructure org, you're reading architecture proposals and incident
postmortems, not typing `kubeadm init`. That's fine — it's the job. But it also means the
fun stuff eludes you. So this is part playing around (it really is fun for me..go figure!) and part preparation for an engagement.

So when I found a stash of free credit sitting unused in my Akamai Cloud (formerly Linode)
account, I gave myself an assignment: stand up a Kubernetes cluster completely from scratch — no
managed control plane, no cloud load balancer, no cloud storage driver — and get back on a first-
name basis with the parts of Kubernetes that don't show up in an architecture review.

This is part one of that write-up: the strategy and the build. Part two, coming next, covers what
I actually did *to* the cluster once it was up — upgrades, etcd disaster recovery, break/fix
drills, and (once I trust the plumbing) some real load testing.

## The strategy: fake bare metal, for real

The easy path here would've been Akamai's managed Kubernetes offering (LKE) — click a button, get
a control plane, done in five minutes. I didn't do that, on purpose. A managed control plane
teaches you nothing about the control plane. The entire point of this exercise was to feel the
sharp edges that a cloud provider normally files off for you, so I built it the way you'd build it
in a colo: four plain Linux virtual machines, `kubeadm`, and my own two hands.

That decision cascades into a bunch of smaller ones. On-prem clusters don't get a cloud controller
manager, a `LoadBalancer` service type that just works, or a CSI driver that provisions disks on
request — those are cloud conveniences, not Kubernetes primitives. So I deliberately went without
all three:

- **No cloud load balancer** → **MetalLB**, running in Layer-2 mode, handing out real IPs and
  ARPing for them itself.
- **No cloud block storage / CSI driver** → a hand-rolled **NFS server** for dynamic storage, plus
  a manually-created **local PersistentVolume** for the static case.
- **No cloud controller manager at all.** The apiserver doesn't know or care it's running on a
  cloud VM.

The one piece of cloud infrastructure I *did* lean on deliberately was a **VLAN** — Akamai lets you
attach a private Layer-2 network to a group of instances. That single detail is what makes MetalLB's
Layer-2 mode work exactly the way it would on a real rack switch: it ARPs for its assigned IP
directly on that segment. Without the VLAN, I'd have been simulating bare metal with a wink and a
nudge. With it, the simulation is honest.

## Getting the nodes ready

Four instances: one control-plane node, two workers, and one node that sits *outside* the cluster
entirely to run NFS and (eventually) a private registry — mirroring how a real infra team usually
keeps storage and cluster compute on separate hardware. We did it with Ceph but any HA storage solution can meet the need depending on the requirements.

Before any of them get to run `kubeadm`, every node needs the same prep, and it's worth walking
through *why*, because each step maps directly to a real failure mode:

- **Swap off.** The kubelet refuses to start cleanly with swap enabled — full stop.
- **`overlay` and `br_netfilter` kernel modules loaded**, plus the sysctls that let bridged pod
  traffic actually get seen by iptables (`net.bridge.bridge-nf-call-iptables`) and let the node
  forward packets between pods at all (`net.ipv4.ip_forward`). Skip these and pods can come up
  fine and still be completely unable to talk to each other — a maddening class of bug if you
  don't know to check for it.
- **containerd's cgroup driver set to `systemd`.** This is the single most common reason a fresh
  kubeadm cluster looks broken: if containerd's cgroup driver doesn't match the kubelet's, the
  kubelet flaps and pods never stabilize. It reads like a networking problem. It isn't.
- **kubelet/kubeadm/kubectl installed one minor version behind current stable, and pinned with
  `apt-mark hold`.** The version lag is deliberate — it guarantees I have a real upgrade to
  perform later instead of just reading about one. The hold is not optional: an unattended
  `apt upgrade` silently bumping these packages is exactly how clusters break at 3 a.m.

## Standing up the control plane

With three nodes prepped, `kubeadm init` on the control-plane node — bound to the VLAN address,
not the public IP, since the public interface exists for SSH and nothing else — brings up etcd,
the API server, the scheduler, and the controller manager as static pods that the kubelet reads
straight off disk. Worth actually looking at `/etc/kubernetes/manifests/` at this point rather than
taking "control plane" as an abstraction; those four YAML files *are* the control plane.

From there:

1. **Calico** goes in via its operator (`tigera-operator` + a custom `Installation` resource) for
   pod networking — the JD I'm building this against names Calico specifically, since it's the CNI
   most associated with real on-prem, BGP-capable deployments rather than pure cloud setups.
2. The two workers join with the token `kubeadm init` prints out — a detail that matters more than
   it looks, since that token expires in 24 hours, and regenerating one mid-project the first time
   is a useful thing to have already done before an interviewer asks about it.
3. **MetalLB** goes in next, gets handed a slice of unused VLAN addresses, and starts advertising
   them over L2.
4. **ingress-nginx** goes on top of that — and its `Service` is `type: LoadBalancer` by default,
   which is the moment the whole exercise clicks into place: with no cloud provider, that would
   normally sit at `<pending>` forever. Watching MetalLB actually satisfy it — a real external IP
   showing up with nothing but ARP behind it — is a small thing that's genuinely satisfying to see
   work.
5. **Storage** comes last: an `nfs-subdir-external-provisioner` pod for dynamic, network-backed
   volumes, and a manually-created local `PersistentVolume` pinned to one specific worker node via
   `nodeAffinity` for the static case. Running the same StatefulSet on each side by side makes the
   tradeoff tangible instead of theoretical — one survives being rescheduled to *any* node, the
   other only survives if it lands back on the exact node its data lives on.

## It didn't go cleanly, and that was the point

None of this went in on the first try, and I'm treating that as a feature of the exercise, not a
blemish on it. A few of the more interesting stumbles:

- A pod could resolve a fully-qualified DNS name perfectly but got `NXDOMAIN` on the short form —
  not a cluster bug at all, but a well-documented quirk of BusyBox's minimal DNS resolver not
  properly walking the search-domain list the way glibc does.
- The NFS dynamic provisioner sat in `ContainerCreating` for six minutes before I found the real
  error: the worker node was simply missing the `nfs-common` package, so the `mount.nfs` helper
  binary kubelet needs didn't exist. An easy one-line fix, but only once you know to look at the
  provisioner pod's own status instead of just staring at a `Pending` PVC.
- A `bash` script died silently with no output at all — turned out to be a classic `pipefail` trap:
  generating a random password via `tr </dev/urandom | head -c 32` causes `head` to close the pipe
  early, `tr` gets `SIGPIPE`, and `set -o pipefail` propagates that failure straight through a
  variable assignment and kills the script before it prints a single line.

Every one of these is now a paragraph in a runbook instead of a mystery, which was the actual goal
all along — not a cluster that happened to come up clean, but a set of failures I've personally
diagnosed and fixed.

## Coming in part 2

The cluster is up, networked, and has real storage. That's necessary but not sufficient — a
cluster you've only ever seen work isn't one you actually know. Part 2 covers what comes next:
performing a real minor-version upgrade end to end, taking an etcd snapshot and actually restoring
from it after deliberately destroying a namespace, adding and cleanly decommissioning nodes, and a
set of deliberate break/fix drills — killing kubelet, filling a disk, corrupting containerd's
config — each timed and written up as it happens. And once I trust the plumbing, some real load
testing to see where it actually falls over.
