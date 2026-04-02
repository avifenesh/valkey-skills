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
| Commandlog configured | `CONFIG GET commandlog-execution-slower-than` |
| Sentinel user has `+failover` | `ACL GETUSER sentinel` (Valkey 9.0+) |
| TLS for replication | `CONFIG GET tls-replication` |

## Security Checklist

Bind to specific interfaces, set firewall rules for port 6379 and cluster bus (16379), disable or restrict default user, use per-service ACL users, enable TLS, run as `valkey` user (not root), monitor `ACL LOG`.
