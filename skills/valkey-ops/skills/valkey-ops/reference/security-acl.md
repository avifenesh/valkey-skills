# ACL Configuration

Use when setting up access control. Redis-standard ACL model (`ACL SETUSER`, categories, selectors, `aclfile`) applies; this file covers Valkey-specific operational knobs.

## Valkey-only ACL pieces

- **`alldbs` / `resetdbs` and per-DB selectors**: restrict a user to specific databases. Absent from Redis. Grep `alldbs` in `src/acl.c` to see the registered tokens.
- **`%R~pattern`** / **`%W~pattern`**: split read-only vs write-only key access on the same user. Redis has a single `~pattern`; Valkey lets you differentiate.
- **Cert-to-user mapping via TLS**: `tls-auth-clients-user cn` / `uri` maps the connecting cert's subject directly to an ACL user. The user must already exist - otherwise the connection is rejected. See `security-tls.md`.

## Sentinel user

Sentinel's monitoring and failover commands need access to `multi`, `exec`, `subscribe`, `publish`, `replicaof` (aliased from `slaveof`), `ping`, `info`, `role`, `config|rewrite`, `client|setname`, `client|kill`, `script|kill`. Standard categories (`@admin`, `@dangerous`, `@slow`) contain the heavier items - an explicit per-command grant matches what Sentinel actually invokes and avoids over-permissioning.

```
ACL SETUSER sentinel on >pw allchannels \
    +multi +exec +subscribe +publish +replicaof \
    +ping +info +role +config|rewrite \
    +client|setname +client|kill +script|kill
```

`FAILOVER` and `CLUSTER FAILOVER` use the standard `@admin` / `@dangerous` / `@slow` categories - no special permission beyond what any admin command needs.

## Default user

Redis-standard: full access unless restricted.

```
ACL SETUSER default off                 # disable entirely
ACL SETUSER default on >pw -@all +@connection  # keep AUTH path but deny everything else
```

When `requirepass` is set, it becomes the password on the `default` user. Prefer named ACL users over `requirepass` in modern deployments.

## Persistence

```
aclfile /etc/valkey/users.acl    # immutable - restart required to toggle
```

Runtime: `ACL LOAD` re-reads the file, `ACL SAVE` writes current state to it. Use one or the other (aclfile or inline-in-valkey.conf) - mixing leads to `ACL REWRITE` surprises.

## Monitoring

```
valkey-cli ACL LOG [COUNT N | RESET]   # denial audit trail
valkey-cli ACL WHOAMI                  # this connection's user
valkey-cli ACL LIST / GETUSER <name>
```

Alert on `ACL LOG` entries growing - it's the signal that a service is attempting operations its ACL doesn't allow (legitimate rollout mismatch, or an attacker probing).
