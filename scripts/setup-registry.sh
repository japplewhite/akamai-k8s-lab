#!/usr/bin/env bash
# Stand up a private, TLS + basic-auth container registry on k8s-nfs, as a bare systemd
# service — no Docker/containerd needed on this node just to host it. Run as root on k8s-nfs.
set -euo pipefail

REGISTRY_HOST="${REGISTRY_HOST:-k8s-nfs}"
REGISTRY_IP="${REGISTRY_IP:-10.10.0.20}"
REGISTRY_USER="${REGISTRY_USER:-labuser}"
REGISTRY_PASS="${REGISTRY_PASS:-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)}"
VERSION="3.1.1"

CONF_DIR=/etc/docker-registry
CERTS_DIR="$CONF_DIR/certs"
AUTH_DIR="$CONF_DIR/auth"
DATA_DIR=/var/lib/registry

echo "== Installing htpasswd (apache2-utils) and curl/tar"
apt-get update -qq
apt-get install -y -qq apache2-utils curl tar

echo "== Downloading registry v${VERSION} (standalone binary, no container runtime needed here)"
curl -fsSL -o /tmp/registry.tar.gz \
  "https://github.com/distribution/distribution/releases/download/v${VERSION}/registry_${VERSION}_linux_amd64.tar.gz"
tar -xzf /tmp/registry.tar.gz -C /usr/local/bin registry
chmod +x /usr/local/bin/registry
rm -f /tmp/registry.tar.gz

mkdir -p "$CERTS_DIR" "$AUTH_DIR" "$DATA_DIR"

if [[ -f "$CERTS_DIR/ca.crt" ]]; then
  echo "== CA/server certs already exist at $CERTS_DIR — not regenerating."
  echo "   Re-running this script with existing certs in place would silently orphan any CA"
  echo "   already distributed to cluster nodes (the running registry keeps serving the OLD"
  echo "   cert until restarted, while a freshly-generated CA on disk wouldn't match it —"
  echo "   this exact confusion cost real debugging time once already). Delete $CERTS_DIR"
  echo "   yourself first if you genuinely want to rotate the CA, then re-run."
  SKIP_CERT_GEN=1
else
  SKIP_CERT_GEN=0
fi

if [[ "$SKIP_CERT_GEN" -eq 0 ]]; then
echo "== Generating a self-signed CA + server cert (SAN: DNS:${REGISTRY_HOST}, IP:${REGISTRY_IP})"
openssl genrsa -out "$CERTS_DIR/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$CERTS_DIR/ca.key" -sha256 -days 3650 \
  -out "$CERTS_DIR/ca.crt" -subj "/CN=k8s-lab-registry-ca" 2>/dev/null

openssl genrsa -out "$CERTS_DIR/server.key" 4096 2>/dev/null
openssl req -new -key "$CERTS_DIR/server.key" -out "$CERTS_DIR/server.csr" \
  -subj "/CN=${REGISTRY_HOST}" 2>/dev/null
openssl x509 -req -in "$CERTS_DIR/server.csr" -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" \
  -CAcreateserial -out "$CERTS_DIR/server.crt" -days 825 -sha256 \
  -extfile <(printf "subjectAltName=DNS:%s,IP:%s" "$REGISTRY_HOST" "$REGISTRY_IP") 2>/dev/null
fi

if [[ "$SKIP_CERT_GEN" -eq 0 ]]; then
echo "== Basic auth: user '${REGISTRY_USER}'"
# -B forces bcrypt — the registry's htpasswd backend REQUIRES bcrypt hashes specifically; the
# htpasswd default (MD5 crypt) looks like it worked but fails auth at request time with no
# useful error, which is a nasty one to debug blind.
htpasswd -Bbn "$REGISTRY_USER" "$REGISTRY_PASS" > "$AUTH_DIR/htpasswd"
else
  echo "== Certs already existed, so leaving the existing htpasswd/password alone too —"
  echo "   otherwise this run's freshly-generated password wouldn't match what's on disk."
fi

cat > "$CONF_DIR/config.yml" <<EOF
version: 0.1
log:
  fields:
    service: registry
storage:
  filesystem:
    rootdirectory: ${DATA_DIR}
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
  tls:
    certificate: ${CERTS_DIR}/server.crt
    key: ${CERTS_DIR}/server.key
auth:
  htpasswd:
    realm: k8s-lab-registry
    path: ${AUTH_DIR}/htpasswd
EOF

cat > /etc/systemd/system/registry.service <<'EOF'
[Unit]
Description=Container image registry
After=network.target

[Service]
ExecStart=/usr/local/bin/registry serve /etc/docker-registry/config.yml
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable registry
# Always an explicit restart, never just enable --now: on an already-running service,
# --now is a no-op that would NOT pick up on-disk certs/config if they'd changed (e.g. after
# manually deleting $CERTS_DIR to intentionally rotate) — exactly the served-vs-disk mismatch
# that cost real debugging time once already. A restart guarantees the running process always
# matches what's on disk when this script exits, every time.
systemctl restart registry

echo
echo "== Registry live at https://${REGISTRY_HOST}:5000 (VLAN IP ${REGISTRY_IP})"
if [[ "$SKIP_CERT_GEN" -eq 0 ]]; then
echo "== Credentials — SAVE THESE:"
echo "     user: ${REGISTRY_USER}"
echo "     pass: ${REGISTRY_PASS}"
else
echo "== Certs/htpasswd were left alone (already existed) — credentials are unchanged from"
echo "   whatever you saved on the run that actually created them."
fi
echo
echo "CA cert for containerd trust: ${CERTS_DIR}/ca.crt — copy this to each cluster node next."
systemctl status registry --no-pager | head -5
