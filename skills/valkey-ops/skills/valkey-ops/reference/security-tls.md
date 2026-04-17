# TLS in Valkey

Use when the Redis-standard TLS playbook needs a Valkey-specific twist.

Generic pieces - OpenSSL cert generation, cipher-suite hardening, PKI strategy - are the same as any TLS-enabled server. Follow the OWASP TLS Cheat Sheet, use TLS 1.2+1.3 only (which is the Valkey default via `tls-protocols`), and rotate certs on a schedule. This file covers what diverges.

## Build

```sh
make BUILD_TLS=yes    # built-in (recommended)
make BUILD_TLS=module # loadable module - valkey-tls<SUFFIX>.so
```

Module mode lets you toggle TLS without rebuilding the server binary. Official Docker images ship with `BUILD_TLS=yes`, so no rebuild needed in containers.

## Core config (same as Redis)

`tls-port`, `tls-cert-file`, `tls-key-file`, `tls-ca-cert-file` / `tls-ca-cert-dir`, `tls-auth-clients` (`yes`/`no`/`optional`), `tls-replication`, `tls-cluster`. All runtime-modifiable. Disable plaintext with `port 0`.

## Valkey-specific TLS knobs

### `tls-auth-clients-user` - cert-to-ACL mapping

```
tls-auth-clients-user cn     # CN → ACL username
tls-auth-clients-user uri    # SAN URI → ACL username
tls-auth-clients-user off    # default - no mapping
```

Lets a connecting mTLS client skip `AUTH` entirely - the cert subject maps directly to an ACL user. Valkey 9.0 added `uri` (SPIFFE-style identities). The username from the cert must already exist as an ACL user or the connection is rejected.

### `tls-auto-reload-interval`

```
tls-auto-reload-interval 3600   # seconds; 0 disables
```

Background thread watches cert/key files and reloads the `SSL_CTX` in-place without restart. Valkey splits the work - a BIO thread parses new certs, the main thread atomically swaps the context pointer. Change-detection uses SHA-256 over cert content plus inode/mtime on the key.

On reload, Valkey re-validates the full material set before committing. If the new certs don't match their keys or have expired, the reload is rejected and the old context keeps serving - a bad push won't black-hole connections. INFO exposes `tls_server_cert_expire_time`, `tls_client_cert_expire_time`, `tls_ca_cert_expire_time` plus `tls_*_expires_in_seconds` for alerting.

### Separate outbound client cert

When `tls-client-cert-file` / `tls-client-key-file` are set, Valkey builds a second `SSL_CTX` just for outbound connections (replication, cluster bus, module-originated connections). Without them, the server cert is reused for both directions - fine for internal-only clusters, but breaks the principle-of-least-privilege if that cert leaks.

## TLS for replication and cluster bus

```
tls-replication yes    # primary <-> replica
tls-cluster     yes    # cluster bus (gossip + migration)
```

Both need to be set on every node. When enabled, the cluster bus port (`port + 10000`) serves TLS too - clients that probe the bus port to validate reachability need TLS, not plaintext.

## TLS handshake offload to I/O threads

When `io-threads > 1`, `SSL_accept` runs on an I/O thread via `trySendAcceptToIOThreads`. Gated by `CONN_FLAG_ALLOW_ACCEPT_OFFLOAD`. Operators see this as the main thread staying responsive during a burst of new TLS connections that would otherwise CPU-bind the accept loop. No config knob - it's automatic when I/O threads are on.

## mTLS with ACL user mapping - minimal example

```
tls-port 6379
port 0
tls-cert-file  /etc/valkey/tls/server.crt
tls-key-file   /etc/valkey/tls/server.key
tls-ca-cert-file /etc/valkey/tls/ca.crt
tls-auth-clients yes
tls-auth-clients-user cn
tls-auto-reload-interval 3600
```

ACL user `alice` exists, connecting cert has `CN=alice` → authenticated as `alice` with no `AUTH alice <pw>` needed.

## Client connection

`valkey-cli` flags (`--tls`, `--cert`, `--key`, `--cacert`) and `valkeys://` URI scheme are stock. Same as Redis with renamed command.
