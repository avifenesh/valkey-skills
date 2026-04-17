# Security Hardening

Use when hardening a Valkey deployment - defense in depth, protected mode, network security, process isolation.

Standard Redis hardening applies - bind to specific interfaces, TLS, ACLs, unprivileged user, firewall rules. See Redis security docs for full guidance.

## Valkey-Specific Names

- Binary runs as `valkey` user (not `redis`)
- Config at `/etc/valkey/valkey.conf`
- Data at `/var/lib/valkey/`
- Protected mode behavior is identical to Redis

## Protected Mode

Valkey auto-enables protected mode when no password is set and binding to all interfaces. Sentinel disables protected mode at startup (it must accept external connections).

## Checklist Items Specific to Valkey

| Check | Command |
|-------|---------|
| COMMANDLOG thresholds set | `CONFIG GET commandlog-execution-slower-than` |
| TLS for replication + cluster bus | `CONFIG GET tls-replication tls-cluster` |
| TLS auto-reload enabled | `CONFIG GET tls-auto-reload-interval` |
| Default user disabled or password-only | `ACL GETUSER default` |

## Security Checklist

Bind to specific interfaces, set firewall rules for port 6379 and cluster bus (16379), disable or restrict default user, use per-service ACL users, enable TLS, run as `valkey` user (not root), monitor `ACL LOG`.
