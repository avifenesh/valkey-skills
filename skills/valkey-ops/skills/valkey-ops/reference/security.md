# Security

Use when setting up ACLs, TLS, hardening a deployment, or restricting commands. Redis-standard security model applies - this file covers Valkey-specific knobs.

## ACL - Valkey-only pieces

- **`alldbs` / `resetdbs` and per-DB selectors**: restrict a user to specific databases. Absent from Redis. `src/acl.c` registers these tokens.
- **`%R~pattern`** / **`%W~pattern`**: split read-only vs write-only key access on the same user. Redis has single `~pattern`; Valkey differentiates.
- **Cert-to-user mapping via TLS**: `tls-auth-clients-user cn` / `uri` maps the cert subject directly to an ACL user. User must already exist or connection is rejected. See below.

## ACL - default user

Full access unless restricted:

```
ACL SETUSER default off                        # disable entirely
ACL SETUSER default on >pw -@all +@connection  # keep AUTH path, deny everything else
```

When `requirepass` is set, it becomes the password on `default`. Prefer named ACL users over `requirepass`.

## ACL - Sentinel user

Sentinel needs `multi`, `exec`, `subscribe`, `publish`, `replicaof` (alias of `slaveof`), `ping`, `info`, `role`, `config|rewrite`, `client|setname`, `client|kill`, `script|kill`. Explicit per-command grant is tighter than `@admin`/`@dangerous`/`@slow` categories:

```
ACL SETUSER sentinel on >pw allchannels \
    +multi +exec +subscribe +publish +replicaof \
    +ping +info +role +config|rewrite \
    +client|setname +client|kill +script|kill
```

`FAILOVER` and `CLUSTER FAILOVER` use standard `@admin`/`@dangerous`/`@slow` - no special permission beyond what any admin command needs.

## ACL - persistence

```
aclfile /etc/valkey/users.acl    # immutable - restart required to toggle
```

Runtime: `ACL LOAD` re-reads, `ACL SAVE` writes current state. Use one or the other (aclfile OR inline-in-valkey.conf) - mixing leads to `ACL REWRITE` surprises.

## ACL - monitoring

```
valkey-cli ACL LOG [COUNT N | RESET]   # denial audit trail
valkey-cli ACL WHOAMI                  # this connection's user
valkey-cli ACL LIST / GETUSER <name>
```

Alert on `ACL LOG` entries growing - signals a service attempting operations its ACL doesn't allow (rollout mismatch or probing).

## TLS - build

```sh
make BUILD_TLS=yes    # built-in (recommended)
make BUILD_TLS=module # loadable - valkey-tls<SUFFIX>.so
```

Module mode lets you toggle TLS without rebuilding. Official Docker images ship with `BUILD_TLS=yes`.

## TLS - core config

`tls-port`, `tls-cert-file`, `tls-key-file`, `tls-ca-cert-file`/`tls-ca-cert-dir`, `tls-auth-clients` (`yes`/`no`/`optional`), `tls-replication`, `tls-cluster`. Runtime-modifiable. Disable plaintext with `port 0`. Default is TLS 1.2+1.3 only (via `tls-protocols`).

## TLS - `tls-auth-clients-user`

```
tls-auth-clients-user cn     # CN → ACL username
tls-auth-clients-user uri    # SAN URI → ACL username (SPIFFE-style)
tls-auth-clients-user off    # default - no mapping
```

Lets a connecting mTLS client skip `AUTH` entirely - cert subject maps directly to an ACL user. The user must already exist or connection is rejected. `uri` added in 9.0.

## TLS - `tls-auto-reload-interval`

```
tls-auto-reload-interval 3600   # seconds; 0 disables
```

Background thread watches cert/key files and reloads `SSL_CTX` in-place without restart. BIO thread parses new certs; main thread atomically swaps the context pointer. Change detection uses SHA-256 over cert content plus inode/mtime on the key.

On reload, Valkey re-validates the full material set before committing. Bad certs (mismatched key, expired) are rejected and the old context keeps serving - a bad push won't black-hole connections. INFO exposes `tls_server_cert_expire_time`, `tls_client_cert_expire_time`, `tls_ca_cert_expire_time` plus `tls_*_expires_in_seconds` for alerting.

## TLS - separate outbound client cert

When `tls-client-cert-file` / `tls-client-key-file` are set, Valkey builds a second `SSL_CTX` just for outbound connections (replication, cluster bus, module-originated). Without them, the server cert is reused both directions - fine for internal-only clusters, but breaks principle-of-least-privilege if the cert leaks.

## TLS - replication and cluster bus

```
tls-replication yes    # primary <-> replica
tls-cluster     yes    # cluster bus (gossip + migration)
```

Both need to be set on every node. When enabled, the cluster bus port (`port + 10000`) also serves TLS - clients probing the bus port for reachability need TLS, not plaintext.

## TLS - handshake offload

When `io-threads > 1`, `SSL_accept` runs on an I/O thread via `trySendAcceptToIOThreads` (gated by `CONN_FLAG_ALLOW_ACCEPT_OFFLOAD`). Operators see this as the main thread staying responsive during bursts of new TLS connections that would otherwise CPU-bind the accept loop. Automatic - no config knob.

## TLS - minimal mTLS + ACL example

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

ACL user `alice` exists, cert has `CN=alice` → authenticated as `alice` with no `AUTH` step.

## TLS - client connection

`valkey-cli` flags (`--tls`, `--cert`, `--key`, `--cacert`) and `valkeys://` URI scheme are stock.

## rename-command (legacy)

ACLs are strongly preferred - per-user, runtime-changeable, replication-safe, logged. `rename-command` is config-file-only, global, not runtime-modifiable, breaks AOF replay if names differ at replay vs recording, breaks replication if configs differ across nodes.

```
# Preferred
ACL SETUSER app on >password +@all -@dangerous ~*

# Legacy
rename-command FLUSHALL ""
rename-command DEBUG ""
```

Still useful for: default-user lockdown when legacy clients can't AUTH, defense in depth, or modules that bypass ACL checks.

## Protected mode

Auto-enables when no password is set and binding to all interfaces. Sentinel disables protected mode at startup (it must accept external connections - set in `sentinel.c`).

## Hardening checklist

- Bind to specific interfaces (not `0.0.0.0`)
- Firewall rules for `port` and cluster bus (`port + 10000`)
- Disable or restrict `default` user
- Per-service ACL users, never a shared superuser
- TLS for client, replication, and cluster bus
- `tls-auto-reload-interval` set (cert expiry won't black-hole you)
- Run as `valkey` user, not root
- Monitor `ACL LOG`
- `COMMANDLOG` thresholds set for audit trail
