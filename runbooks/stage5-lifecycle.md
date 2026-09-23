# Runbook — Day-2 Lifecycle: Upgrade, etcd Disaster Recovery, Node Add/Remove (Stage 5)

The second-highest-value stage in the whole project — this is where Director-shaped answers get
exposed. Four things, in order: upgrade the cluster one minor version, prove etcd backup/restore
actually works (not just "I know the command"), add a third worker, then cleanly decommission it.
Fill in `[ ]` and `RESULT:` as you go, same as every other stage.

Current state going in: three nodes, all `v1.36.4`, containerd `2.2.1`. Target: `v1.37.0` — the
current stable minor, confirmed against [kubernetes.io/releases](https://kubernetes.io/releases/)
right before writing this, not assumed from memory.

---

## 1. Baseline etcd snapshot — before touching anything

Good habit, not just a Stage-5 exercise: never start a risky change (like a version upgrade)
without a fresh backup first. Install the etcd client tools that exactly match the running server
version — using a mismatched `etcdctl`/`etcdutl` against a live etcd is asking for a subtle,
hard-to-diagnose failure:

```bash
ssh root@139.144.223.215   # cp1
ETCD_VER=v3.6.8   # must match the running etcd version — check: crictl images | grep etcd
curl -fsSL -o /tmp/etcd.tar.gz \
  https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar -xzf /tmp/etcd.tar.gz -C /tmp
cp /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /tmp/etcd-${ETCD_VER}-linux-amd64/etcdutl /usr/local/bin/
etcdctl version
```

```bash
mkdir -p /root/etcd-backups
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  snapshot save /root/etcd-backups/pre-upgrade.db

etcdutl snapshot status /root/etcd-backups/pre-upgrade.db -w table
```

- [ X] snapshot file created, `etcdutl snapshot status` shows a sane revision/key count

RESULT: ____success___________

## 2. Upgrade the control plane (cp1)

`pkgs.k8s.io` hosts a **separate repo per minor version** — point the apt source at the new one
before touching any packages:

```bash
apt-mark unhold kubeadm
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y kubeadm=1.37.0-*
apt-mark hold kubeadm

kubeadm upgrade plan
```

Read the plan output before applying — confirm it's proposing `v1.36.4 → v1.37.0` and not
something unexpected. Then:

```bash
kubeadm upgrade apply v1.37.0
```

Once that completes, upgrade `kubelet` and `kubectl` on cp1 (kubeadm never touches these itself):

```bash
apt-mark unhold kubelet kubectl
apt-get install -y kubelet=1.37.0-* kubectl=1.37.0-*
apt-mark hold kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet
kubectl get nodes   # cp1 should now show v1.37.0
```

- [X ] `kubeadm upgrade apply` completed without errors
- [X ] cp1 shows `v1.37.0` in `kubectl get nodes`
- [ X] a demo app (`curl` the ingress from Stage 2, or `kubectl exec` into `pg-nfs-0`) still works
      through the upgrade — control-plane upgrades shouldn't drop running workloads

RESULT: ________success_______

## 3. Upgrade the workers, one at a time, properly drained

Do **not** upgrade both workers simultaneously — the whole point of draining first is that the
cluster never loses more than one node's worth of capacity at once. On **cp1**:

```bash
kubectl drain k8s-w1 --ignore-daemonsets --delete-emptydir-data
```

Then on **w1**:
```bash
apt-mark unhold kubeadm
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y kubeadm=1.37.0-*
apt-mark hold kubeadm

kubeadm upgrade node

apt-mark unhold kubelet
apt-get install -y kubelet=1.37.0-*
apt-mark hold kubelet
systemctl daemon-reload
systemctl restart kubelet
```

Back on **cp1**:
```bash
kubectl uncordon k8s-w1
kubectl get nodes   # w1 should show v1.37.0 and Ready
```

Repeat the exact same sequence for **w2**.

- [X ] w1 drained, upgraded, uncordoned, back to `Ready` at `v1.37.0`
- [X ] w2 drained, upgraded, uncordoned, back to `Ready` at `v1.37.0`
- [X ] `kubectl get nodes` shows all three at `v1.37.0`

RESULT: ____success___________

## 4. etcd disaster recovery — actually prove it, don't just run the command

The test that actually proves something: take a snapshot, create a resource **after** that
snapshot, restore from the *earlier* snapshot, and confirm the newer resource is **gone**. That's
the real, uncomfortable truth about etcd restore that's easy to gloss over: it's a point-in-time
revert, not an "undo my last mistake" button — anything created after the snapshot is lost too,
which is exactly why the timing of your last backup matters so much in a real incident.

**Take a fresh snapshot** (the pre-upgrade one is now on old data — start clean post-upgrade):
```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  snapshot save /root/etcd-backups/before-canary.db
```

**Create a "canary" namespace** — this represents work done *after* the last backup, which a real
restore would lose:
```bash
kubectl create namespace canary
kubectl create deployment canary-app --image=nginx:alpine -n canary
kubectl get ns canary   # confirm it exists before restoring
```

**Stop the control plane's dependency on etcd** — move the static pod manifests out so kubelet
stops them (do this on cp1):
```bash
mkdir -p /root/manifests-stopped
mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/kube-apiserver.yaml /root/manifests-stopped/
# give kubelet ~10-20s to actually tear the static pods down
crictl ps | grep -E "etcd|kube-apiserver"   # should show nothing running for either
```

**Restore from the pre-canary snapshot into a fresh data directory** (never restore directly on
top of the live data dir — restore to a new path, then swap it in, so a failed restore doesn't
destroy your only copy of the *current* data too):
```bash
etcdutl snapshot restore /root/etcd-backups/before-canary.db \
  --data-dir /var/lib/etcd-restored \
  --name k8s-cp1 \
  --initial-cluster k8s-cp1=https://10.10.0.10:2380 \
  --initial-advertise-peer-urls https://10.10.0.10:2380

mv /var/lib/etcd /var/lib/etcd-old-$(date +%s)
mv /var/lib/etcd-restored /var/lib/etcd
```

**Bring the control plane back**:
```bash
mv /root/manifests-stopped/etcd.yaml /root/manifests-stopped/kube-apiserver.yaml /etc/kubernetes/manifests/
# wait ~20-30s
kubectl get nodes   # confirms apiserver+etcd are back and answering
```

If etcd doesn't come back healthy, check `crictl ps | grep etcd` and `crictl logs <container-id>`
before assuming the restore itself failed — a permission mismatch on the restored data directory
(the new directory `etcdutl` creates may not match the ownership the etcd container expects) is a
plausible, fixable cause, not a sign the snapshot is bad.

- [X ] `kubectl get ns canary` now returns **NotFound** — the restore genuinely reverted state
- [X ] `kubectl get pods -n demo` (or wherever Stage 1-4 workloads live) shows everything that
      existed *at snapshot time* still present and healthy
- [ X] `kubectl get nodes` shows all three nodes `Ready`

RESULT: __success_____________

Clean up the old data directory once you're confident the restore is good:
```bash
rm -rf /var/lib/etcd-old-*
```

## 5. Scale: add a third worker with a fresh join token

The token from the original `kubeadm init` is long expired (24h lifetime) — generate a new one
rather than hunting for the old one:
```bash
kubeadm token create --print-join-command
```

Provision `k8s-w3` the same way the original three were built — reuse the exact `provision.sh`
pattern rather than typing a one-off `linode-cli` command from memory:
```bash
linode-cli linodes create \
  --label k8s-w3 --type g6-standard-1 --region us-iad --image linode/ubuntu24.04 \
  --root_pass "$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^_+=' </dev/urandom | head -c 32 || true)" \
  --authorized_keys "$(cat ~/.ssh/id_ed25519.pub)" \
  --interface_generation legacy_config \
  --interfaces.purpose public --interfaces.purpose vlan \
  --interfaces.label k8slab --interfaces.ipam_address "10.10.0.13/24" \
  --tags k8s --text --no-headers
```

Attach it to the same Cloud Firewall as the other three nodes (Cloud Manager, same as the original
setup — do this before anything else touches the node), then:
```bash
K8S_MINOR=1.37 ./node-prep.sh   # on w3 — note the target version is now 1.37, not 1.36
```
(Building a brand-new node straight onto current stable, no deliberate version lag this time —
the version-lag trick was only ever about guaranteeing an upgrade to practice, which you just did.)

Then join it with the fresh token:
```bash
sudo kubeadm join 10.10.0.10:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

- [X ] `kubectl get nodes` shows `k8s-w3` `Ready` at `v1.37.0`

RESULT: _____success__________

## 6. Decommission: drain, remove, clean up what `kubeadm reset` leaves behind

Take `k8s-w3` back out the correct way — this is the sequence that matters when a real node is
being retired, not just unplugged:

```bash
kubectl drain k8s-w3 --ignore-daemonsets --delete-emptydir-data
kubectl delete node k8s-w3
```

On **w3** itself:
```bash
kubeadm reset -f
```

`kubeadm reset` does **not** fully clean up — check what it leaves behind:
```bash
ip link show | grep -E "cni|cali|flannel"   # leftover CNI interfaces
iptables-save | grep -i kube                # leftover iptables rules from kube-proxy/CNI
ls /etc/cni/net.d/                          # leftover CNI config
```

Clean those up explicitly:
```bash
ip link delete cni0 2>/dev/null
rm -rf /etc/cni/net.d/*
iptables-save | grep -v KUBE | iptables-restore   # strip kube-proxy rules, keep everything else
```

That `iptables-restore` one-liner is illustrative, not bulletproof — stripping lines that mention
`KUBE` can leave a dangling reference to a chain whose definition line got removed, which makes
`iptables-restore` refuse the whole ruleset. Since this node is about to be deleted entirely below,
it's fine to let that fail rather than debug it — the point is knowing this state exists and where
to look for it, not perfecting the cleanup of a node you're discarding anyway.

Finally, delete the Linode itself:
```bash
# from your Mac
linode-cli linodes list --label k8s-w3 --text --no-headers   # get the id
linode-cli linodes delete <id>
```

- [ ] `kubectl get nodes` shows only the original three, all `Ready` at `v1.37.0`
- [ ] leftover CNI/iptables state on w3 identified and cleaned (or the Linode deleted entirely,
      making the question moot — either is a valid answer, but know which leftover state
      `kubeadm reset` doesn't touch, since that's the actual interview-relevant fact)

RESULT: ____success___________

---

**Proof for this stage (per PROJECT-PLAN.md):** `runbooks/` entries for upgrade, etcd restore,
node add, and node removal — this file is that proof.

**Interview answer this stage buys you:** "How do you upgrade a cluster with no downtime?" — the
real answer, drain-one-node-at-a-time, not a description of it. "etcd is corrupt, what now?" — a
real restore you've performed, including the uncomfortable truth that anything created after your
last snapshot is gone, not a textbook definition of `snapshot save`. And "walk me through adding
and removing a node" — including the part most people skip, that `kubeadm reset` leaves CNI and
iptables state behind that you have to know to look for.

## Things that went differently than the script (fill in during the real run)

- Exact 1.37 patch actually installed (confirm still 1.37.0, or a newer patch shipped since this
  was written): _______________
- Anything about the etcd restore that needed adjusting: _______________
- Anything above that took more than one attempt, and why: _______________
