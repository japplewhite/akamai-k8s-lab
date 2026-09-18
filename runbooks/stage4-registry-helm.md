# Runbook — Registry, Images, and Helm Authoring (Stage 4)

A self-hosted TLS + basic-auth registry on `k8s-nfs`, containerd configured to trust it,
`crictl`-driven image inspection, and a Helm chart authored from scratch (not `helm install`ing
someone else's). Fill in `[ ]` and `RESULT:` as you go.

---

## 1. Stand up the registry on k8s-nfs

```bash
scp scripts/setup-registry.sh root@172.234.157.215:~/
ssh root@172.234.157.215
./setup-registry.sh
```

**Copy down the printed username/password — you'll need them below and they aren't stored
anywhere else.** Also grab the CA cert to your Mac so you can distribute it to the cluster nodes:

```bash
# from your Mac
scp root@172.234.157.215:/etc/docker-registry/certs/ca.crt ~/akamai-k8s-lab/
```

- [ ] `systemctl status registry` shows `active (running)`
- [ ] CA cert copied to your Mac

RESULT (username / password, keep private): _______________

## 2. Make cp1, w1, and w2 trust it

Do this on **all three** cluster nodes — the registry might get pulled from by a pod on any node,
and cp1 needs it too since that's where we'll build and push the image with `nerdctl`.

```bash
for ip in 139.144.223.215 172.234.157.15 172.234.157.226; do
  scp ~/akamai-k8s-lab/ca.crt root@$ip:~/
  scp ~/akamai-k8s-lab/scripts/trust-registry.sh root@$ip:~/
done
```

Then on **each** node:
```bash
./trust-registry.sh
```

This writes `/etc/containerd/certs.d/k8s-nfs:5000/hosts.toml` and adds an `/etc/hosts` entry — but
it deliberately stops short of touching `config.toml`, because the exact plugin key for the CRI
registry's `config_path` setting has moved across containerd versions and guessing wrong would
silently do nothing. Check what **this** node's install actually uses:

```bash
containerd config default | grep -B1 -A3 "config_path"
```

Look for a line like `config_path = ""` under whatever the registry stanza is called on your
version — set it to `config_path = "/etc/containerd/certs.d"` by editing
`/etc/containerd/config.toml` directly at that exact spot, then:

```bash
systemctl restart containerd
```

Repeat the `containerd config default | grep ... config_path` check + edit + restart on **all
three** nodes. Write down the exact plugin key you found (it'll be the same across all three
since they're all the same containerd version, but confirm rather than assume):

RESULT (plugin key found): _______________

- [ ] all three nodes have `config_path` set and containerd restarted

## 3. Build and push an image — no Docker anywhere

Install `nerdctl` + `buildkit` on **cp1 only** (this becomes your one "build node" — a normal
pattern, not every node needs to build images):

```bash
ssh root@139.144.223.215
NERDCTL_VERSION=2.3.5   # verified current as of this writing — https://github.com/containerd/nerdctl/releases
curl -fsSL -o /tmp/nerdctl.tar.gz \
  https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-amd64.tar.gz
tar -xzf /tmp/nerdctl.tar.gz -C /usr/local/bin nerdctl

BUILDKIT_VERSION=0.33.0   # verified current as of this writing — https://github.com/moby/buildkit/releases
curl -fsSL -o /tmp/buildkit.tar.gz \
  https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/buildkit-v${BUILDKIT_VERSION}.linux-amd64.tar.gz
tar -xzf /tmp/buildkit.tar.gz -C /usr/local bin/buildkitd bin/buildctl
nohup /usr/local/bin/buildkitd >/var/log/buildkitd.log 2>&1 &
```

If enough time has passed since this was written that these feel stale, re-check both projects'
releases pages before running — same lesson as every other version pin in this lab.

Build a trivial image:
```bash
mkdir -p ~/hello-lab-image && cd ~/hello-lab-image
cat > Dockerfile <<'EOF'
FROM nginx:alpine
RUN echo "<h1>hello from the private registry</h1>" > /usr/share/nginx/html/index.html
EOF
nerdctl build -t k8s-nfs:5000/hello-lab:v1 .
```

Log in and push (uses the trust config from step 2 automatically, since `nerdctl` talks to the
same containerd):
```bash
nerdctl login k8s-nfs:5000   # enter the username/password from step 1
nerdctl push k8s-nfs:5000/hello-lab:v1
```

- [ ] push succeeds with no TLS errors (a TLS error here means step 2's `hosts.toml`/CA isn't
      right on cp1 — go back and check before moving on)

RESULT: _______________

## 4. Inspect it with `crictl`, not `docker` — and hit a real upstream containerd bug

`crictl` is the CRI-native tool — this is what you actually reach for on a node without Docker
installed, which is every node in this cluster:

```bash
crictl pull --creds labuser:<password> k8s-nfs:5000/hello-lab:v1
```

**Known issue, confirmed on this cluster (containerd v2.2.1):** this pull will very likely fail
with `x509: certificate signed by unknown authority`, even though `nerdctl push`/`pull` against the
exact same target, on the exact same node, with the exact same `hosts.toml`/CA, works fine. Do
**not** assume this means the CA or `hosts.toml` from step 2 is wrong — verify that first with
`openssl verify -CAfile "/etc/containerd/certs.d/k8s-nfs:5000/ca.crt" <(echo | openssl s_client
-connect k8s-nfs:5000 -servername k8s-nfs 2>/dev/null | openssl x509)` (should say `OK`).

If the CA verifies fine but `crictl pull` still fails, this is
[containerd#13246](https://github.com/containerd/containerd/issues/13246): containerd 2.x's newer
CRI-plugin pull path (the "transfer service" — check `journalctl -u containerd` at debug level for
`"using transfer service"` in the log line to confirm) does not correctly apply the daemon's
`config_path`/`certs.d` configuration, even though the classic resolver used by `ctr`/`nerdctl`
does. This affects **any daemon-driven pull**, which includes kubelet pulling images for pods —
not just `crictl`. As of this writing the fix ([containerd#13284](https://github.com/containerd/containerd/pull/13284))
is an open PR, not yet in a released version — check if that's changed by the time you read this.

**Workaround: pre-pull directly into containerd's `k8s.io` namespace using an explicit
`--hosts-dir` override**, which sidesteps the broken daemon-side resolution entirely:

```bash
ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d --user labuser:<password> k8s-nfs:5000/hello-lab:v1
crictl images
crictl inspecti k8s-nfs:5000/hello-lab:v1 | head -30
```

`ctr` ships with containerd already — no extra install needed. This has to be repeated on **every
node the pod might schedule onto** (see step 6), since each node's kubelet independently needs the
image present locally. With `imagePullPolicy: IfNotPresent` (already set in this chart's
`values.yaml`), a pre-cached image means kubelet never attempts a new pull and never hits the bug.

Note that `--user`/`--creds` supplied the password directly on this manual pull — that's the
node-level credential path, completely separate from the Kubernetes-level `imagePullSecret` you'll
create next. `hosts.toml` (step 2) never carries credentials; it only handles TLS trust and
routing.

- [ ] image visible in `crictl images`

RESULT: _______________

## 5. Give the cluster a real pull secret

```bash
kubectl create secret docker-registry registry-creds \
  --docker-server=k8s-nfs:5000 \
  --docker-username=labuser \
  --docker-password='<password from step 1>' \
  -n demo
```

- [ ] `kubectl get secret -n demo registry-creds` exists

RESULT: _______________

## 6. Pre-pull on the workers, then install the chart

Because of the containerd bug in step 4, do the same `ctr -n k8s.io images pull --hosts-dir
/etc/containerd/certs.d --user labuser:<password> k8s-nfs:5000/hello-lab:v1` on **w1 and w2** too —
the chart's 2 replicas can land on either, and without this, both would sit in `ImagePullBackOff`
regardless of the `imagePullSecret` being correctly configured, since the underlying daemon-side
pull is what's broken, not the credentials.

`helm` also needs installing on cp1 — it was only ever on your Mac:
```bash
HELM_VERSION=4.3.0   # check https://github.com/helm/helm/releases if this is stale
curl -fsSL -o /tmp/helm.tar.gz https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp
mv /tmp/linux-amd64/helm /usr/local/bin/helm
```

```bash
scp -r ~/akamai-k8s-lab/charts/hello-lab root@139.144.223.215:~/
# on cp1
helm install hello ./hello-lab -n demo
kubectl get pods -n demo -l app.kubernetes.io/instance=hello -o wide
```

If it comes up `ImagePullBackOff` even after pre-pulling everywhere, that's worth actually
debugging rather than re-running: `kubectl describe pod` will show the exact pull error, which
could be a wrong secret name/namespace, `hosts.toml` that didn't take effect on the specific node
the pod landed on, or the node in question missing the `ctr` pre-pull from above.

- [ ] both replicas `Running`

Port-forward and confirm it's actually serving the image you built:
```bash
kubectl port-forward -n demo svc/hello-hello-lab 8080:80
curl http://localhost:8080/
```
Should return `<h1>hello from the private registry</h1>`.

- [ ] curl returns the expected content

RESULT: _______________

## 7. Debug the chart the way you'd actually debug one

Two commands worth having muscle memory for, since "installing charts" isn't the gap — "debugging
one that's wrong" is:

```bash
helm template hello ./hello-lab --set replicaCount=5 | grep replicas
helm install hello ./hello-lab -n demo --dry-run --debug
```

`--dry-run --debug` renders the chart AND shows you the values Helm actually resolved (defaults +
overrides merged) without touching the cluster — the first thing to reach for when a chart isn't
producing what you expect, before assuming Kubernetes itself is the problem.

- [ ] `--set replicaCount=5` visibly changes the rendered output

RESULT: _______________

---

**Proof for this stage (per PROJECT-PLAN.md):** `helm install ./charts/hello-lab` deploying your
own image from your own registry, verified by actually curling the content you put in it.

**Interview answer this stage buys you:** the full image lifecycle with no Docker involved
anywhere — build with `nerdctl`+`buildkit`, push over verified TLS to a self-hosted registry,
inspect with `crictl`, and the specific, correct answer to "how does containerd get registry
credentials" (it doesn't, from `hosts.toml` — that's TLS/routing only; credentials come from
`imagePullSecret` via kubelet for pods, or `--creds` for manual pulls). Plus a chart you wrote
yourself, which is a very different interview answer than "I've used Helm charts."

The containerd transfer-service bug in step 4 is arguably the single best story in this whole
lab: a real, currently-unfixed upstream bug (containerd#13246), diagnosed from first principles —
ruled out the CA/cert content with `openssl verify`, isolated it to the CRI plugin specifically by
proving `nerdctl` succeeded against the identical target, confirmed the mechanism via debug-level
containerd logs showing `"using transfer service"`, found the matching upstream issue, and shipped
a working node-level mitigation. That is a materially different answer than "I've read about
containerd" — it's evidence you can debug containerd internals when the documentation doesn't
cover the failure mode.

## Things that went differently than the script (fill in during the real run)

- Actual containerd plugin key found for `config_path` on this version: _______________
- nerdctl / buildkit versions actually used (check against the stale ones above): _______________
- Anything that took more than one attempt, and why: _______________
