#!/bin/bash
# Generate self-signed TLS certificates for the Valkey cluster.
# Includes SAN extensions for Kubernetes service DNS names.
# Usage: bash generate-tls.sh

set -e

CERT_DIR="tls-certs"
mkdir -p "$CERT_DIR"

NAMESPACE="valkey-cluster"
SAN_DOMAIN="valkey-cluster.${NAMESPACE}.svc.cluster.local"

echo "[1/5] Generating CA key (4096 bits)..."
openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null

echo "[2/5] Generating CA certificate (10 year validity)..."
openssl req -x509 -new -nodes \
  -key "$CERT_DIR/ca.key" -sha256 -days 3650 \
  -out "$CERT_DIR/ca.crt" -subj "/CN=Valkey CA"

echo "[3/5] Generating server key (2048 bits)..."
openssl genrsa -out "$CERT_DIR/server.key" 2048 2>/dev/null

echo "[4/5] Generating server CSR with SAN extensions..."
cat > "$CERT_DIR/san.cnf" <<EOF
[req]
default_bits = 2048
prompt = no
distinguished_name = dn
req_extensions = v3_req

[dn]
CN = *.$SAN_DOMAIN

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.$SAN_DOMAIN
DNS.2 = $SAN_DOMAIN
DNS.3 = valkey-client.${NAMESPACE}.svc.cluster.local
DNS.4 = *.${NAMESPACE}.svc.cluster.local
EOF

openssl req -new \
  -key "$CERT_DIR/server.key" \
  -out "$CERT_DIR/server.csr" \
  -config "$CERT_DIR/san.cnf"

echo "[5/5] Signing server certificate (365 day validity)..."
openssl x509 -req \
  -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
  -out "$CERT_DIR/server.crt" -days 365 -sha256 \
  -extensions v3_req -extfile "$CERT_DIR/san.cnf"

# Permissions
chmod 600 "$CERT_DIR/ca.key" "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/ca.crt" "$CERT_DIR/server.crt"

# Cleanup intermediates
rm -f "$CERT_DIR/server.csr" "$CERT_DIR/san.cnf" "$CERT_DIR"/*.srl

echo ""
echo "=== Server Certificate SANs ==="
openssl x509 -in "$CERT_DIR/server.crt" -noout -ext subjectAltName 2>/dev/null || true

echo ""
echo "[OK] Certificates generated in $CERT_DIR/"
ls -lh "$CERT_DIR"
