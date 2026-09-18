# Gap Analysis — AHEAD Kubernetes Infrastructure Engineer (Job ID AHD2026704630)

Source: `email.txt` (Himanshu Sharma / NASSCOMM, 2026-09-02) and
`~/job-search/Jeff_Applewhite_AHEAD_Kubernetes_Infrastructure_Engineer_Resume.docx`.

## The actual gap

It is not knowledge. Twenty years across NetApp, Red Hat, StackPath, and Backblaze covers every
concept in this JD, and you led the org that ran a 100+ node bare-metal Kubernetes private cloud.

The gap is **evidentiary and muscle-memory**. This is an IC contract role, and the resume's
Applewhite IT bullets already describe a kubeadm cluster on Akamai in the past tense. The lab's job
is to make those bullets literally true and defensible under a hands-on technical screen — where
the question is not "what is etcd" but "walk me to a terminal and restore it."

Two specific risks a sharp interviewer will probe:

1. **Director-shaped answers.** Describing what a team did, in outcomes and architecture, when the
   interviewer wants keystrokes and failure modes. The fix is having personally hit the errors.
2. **Cloud-shaped reflexes.** This role is explicitly on-prem/bare-metal. Reaching for a managed
   LoadBalancer, a cloud CSI driver, or a cloud controller manager is the tell that ends the
   interview. The lab is deliberately configured *without* those (see PROJECT-PLAN.md, Stage 0).

## Requirement → evidence → gap

| JD requirement | Existing evidence | Gap | Closed by |
|---|---|---|---|
| Build K8s clusters from scratch | Led 100+ node bare-metal build (Backblaze) | Personally running `kubeadm init/join`, certs, tokens, static pods | Stage 1 |
| Control plane components | Architecture ownership | Reading `/etc/kubernetes/manifests`, debugging a broken apiserver | Stage 1, 6 |
| Networking / CNI (Calico) | Cilium + default-deny at Backblaze | Calico specifically; pod CIDR/IPAM mismatch debugging | Stage 2 |
| Load balancers & DNS | Edge/CDN LB at StackPath | LB with **no cloud provider** — MetalLB L2; CoreDNS failure modes | Stage 2 |
| Storage (NFS, local PV, CSI) | Ceph + local PV oversight; NetApp Trident | Hands-on StorageClass/PVC binding failures, reclaim policy | Stage 3 |
| containerd, OCI, registries | Platform-level | `crictl`, `config.toml`, registry auth, image GC | Stage 4 |
| Helm charts | Deployed via Helm | **Authoring** a chart: templates, values, `helm template` debugging | Stage 4 |
| Lifecycle: upgrade, patch, scale, decommission | Owned Day-2 program | Personally running `kubeadm upgrade`, drain order, node removal | Stage 5 |
| etcd | Listed as known | `etcdctl` with certs, snapshot save/restore, quorum loss | Stage 5 |
| Linux admin & troubleshooting | Deep — 20 yrs | Low risk. Refresh: cgroups v2, kubelet systemd unit, journalctl | Stage 1, 6 |
| Bash/Python automation | Deep — recent (llm-serving-lab) | Low risk. Provisioning + ops scripts are a byproduct of the lab | All stages |
| Monitoring (Prometheus) | Prometheus/VictoriaMetrics/Grafana at Backblaze | Low risk. Install `kube-prometheus-stack` yourself once | Stage 6 |
| CI/CD for infra + apps | Jenkins, Pulumi, release eng | Medium. One real pipeline against this cluster | Stage 6 (stretch) |
| Runbooks & documentation | Deep — NetApp TME, Red Hat PM | None. This is your edge; lean on it | Stage 7 |

## What "closed" means

For each stage: you have run it, broken it, fixed it, and written the runbook. The runbook is the
artifact you can send AHEAD; the break/fix is what makes the story hold up when someone digs.
