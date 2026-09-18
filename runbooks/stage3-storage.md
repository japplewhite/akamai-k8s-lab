# Runbook — Storage with No Cloud CSI (Stage 3)

NFS dynamic provisioning + a static local PV, compared head-to-head with two Postgres
StatefulSets, then a reclaim-policy comparison. Fill in `[ ]` and `RESULT:` as you go.

---

## 1. NFS server on k8s-nfs

```bash
scp scripts/setup-nfs-server.sh root@172.234.157.215:~/
ssh root@172.234.157.215
./setup-nfs-server.sh
```

- [ ] `exportfs -v` shows `/srv/nfs/k8s` exported to `10.10.0.0/24`

RESULT: __Server ready at 10.10.0.20:/srv/nfs/k8s. VLAN firewall already allows all traffic on
10.10.0.0/24, so no additional firewall changes are needed for NFS (port 2049)._____________

## 2. Deploy the NFS provisioner

```bash
scp manifests/storage/nfs-provisioner.yaml root@139.144.223.215:~/
# on cp1
kubectl apply -f nfs-provisioner.yaml
kubectl get pods -n nfs-provisioner
kubectl get storageclass
```

- [X ] `nfs-client-provisioner` pod `Running`
- [ X] `nfs-client` StorageClass listed

RESULT: ___success____________

## 3. Prepare the local PV's directory on w1

The `local` volume type does **not** create the directory for you — it just points at one that
must already exist:

```bash
ssh root@172.234.157.15   # w1
mkdir -p /mnt/local-pv
```

Then apply the StorageClass + PV from cp1:
```bash
scp manifests/storage/local-pv.yaml root@139.144.223.215:~/
# on cp1
kubectl apply -f local-pv.yaml
kubectl get pv
```

- [X ] `local-pv-w1` shows `STATUS: Available`

RESULT: _. kubectl get pv
NAME          CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS    VOLUMEATTRIBUTESCLASS   REASON   AGE
local-pv-w1   2Gi        RWO            Retain           Available           local-storage   <unset>                          8s
root@k8s-cp1:~#______________

## 4. Deploy both Postgres StatefulSets

```bash
scp manifests/storage/postgres-nfs.yaml manifests/storage/postgres-local.yaml root@139.144.223.215:~/
# on cp1
kubectl apply -f postgres-nfs.yaml
kubectl apply -f postgres-local.yaml
kubectl get pods -n demo -o wide
kubectl get pvc -n demo
```
Result:


Watch `pg-local-0` specifically — it should land on **w1** (check the `NODE` column in
`-o wide`), because that's the only node the PV's `nodeAffinity` allows.

- [ X] both `pg-nfs-0` and `pg-local-0` reach `Running`
- [X ] `pg-local-0` is scheduled on `k8s-w1`
- [X ] both PVCs `Bound`

RESULT: _______________
root@k8s-cp1:~# kubectl get pods -n demo -o wide
NAME                     READY   STATUS    RESTARTS   AGE   IP               NODE     NOMINATED NODE   READINESS GATES
app-a-b8d8b9c9d-tgpmv    1/1     Running   0          22h   192.168.228.67   k8s-w1   <none>           <none>
app-b-84b54865c4-rrbrl   1/1     Running   0          22h   192.168.46.7     k8s-w2   <none>           <none>
pg-local-0               1/1     Running   0          18h   192.168.228.75   k8s-w1   <none>           <none>
pg-nfs-0                 1/1     Running   0          18h   192.168.46.8     k8s-w2   <none>           <none>
root@k8s-cp1:~# kubectl get pvc -n demo
NAME              STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS    VOLUMEATTRIBUTESCLASS   AGE
data-pg-local-0   Bound    local-pv-w1                                2Gi        RWO            local-storage   <unset>                 18h
data-pg-nfs-0     Bound    pvc-b00ebb5a-46a7-465f-9115-c209155ba1fe   1Gi        RWO            nfs-client      <unset>                 18h

## 5. Put data in each, then kill the pod and watch what happens

```bash
kubectl exec -n demo pg-nfs-0   -- psql -U postgres -c "CREATE TABLE t(x int); INSERT INTO t VALUES (1);"
kubectl exec -n demo pg-local-0 -- psql -U postgres -c "CREATE TABLE t(x int); INSERT INTO t VALUES (1);"

kubectl delete pod -n demo pg-nfs-0 pg-local-0
kubectl get pods -n demo -o wide -w    # ctrl-c once both are back to Running
```
root@k8s-cp1:~# kubectl delete pod -n demo pg-nfs-0 pg-local-0
pod "pg-nfs-0" deleted from demo namespace
pod "pg-local-0" deleted from demo namespace
root@k8s-cp1:~# kubectl get pods -n demo -o wide -w
NAME                     READY   STATUS    RESTARTS   AGE   IP               NODE     NOMINATED NODE   READINESS GATES
app-a-b8d8b9c9d-tgpmv    1/1     Running   0          22h   192.168.228.67   k8s-w1   <none>           <none>
app-b-84b54865c4-rrbrl   1/1     Running   0          22h   192.168.46.7     k8s-w2   <none>           <none>
pg-local-0               1/1     Running   0          17s   192.168.228.77   k8s-w1   <none>           <none>
pg-nfs-0                 1/1     Running   0          14s   192.168.46.9     k8s-w2   <none>           <none>

Confirm the data survived on both, and note where each pod landed this time:

```bash
kubectl exec -n demo pg-nfs-0   -- psql -U postgres -c "SELECT * FROM t;"
kubectl exec -n demo pg-local-0 -- psql -U postgres -c "SELECT * FROM t;"
```
root@k8s-cp1:~# kubectl exec -n demo pg-nfs-0   -- psql -U postgres -c "SELECT * FROM t;"
 x
---
 1
(1 row)

root@k8s-cp1:~# kubectl exec -n demo pg-local-0 -- psql -U postgres -c "SELECT * FROM t;"
 x
---
 1
(1 row)
 [X] `pg-local-0` data survived, and it landed on `k8s-w1` again (the only place it *can* land)

RESULT: _______success________

## 6. Prove the local PV's constraint for real: cordon w1

This is the part that's actually worth being able to explain in an interview — not just "local PV
is node-bound" as a fact, but having watched it deadlock:

```bash
kubectl cordon k8s-w1
kubectl delete pod -n demo pg-local-0
kubectl get pods -n demo pg-local-0 -w    # ctrl-c after ~20s
kubectl describe pod -n demo pg-local-0 | tail -15
```
root@k8s-cp1:~# kubectl delete pod -n demo pg-local-0
pod "pg-local-0" deleted from demo namespace
root@k8s-cp1:~# kubectl get pods -n demo pg-local-0 -w    # ctrl-c after ~20s
NAME         READY   STATUS    RESTARTS   AGE
pg-local-0   0/1     Pending   0          11s

root@k8s-cp1:~# kubectl describe pod -n demo pg-local-0 | tail -15
    ReadOnly:   false
  kube-api-access-zppbb:
    Type:                    Projected (a volume that contains injected data from multiple sources)
    TokenExpirationSeconds:  3607
    ConfigMapName:           kube-root-ca.crt
    Optional:                false
    DownwardAPI:             true
QoS Class:                   Burstable
Node-Selectors:              <none>
Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  107s  default-scheduler  0/3 nodes are available: 1 node(s) didn't match PersistentVolume's node affinity, 1 node(s) had untolerated taint(s), 1 node(s) were unschedulable. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.

- [X] `pg-local-0` stays `Pending` — `describe` should show a scheduling failure mentioning node
      affinity/selector not matching any schedulable node

Clean up:
```bash
kubectl uncordon k8s-w1
```
Confirm `pg-local-0` schedules and comes back `Running` once w1 is uncordoned.

RESULT: _______________
root@k8s-cp1:~# kubectl uncordon k8s-w1
node/k8s-w1 uncordoned
root@k8s-cp1:~# kubectl get pods -n demo pg-local-0 -w    # ctrl-c after ~20s
NAME         READY   STATUS    RESTARTS   AGE
pg-local-0   1/1     Running   0          3m32s



## 7. Reclaim policy: what happens when you delete the PVC

The two StorageClasses were deliberately set up with **different** reclaim policies, so this
comparison happens naturally rather than needing a contrived second StorageClass:

- `nfs-client` → `reclaimPolicy: Delete` (the dynamic-provisioning default)
- `local-pv-w1` → `persistentVolumeReclaimPolicy: Retain` (set by hand on the PV — the sane
  default for anything statically provisioned, since you don't want a typo'd `kubectl delete pvc`
  silently destroying data you manually provisioned)

```bash
kubectl get pv    # note the two PV names before you start
root@k8s-cp1:~# kubectl get pv    # note the two PV names before you start
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                  STORAGECLASS    VOLUMEATTRIBUTESCLASS   REASON   AGE
local-pv-w1                                2Gi        RWO            Retain           Bound    demo/data-pg-local-0   local-storage   <unset>                          18h
pvc-b00ebb5a-46a7-465f-9115-c209155ba1fe   1Gi        RWO            Delete           Bound    demo/data-pg-nfs-0     nfs-client      <unset>                          18h

kubectl delete pvc -n demo data-pg-nfs-0
above command hung but succeeded.. weird
kubectl get pv    # the NFS-backed PV should be GONE
root@k8s-cp1:~# kubectl get pv    # the NFS-backed PV should be GONE
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                  STORAGECLASS    VOLUMEATTRIBUTESCLASS   REASON   AGE
local-pv-w1                                2Gi        RWO            Retain           Bound    demo/data-pg-local-0   local-storage   <unset>                          18h
pvc-b00ebb5a-46a7-465f-9115-c209155ba1fe   1Gi        RWO            Delete           Bound    demo/data-pg-nfs-0     nfs-client      <unset>                          18h
Clean up:
root@k8s-cp1:~# kubectl scale statefulset -n demo pg-nfs --replicas=0
statefulset.apps/pg-nfs scaled
root@k8s-cp1:~# kubectl get pod -n demo pg-nfs-0 -w    # ctrl-c once it's gone
NAME       READY   STATUS        RESTARTS   AGE
pg-nfs-0   1/1     Terminating   0          17m
pg-nfs-0   1/1     Terminating   0          17m
pg-nfs-0   0/1     Completed     0          17m

pg-nfs-0   0/1     Completed     0          17m
pg-nfs-0   0/1     Completed     0          17m



^Croot@k8s-cp1:~# kubectl get pod -n demo pg-nfs-0 -w    # ctrl-c once it's gone
Error from server (NotFound): pods "pg-nfs-0" not found



ssh root@172.234.157.215 'ls /srv/nfs/k8s/'   # its subdirectory should be gone too

kubectl delete pvc -n demo data-pg-local-0
kubectl get pv    # local-pv-w1 should still exist, now STATUS: Released, not deleted
```
root@k8s-cp1:~# kubectl scale statefulset -n demo pg-local --replicas=0
statefulset.apps/pg-local scaled
root@k8s-cp1:~# kubectl get pod -n demo pg-local-0 -w   # ctrl-c once it's gone
NAME         READY   STATUS        RESTARTS   AGE
pg-local-0   1/1     Terminating   0          15m
pg-local-0   1/1     Terminating   0          15m
pg-local-0   0/1     Completed     0          15m
pg-local-0   0/1     Completed     0          15m
pg-local-0   0/1     Completed     0          15m
- [ X] NFS PVC delete → PV **and** its NFS subdirectory both disappeared automatically
- [ X] local PVC delete → PV still exists, `STATUS: Released`, data still on w1's disk untouched
see below for details..

RESULT: _______________
oot@k8s-cp1:~# kubectl scale statefulset -n demo pg-local --replicas=0
statefulset.apps/pg-local scaled
root@k8s-cp1:~# kubectl get pod -n demo pg-local-0 -w   # ctrl-c once it's gone
NAME         READY   STATUS        RESTARTS   AGE
pg-local-0   1/1     Terminating   0          15m
pg-local-0   1/1     Terminating   0          15m
pg-local-0   0/1     Completed     0          15m
pg-local-0   0/1     Completed     0          15m
pg-local-0   0/1     Completed     0          15m

^Croot@k8s-cp1:~# kubectl delete pvc -n demo data-pg-local-0
persistentvolumeclaim "data-pg-local-0" deleted from demo namespace
root@k8s-cp1:~# kubectl get pv
NAME          CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM                  STORAGECLASS    VOLUMEATTRIBUTESCLASS   REASON   AGE
local-pv-w1   2Gi        RWO            Retain           Released   demo/data-pg-local-0   local-storage   <unset>                          18h


To actually reuse `local-pv-w1` after this, a `Released` PV needs its `claimRef` cleared by hand
(`kubectl patch pv local-pv-w1 -p '{"spec":{"claimRef": null}}'`) before it'll go back to
`Available` — worth knowing that `Retain` means "won't auto-delete," not "will auto-recycle."

**Tip worth remembering, not necessarily worth re-testing here:** you can patch a live PV's
reclaim policy after the fact — `kubectl patch pv <name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`
— as a safety net right before deleting a PVC you're nervous about, even if it was originally
provisioned with `Delete`.

oot@k8s-cp1:~# kubectl scale statefulset -n demo pg-local --replicas=0
statefulset.apps/pg-local scaled
root@k8s-cp1:~# kubectl get pod -n demo pg-local-0 -w   # ctrl-c once it's gone
NAME         READY   STATUS        RESTARTS   AGE
pg-local-0   1/1     Terminating   0          15m
pg-local-0   1/1     Terminating   0          15m
pg-local-0   0/1     Completed     0          15m
pg-local-0   0/1     Completed     0          15m
pg-local-0   0/1     Completed     0          15m

^Croot@k8s-cp1:~# kubectl delete pvc -n demo data-pg-local-0
persistentvolumeclaim "data-pg-local-0" deleted from demo namespace
root@k8s-cp1:~# kubectl get pv
NAME          CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM                  STORAGECLASS    VOLUMEATTRIBUTESCLASS   REASON   AGE
local-pv-w1   2Gi        RWO            Retain           Released   demo/data-pg-local-0   local-storage   <unset>                          18h

---

**Proof for this stage (per PROJECT-PLAN.md):** a StatefulSet with data surviving pod
delete/reschedule on both storage classes, plus the cordon test showing the actual node-affinity
constraint in action, plus a real Delete-vs-Retain comparison.

**Interview answer this stage buys you:** "PVC stuck Pending — why?" now has real, lived-in
answers: no matching StorageClass, no provisioner running, access-mode mismatch,
`WaitForFirstConsumer` waiting on a schedulable pod, or — the one you actually watched happen —
local-PV node affinity pointing at a cordoned/unschedulable node.

## Things that went differently than the script (fill in during the real run)

- Anything the NFS setup needed fixing (permissions, `no_root_squash`, etc.): _no______________
- Postgres resource requests too tight/loose for the worker nodes' 2GB RAM: ____no___________
- Anything above that took more than one attempt, and why: ___the pvs did not delete until we scaled the stateful set to 0 with
kubectl scale statefulset -n demo pg-local --replicas=0
____________
