# Security Hardening

Use when hardening a Valkey deployment - defense in depth, protected mode,
restricting dangerous commands, network security, and pre-production security
audits.

Source-verified against `src/config.c`, `src/networking.c`, `src/acl.c`,
and `src/server.h` in valkey-io/valkey.

---

## Defense in Depth Layers

Security should be applied at every layer. No single control is sufficient.

| Layer | Control | Implementation |
|-------|---------|----------------|
| 1. Network | VPC / firewall | Restrict port 6379 to trusted IPs only |
| 2. Binding | Interface restriction | `bind 127.0.0.1` or specific internal IPs |
| 3. Authentication | ACLs | Per-user credentials and permissions |
| 4. Authorization | Command/key restrictions | Least-privilege ACL rules per role |
| 5. Encryption | TLS in transit | `tls-port` with `port 0` |
| 6. Process isolation | Unprivileged user | Run as `valkey` user, not root |
| 7. Monitoring | Audit logging | ACL LOG, commandlog, connection tracking |

---

## Protected Mode

When Valkey starts with default configuration (no password, binding to all
interfaces), protected mode activates automatically. It rejects commands from
non-loopback connections with a detailed error message.

Verified in `src/networking.c`: protected mode triggers when
`server.protected_mode` is true AND the default user has `USER_FLAG_NOPASS`.

```
# Default: enabled
protected-mode yes
```

Protected mode is automatically satisfied (and connections are allowed) when
either:
- A password is set via `requirepass` or ACL
- Valkey is bound to specific interfaces via `bind`

Sentinel disables protected mode at startup (`server.protected_mode = 0` in
`src/sentinel.c`) because sentinels must accept external connections.

To disable explicitly (not recommended for production):

```
CONFIG SET protected-mode no
```

---

## Network Security

### Bind to specific interfaces

```
# valkey.conf
bind 127.0.0.1 -::1              # localhost only
bind 10.0.1.5                     # specific internal IP
bind 10.0.1.5 127.0.0.1           # internal + localhost
```

Never use `bind 0.0.0.0` in production unless behind a firewall and using
TLS + authentication.

### Disable plaintext port when using TLS

```
tls-port 6379
port 0
```

### TCP settings

```
tcp-backlog 511          # match with net.core.somaxconn
tcp-keepalive 300        # detect dead connections (seconds)
timeout 300              # close idle clients after 5 minutes (0 = disabled)
maxclients 10000         # connection limit
```

### Firewall rules (iptables example)

```bash
# Allow Valkey only from application subnet
iptables -A INPUT -p tcp --dport 6379 -s 10.0.1.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 6379 -j DROP

# Allow cluster bus (port + 10000) only between cluster nodes
iptables -A INPUT -p tcp --dport 16379 -s 10.0.2.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 16379 -j DROP
```

---

## Restricting Dangerous Commands

The `@dangerous` category (defined in `src/acl.c`, bit 17 in `src/server.h`)
includes commands that can cause data loss, resource exhaustion, or security
issues. Commands tagged `@dangerous` include cluster mutation commands
(`CLUSTER ADDSLOTS`, `CLUSTER FAILOVER`, `CLUSTER FLUSHSLOT`, etc.),
`FLUSHDB`, `FLUSHALL`, `KEYS`, `DEBUG`, `CONFIG`, `SHUTDOWN`, `REPLICAOF`,
`MONITOR`, `SLOWLOG`, `CLIENT`, `BGREWRITEAOF`, and others.

### Block dangerous commands for application users

```
ACL SETUSER app on >password +@all -@dangerous -@scripting ~*
```

### Block specific high-risk commands

```
# Rename away dangerous commands (legacy approach, ACLs preferred)
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command DEBUG ""
rename-command KEYS ""
```

### Replace KEYS with SCAN

`KEYS *` blocks the server while scanning all keys. Always use `SCAN` instead:

```
# Bad - blocks the server
KEYS user:*

# Good - cursor-based iteration
SCAN 0 MATCH user:* COUNT 100
```

Block `KEYS` for all application users:

```
ACL SETUSER app on >password +@all -keys ~*
```

---

## Process Security

### Run as unprivileged user

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin valkey
sudo chown -R valkey:valkey /var/lib/valkey /var/log/valkey /etc/valkey
```

### Systemd hardening

```ini
[Service]
User=valkey
Group=valkey
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=full
ReadWriteDirectories=/var/lib/valkey /var/log/valkey /var/run/valkey
NoNewPrivileges=yes
```

### File permissions

```bash
chmod 640 /etc/valkey/valkey.conf    # owner + group read, no world
chmod 640 /etc/valkey/users.acl      # ACL file
chmod 600 /etc/valkey/tls/*.key      # private keys - owner only
chmod 750 /var/lib/valkey            # data directory
```

---

## CVE History - Top Vulnerabilities

Valkey inherits Redis attack surface. These are the highest-severity CVEs
operators should verify are patched.

| CVE / Advisory | CVSS | Description | Fix |
|----------------|------|-------------|-----|
| GHSA-9rfg-jx7v-52p6 | 9.8 | Lua use-after-free via GC - potential RCE | Valkey patched |
| GHSA-cjwh-fcpr-v5r7 | 9.8 | Stack buffer overflow in Lua bit library - potential RCE | 7.2.7, 8.0.1 |
| CVE-2015-4335 | 10.0 | Arbitrary Lua bytecode execution via EVAL | Redis < 2.8.21, < 3.0.2 |
| CVE-2018-11218 | 9.8 | Memory corruption in cmsgpack Lua library | Redis < 4.0.10, < 5.0-rc2 |
| CVE-2016-8339 | 9.8 | Buffer overflow via CONFIG SET client-output-buffer-limit | Redis < 3.2.4 |

Patch priority: Critical (CVSS >= 9.0) within 72 hours. High (7.0-8.9)
within 30 days. Subscribe to `github.com/valkey-io/valkey/security/advisories`.

---

## PCI DSS Key Mappings

| PCI Req | Control | Valkey Implementation |
|---------|---------|----------------------|
| 1.3 | Restrict public access | Network segmentation, never expose port to internet |
| 2.1 | Change vendor defaults | Disable or password-protect default user, change default port |
| 4.1 | Strong TLS in transit | `tls-port 6379`, `port 0`, TLS 1.2+ only |
| 7.1-7.2 | Need-to-know access | Per-user ACLs with key patterns and command restrictions |
| 8.1-8.5 | Unique user IDs | Named ACL users per service, no shared default user |
| 10.1-10.2 | Audit trail | ACL LOG, commandlog, syslog integration |
| 11.5 | Change detection | Monitor valkey.conf and ACL file for unauthorized changes |

---

## Credential Management

- Never commit passwords to version control
- Use environment variables or secret management tools (Vault, AWS Secrets Manager)
- Rotate passwords regularly
- Use `ACL GENPASS` to generate cryptographically secure passwords
- Prefer ACL-based authentication over `requirepass`

---

## Security Checklist

Run through this checklist before any production deployment:

| Check | Command / Action |
|-------|-----------------|
| Valkey bound to specific interfaces | `CONFIG GET bind` - should not be empty or `0.0.0.0` |
| Firewall restricts port 6379 | `iptables -L -n` or cloud security group review |
| Authentication enabled | `ACL LIST` - verify no `nopass` on default user |
| Default user restricted or disabled | `ACL GETUSER default` - check permissions |
| Application users have minimal permissions | `ACL GETUSER <name>` for each app user |
| TLS enabled for all connections | `CONFIG GET tls-port` returns non-zero, `CONFIG GET port` returns 0 |
| TLS for replication | `CONFIG GET tls-replication` returns `yes` |
| TLS for cluster bus | `CONFIG GET tls-cluster` returns `yes` (if using cluster) |
| Valkey runs as unprivileged user | `ps aux \| grep valkey` - should not be root |
| KEYS command blocked for apps | `ACL GETUSER app` - verify `-keys` or `-@dangerous` |
| No credentials in version control | Review `valkey.conf` and deployment scripts |
| ACL LOG monitored | `ACL LOG` - check for unexpected denials |
| Commandlog configured | `CONFIG GET commandlog-execution-slower-than` |

---

## See Also

- [ACL Configuration](acl.md) - per-user access control
- [TLS Configuration](tls.md) - encryption in transit
- [Command Restriction](rename-commands.md) - rename-command directive
- [Monitoring Metrics](../monitoring/metrics.md) - ACL LOG and connection tracking
- [Commandlog](../monitoring/commandlog.md) - slow command logging referenced in security checklist
- [Alerting Rules](../monitoring/alerting.md) - alerts for rejected connections and anomalies
- [Production Checklist](../production-checklist.md) - full security checklist
- [See valkey-dev: acl](../../../valkey-dev/reference/security/acl.md) - ACL internals
- [See valkey-dev: tls](../../../valkey-dev/reference/security/tls.md) - TLS internals
