Confirming this also reproduces on **containerd v2.2.1** (kubeadm-installed, via
`pkgs.k8s.io` stable-1.36 repo on Ubuntu 24.04), not just v2.2.3 — same root symptom, same
divergence between the classic resolver and the CRI/daemon pull path.

**Setup:** self-hosted private registry with a self-signed CA, TLS + basic auth,
`/etc/containerd/certs.d/<host>:5000/hosts.toml` configured with `ca = ".../ca.crt"`, and
`config_path` correctly set under `[plugins."io.containerd.cri.v1.images".registry]` in
`/etc/containerd/config.toml` (confirmed against the actual on-disk file, not just
`containerd config default`'s template output).

**Symptom:**
```
crictl pull --creds user:pass myregistry:5000/myimage:v1
# → tls: failed to verify certificate: x509: certificate signed by unknown authority
```
on the exact same node, against the exact same target, where `nerdctl pull
myregistry:5000/myimage:v1` (no extra flags) succeeds cleanly.

**Diagnosis steps that ruled out a cert/config problem before concluding this was the daemon path:**
1. `openssl verify -CAfile <the hosts.toml CA> <fetched live leaf cert>` → `OK` — the CA
   genuinely does sign the certificate the registry is serving, confirmed both via the public
   interface and via the same network path `crictl` uses.
2. `nerdctl pull` against the identical reference succeeds with the same on-disk `hosts.toml`.
3. Enabling `[debug] level = "debug"` on containerd and retrying the `crictl pull` shows:
   ```
   PullImage "myregistry:5000/myimage:v1" with snapshotter overlayfs using transfer service
   ...
   fetch failed" error="...: x509: certificate signed by unknown authority" host="myregistry:5000"
   ```
   with no log line indicating `hosts.toml`/`certs.d` was ever consulted for this pull.

**Workaround that unblocked us** (matches the `--hosts-dir` pattern from the original report):
pre-pull directly into the `k8s.io` namespace with an explicit override, so kubelet/CRI finds the
image already present and never attempts its own (broken) pull:
```
ctr -n k8s.io images pull --hosts-dir /etc/containerd/certs.d --user user:pass myregistry:5000/myimage:v1
```
combined with `imagePullPolicy: IfNotPresent` on the Pod spec. Confirms this isn't just a `crictl`
CLI inconvenience — it affects any daemon-driven pull, including kubelet pulling images for actual
pods, which is the higher-impact part of this bug.

Happy to provide the full `containerd` debug log or `config.toml` if useful for triage.
