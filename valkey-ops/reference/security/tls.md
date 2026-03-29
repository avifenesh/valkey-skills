# TLS Configuration

Use when setting up TLS encryption for Valkey - certificate generation,
server configuration, mutual TLS, replication encryption, and cluster bus
encryption.

Source-verified against `src/tls.c` and `src/config.c` in valkey-io/valkey.

---

## Prerequisites

Valkey must be compiled with TLS support:

```bash
make BUILD_TLS=yes
```

TLS can also be loaded as a module (`USE_OPENSSL=2`), but the built-in mode
(`USE_OPENSSL=1`) is more common for production. The default protocol is
TLSv1.2 + TLSv1.3 (verified in `src/tls.c`: `REDIS_TLS_PROTO_DEFAULT`).

---

## Certificate Generation

### Self-signed CA and certificates

```bash
# Generate CA key and certificate
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt -subj "/CN=Valkey CA"

# Generate server key and certificate
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr \
  -subj "/CN=valkey-server"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 365 -sha256

# Generate client key and certificate (for mTLS)
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr \
  -subj "/CN=valkey-client"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out client.crt -days 365 -sha256

# Set permissions
chmod 600 *.key
chmod 644 *.crt
```

### Production recommendations

- Use a proper PKI or internal CA (HashiCorp Vault, cfssl, step-ca)
- Set certificate lifetimes to 90 days or less and automate rotation
- Use SAN extensions for hostname verification
- Store private keys with restricted permissions (owner read-only)

---

## Server Configuration

### Basic TLS (encrypt in transit)

```
# valkey.conf
tls-port 6379
port 0                          # disable plaintext connections
tls-cert-file /etc/valkey/tls/server.crt
tls-key-file /etc/valkey/tls/server.key
tls-ca-cert-file /etc/valkey/tls/ca.crt
```

### All TLS parameters

Verified from `src/config.c` - complete list of TLS configuration options:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `tls-port` | 0 (disabled) | TLS listening port |
| `tls-cert-file` | none | Server certificate file path |
| `tls-key-file` | none | Server private key file path |
| `tls-key-file-pass` | none | Password for encrypted private key |
| `tls-ca-cert-file` | none | CA certificate for client verification |
| `tls-ca-cert-dir` | none | Directory of CA certificates |
| `tls-auth-clients` | yes | Client certificate requirement: yes/no/optional |
| `tls-auth-clients-user` | off | Map client cert field to ACL user: off/cn/uri |
| `tls-client-cert-file` | none | Separate client cert for outbound connections |
| `tls-client-key-file` | none | Private key for client cert |
| `tls-client-key-file-pass` | none | Password for client key |
| `tls-dh-params-file` | none | DH parameters file |
| `tls-protocols` | TLSv1.2 TLSv1.3 | Space-separated list of allowed protocols |
| `tls-ciphers` | none (OpenSSL default) | TLS 1.2 cipher list |
| `tls-ciphersuites` | none (OpenSSL default) | TLS 1.3 ciphersuites |
| `tls-prefer-server-ciphers` | no | Server-side cipher preference |
| `tls-session-caching` | yes | Enable TLS session caching |
| `tls-session-cache-size` | 20480 | Session cache size |
| `tls-session-cache-timeout` | 300 | Session cache timeout (seconds) |
| `tls-replication` | no | Use TLS for replication connections |
| `tls-cluster` | no | Use TLS for cluster bus |
| `tls-auto-reload-interval` | 0 (disabled) | Background certificate reload interval (seconds) |

All TLS parameters are runtime-modifiable (`MODIFIABLE_CONFIG` flag in source).

---

## Mutual TLS (Client Authentication)

Require clients to present a valid certificate signed by the trusted CA:

```
# valkey.conf
tls-auth-clients yes
```

Three modes:
- `yes` - require client certificate (mutual TLS)
- `no` - do not request client certificate
- `optional` - request but do not require

### Certificate-based ACL user mapping

Map the client certificate CN or SAN URI to an ACL username automatically:

```
tls-auth-clients-user cn    # use Common Name as ACL username
tls-auth-clients-user uri   # use SAN URI as ACL username
```

This eliminates the need for password-based AUTH when using mTLS.

---

## TLS for Replication

Enable encryption between primary and replicas:

```
# On primary and all replicas
tls-port 6379
port 0
tls-cert-file /etc/valkey/tls/server.crt
tls-key-file /etc/valkey/tls/server.key
tls-ca-cert-file /etc/valkey/tls/ca.crt
tls-replication yes
```

When `tls-client-cert-file` and `tls-client-key-file` are configured, Valkey
uses a separate SSL context for outbound connections (replication, cluster bus).
Otherwise, the server certificate is used for both directions. Verified in
`src/tls.c`: `valkey_tls_client_ctx` vs `valkey_tls_ctx`.

---

## TLS for Cluster Bus

Enable encryption for inter-node cluster communication:

```
# On all cluster nodes
tls-cluster yes
```

This encrypts both the gossip protocol and data migration traffic between
cluster nodes.

---

## Certificate Auto-Reload

Valkey can detect certificate file changes and reload without restart:

```
tls-auto-reload-interval 3600    # check every hour (seconds)
```

Set to 0 to disable. The background thread checks file modification times
and reloads the SSL context when changes are detected.

---

## Client Connection

### valkey-cli

```bash
# Server-only TLS
valkey-cli --tls --cacert /path/to/ca.crt -h valkey-host

# Mutual TLS
valkey-cli --tls \
  --cert /path/to/client.crt \
  --key /path/to/client.key \
  --cacert /path/to/ca.crt \
  -h valkey-host
```

### Application clients

Most client libraries support TLS via connection URL:

```
valkeys://username:password@valkey-host:6379
```

Or via explicit TLS options in the client constructor. Consult your client
library documentation for the specific parameter names.

---

## Recommended Cipher Suites

Based on OWASP TLS Cheat Sheet guidance. Only AEAD ciphers with forward
secrecy - no CBC, RC4, DES, 3DES, MD5, SHA-1, EXPORT, NULL, or anonymous
ciphers.

**TLS 1.3 (preferred):**

```
tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
```

**TLS 1.2 (compatibility):**

```
tls-ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
```

Enable server-side cipher preference:

```
tls-prefer-server-ciphers yes
```

PCI DSS requires TLS 1.2 minimum. Use `tls-protocols "TLSv1.2 TLSv1.3"`
(this is already the default).

---

## TLS Material Validation

Valkey validates all TLS materials on load and reload:

- Files and directories are not empty or malformed
- Certificates match their private keys
- Certificates are within their validity period

If validation fails, the reload is rejected and existing materials remain
in use. This prevents a bad certificate push from taking down connections.

---

## Troubleshooting

| Symptom | Likely Cause |
|---------|-------------|
| Connection refused on TLS port | `tls-port` not set or firewall blocking |
| SSL handshake failure | Certificate/key mismatch or expired cert |
| "no shared cipher" error | Protocol version mismatch (check `tls-protocols`) |
| Client cert rejected | CA mismatch or `tls-auth-clients` set to `yes` without client cert |
| Replication not encrypting | `tls-replication yes` missing on primary or replica |

Verify TLS configuration with:

```bash
openssl s_client -connect valkey-host:6379 -CAfile ca.crt
```

---

## See Also

- [ACL Configuration](acl.md) - authentication and authorization
- [Security Hardening](hardening.md) - defense in depth
- [Command Restriction](rename-commands.md) - command restriction strategies
- [Prometheus Setup](../monitoring/prometheus.md) - TLS flags for exporter mTLS connections
- [Monitoring Metrics](../monitoring/metrics.md) - connection tracking and rejected connection metrics
- [Alerting Rules](../monitoring/alerting.md) - alerts for connection failures and TLS handshake errors
- [Replication Tuning](../replication/tuning.md) - TLS for replication connections
- [Cluster Setup](../cluster/setup.md) - TLS for cluster bus
- [See valkey-dev: tls](../valkey-dev/reference/security/tls.md) - SSL context architecture, OpenSSL integration internals
