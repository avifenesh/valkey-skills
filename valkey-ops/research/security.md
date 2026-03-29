# Valkey Security Hardening and ACL Best Practices - Research

Research date: 2026-03-29

## Sources Consulted

| Source | URL | Status |
|--------|-----|--------|
| Valkey Official Security Docs | https://valkey.io/topics/security/ | Fetched |
| Valkey ACL Documentation | https://valkey.io/topics/acl/ | Fetched |
| Valkey TLS Documentation | https://valkey.io/topics/tls/ | Fetched |
| Valkey Administration Guide | https://valkey.io/topics/admin/ | Fetched |
| Valkey Default Config (unstable) | github.com/valkey-io/valkey/blob/unstable/valkey.conf | Fetched |
| Valkey Security Advisories | github.com/valkey-io/valkey/security/advisories | Fetched (8 advisories) |
| NVD - Redis CVEs | services.nvd.nist.gov/rest/json/cves/2.0 | Fetched (40+ CVEs) |
| OWASP Database Security Cheat Sheet | cheatsheetseries.owasp.org | Fetched |
| OWASP NoSQL Security Cheat Sheet | cheatsheetseries.owasp.org | Fetched |
| OWASP Transport Layer Security Cheat Sheet | cheatsheetseries.owasp.org | Fetched |

---

## 1. Security Model and Attack Surface

### Core Security Model (from Valkey docs)

Valkey is designed to be accessed by **trusted clients inside trusted environments**. It should never be directly exposed to the internet. The application layer must mediate all access between Valkey and untrusted clients.

Key principles:
- Valkey is not designed for direct untrusted access
- An application layer implementing ACLs and input validation must sit between users and Valkey
- The protocol is binary-safe with prefixed-length strings, making injection impossible under normal client library use
- Lua scripts via EVAL/EVALSHA follow the same binary-safe rules but applications should avoid composing Lua from untrusted input

### Common Attack Vectors and Mitigations

| Attack Vector | Description | Mitigation |
|---------------|-------------|------------|
| Unauthenticated access | Exposed port with no auth | Enable ACLs, use `requirepass` at minimum, enable protected mode |
| Data destruction | `FLUSHALL` from external attacker | ACLs restricting `@dangerous` commands, network segmentation |
| Hash collision DoS | Crafted inputs causing O(N) hash operations | Valkey uses per-execution pseudo-random hash seeds |
| SORT worst-case DoS | Quadratic qsort behavior via crafted input | Restrict SORT to trusted users, limit key sizes |
| Eavesdropping | AUTH command sent unencrypted | Enable TLS on all connections |
| Lua RCE | Malicious Lua scripts exploiting GC or buffer overflows | ACL-restrict EVAL/EVALSHA, patch to latest version |
| Cluster bus injection | Malformed cluster bus packets | Isolate cluster bus port, patch advisories |
| Output buffer exhaustion | Unauthenticated client causing unbounded buffer growth | Set `client-output-buffer-limit`, require auth |
| Pattern matching DoS | Long match patterns causing stack overflow | Patch to 7.2.7+/8.0.1+, restrict KEYS/SCAN usage |

### Protected Mode

When Valkey starts with default configuration (binding all interfaces, no password), it enters **protected mode**: only responds to loopback queries. External clients receive an error with configuration instructions. This provides baseline protection against accidental exposure but should not be relied upon as the sole security measure.

---

## 2. Access Control Lists (ACL) - Complete Reference

### ACL Rule Syntax

**User lifecycle:**
- `on` - Enable user (authentication allowed)
- `off` - Disable user (new auth blocked, existing connections persist)
- `reset` - Full reset: resetpass, resetkeys, resetchannels, allchannels (if acl-pubsub-default set), off, clearselectors, -@all

**Command permissions:**
- `+<command>` - Allow command (supports `|` for subcommands: `+config|get`)
- `-<command>` - Deny command (supports `|` for subcommands: `-config|set`)
- `+@<category>` - Allow all commands in category
- `-@<category>` - Deny all commands in category
- `allcommands` - Alias for `+@all`
- `nocommands` - Alias for `-@all`

**Key permissions:**
- `~<pattern>` - Glob-style key pattern (read+write)
- `%R~<pattern>` - Read-only key pattern
- `%W~<pattern>` - Write-only key pattern
- `%RW~<pattern>` - Alias for `~<pattern>`
- `allkeys` - Alias for `~*`
- `resetkeys` - Flush all key patterns

**Pub/Sub channel permissions:**
- `&<pattern>` - Allow access to matching channels
- `allchannels` - Alias for `&*`
- `resetchannels` - Flush all channel patterns

**Password management:**
- `><password>` - Add plaintext password (hashed to SHA-256 internally)
- `<<password>` - Remove password
- `#<hash>` - Add pre-hashed SHA-256 password (64 hex chars)
- `!<hash>` - Remove hashed password
- `nopass` - No password required (any password accepted)
- `resetpass` - Flush all passwords, remove nopass

**Selectors:**
- `(<rule list>)` - Create additional permission selector
- `clearselectors` - Remove all selectors

### Command Categories

| Category | Description | Key Commands Included |
|----------|-------------|----------------------|
| **admin** | Administrative commands | REPLICAOF, CONFIG, DEBUG, SAVE, MONITOR, ACL, SHUTDOWN |
| **dangerous** | Commands needing careful consideration | FLUSHALL, MIGRATE, RESTORE, SORT, KEYS, CLIENT, DEBUG, INFO, CONFIG, SAVE, REPLICAOF |
| **read** | Commands that read key data | GET, MGET, HGETALL, LRANGE, SMEMBERS, etc. |
| **write** | Commands that write key data | SET, DEL, HSET, LPUSH, SADD, etc. |
| **keyspace** | Type-agnostic key/db operations | DEL, RESTORE, DUMP, RENAME, EXISTS, DBSIZE, KEYS, EXPIRE, TTL, FLUSHALL |
| **connection** | Connection management | AUTH, SELECT, COMMAND, CLIENT, ECHO, PING |
| **scripting** | Scripting related | EVAL, EVALSHA, SCRIPT |
| **pubsub** | Pub/Sub related | PUBLISH, SUBSCRIBE, PSUBSCRIBE |
| **transaction** | Transaction related | WATCH, MULTI, EXEC |
| **blocking** | Potentially blocking | BLPOP, BRPOP, BLMOVE, BZPOPMIN |
| **fast** | O(1) commands | Most single-key operations |
| **slow** | Non-fast commands | KEYS, SORT, aggregate operations |
| **string/hash/list/set/sortedset/stream/bitmap/hyperloglog/geo** | Data-type specific | Respective data type commands |

### Production ACL Role Patterns

#### Read-only application user
```
user app-readonly on >STRONG_PASSWORD_HERE ~app:* &app:* -@all +@read +@connection +ping
```

#### Read-write application user (no dangerous commands)
```
user app-readwrite on >STRONG_PASSWORD_HERE ~app:* &app:* +@all -@admin -@dangerous
```

#### Cache-only user (GET/SET/DEL with TTL, specific key prefix)
```
user cache-worker on >STRONG_PASSWORD_HERE ~cache:* -@all +get +set +del +expire +ttl +exists +ping
```

#### Queue worker (list operations on job keys)
```
user worker on >STRONG_PASSWORD_HERE ~jobs:* -@all +@list +@connection +ping +del
```

#### Pub/Sub only user
```
user pubsub-client on >STRONG_PASSWORD_HERE resetchannels &notifications:* -@all +subscribe +publish +ping
```

#### Monitoring/observability user
```
user monitor on >STRONG_PASSWORD_HERE -@all +info +ping +client|list +slowlog|get +latency|latest +dbsize +memory|usage +memory|stats
```

#### Sentinel user (minimum required permissions)
```
user sentinel-user on >STRONG_PASSWORD_HERE allchannels +multi +slaveof +ping +exec +subscribe +config|rewrite +role +publish +info +client|setname +client|kill +script|kill
```

#### Replica user (minimum required permissions)
```
user replica-user on >STRONG_PASSWORD_HERE +psync +replconf +ping
```

#### Admin user (full access but explicit, separate from default)
```
user admin-user on >VERY_STRONG_PASSWORD_HERE ~* &* +@all
```

#### Locked-down default user
```
user default on >STRONG_PASSWORD_HERE ~* &* +@all -@admin -@dangerous
```

Or fully disabled default user:
```
user default off
```

### ACL File Management

Two mutually exclusive methods:
1. **Inline in valkey.conf** - Use `user <username> ... acl rules ...` directives; persist via `CONFIG REWRITE`
2. **External ACL file** - Set `aclfile /etc/valkey/users.acl`; manage via `ACL LOAD` / `ACL SAVE`

The external file is recommended for complex environments. The format is identical. `ACL LOAD` validates all users atomically - if any user definition is invalid, the entire load fails and the old configuration remains.

### ACL Audit Logging

```
acllog-max-len 128
```

The `ACL LOG` command tracks failed commands and authentication events. Use it for:
- Troubleshooting permission denials
- Detecting brute-force auth attempts
- Identifying misconfigured application permissions

Generate strong passwords:
```
ACL GENPASS
```
Produces 256-bit cryptographically random hex string. Always use this rather than human-created passwords.

### Selectors for Complex Permission Models

Selectors allow multiple independent permission sets per user. Evaluated after root permissions, in order of definition.

Example - user that can GET from one prefix and SET in another:
```
ACL SETUSER app-user on >pass +GET ~readonly:* (+SET ~writable:*)
```

Cross-key operations example (COPY from source to destination):
```
ACL SETUSER app-user on >pass +@all ~app1:* %R~app2:*
```

### Key Permission Granularity

- `%R~<pattern>` - Read-only: data from key is read, copied, or returned
- `%W~<pattern>` - Write-only: data in key is updated or deleted
- Full access: `~<pattern>` or `%RW~<pattern>`

Metadata operations (STRLEN, TYPE, SISMEMBER, EXISTS) do not require read permission - only that the user has some key access.

---

## 3. TLS Configuration and Certificate Management

### Enabling TLS

Compile Valkey with TLS support (optional build flag), then configure:

```
# Disable plaintext, enable TLS on default port
port 0
tls-port 6379

# Server certificate and key
tls-cert-file /path/to/valkey.crt
tls-key-file /path/to/valkey.key

# CA certificate for peer verification
tls-ca-cert-file /path/to/ca.crt
# OR directory of CA certs:
# tls-ca-cert-dir /etc/ssl/certs
```

### Mutual TLS (mTLS) - Client Certificate Authentication

```
# Server-side client cert + key for outgoing connections (replication, cluster)
tls-client-cert-file /path/to/client.crt
tls-client-key-file /path/to/client.key

# Require client certificates (default: yes)
tls-auth-clients yes
# Options: yes | no | optional
```

### Certificate-Based User Authentication

Map TLS client certificates directly to Valkey ACL users:
```
tls-auth-clients-user URI
```
When enabled, Valkey extracts a field from the client certificate's Subject Alternative Name (SAN) and matches it to ACL usernames. Create passwordless users for cert-only auth:
```
ACL SETUSER client-user on allcommands allkeys
```

### TLS Protocol and Cipher Configuration

```
# Protocol versions (default: TLSv1.2 TLSv1.3 - KEEP THIS)
tls-protocols "TLSv1.2 TLSv1.3"

# TLS 1.2 cipher suites
tls-ciphers DEFAULT:!MEDIUM

# TLS 1.3 cipher suites
tls-ciphersuites TLS_CHACHA20_POLY1305_SHA256

# Prefer server cipher order
tls-prefer-server-ciphers yes

# DH parameters for DHE key exchange
tls-dh-params-file /path/to/valkey.dh

# Session caching (enabled by default)
tls-session-caching yes
tls-session-cache-size 5000
tls-session-cache-timeout 60
```

### Recommended Cipher Suite Configuration

Based on OWASP TLS Cheat Sheet guidance, for Valkey specifically:

**TLS 1.3 (preferred):**
```
tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
```

**TLS 1.2 (compatibility):**
```
tls-ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
```

**Cipher requirements:**
- Only GCM or ChaCha20-Poly1305 AEAD ciphers
- ECDHE or DHE for forward secrecy
- No CBC, RC4, DES, 3DES, MD5, SHA-1 ciphers
- No EXPORT or NULL ciphers
- No anonymous ciphers

### Certificate Rotation

Automatic reload (new in Valkey):
```
# Reload TLS materials every 24 hours
tls-auto-reload-interval 86400
```

Valkey validates all TLS materials on load/reload:
- Files and directories are not empty or malformed
- Certificates match their private keys
- Certificates are within their validity period

If validation fails, the reload is rejected and existing materials remain in use.

### Replication and Cluster TLS

```
# Replicas use TLS for outgoing connections to primary
tls-replication yes

# Cluster bus uses TLS
tls-cluster yes
```

Sentinel inherits TLS config from common Valkey configuration. `tls-replication` controls both Sentinel-to-primary connections and Sentinel-to-Sentinel connections.

### Certificate Best Practices (from OWASP)

- Use RSA 2048-bit minimum or ECDSA P-256+ keys
- Use SHA-256 for certificate hashing (not MD5 or SHA-1)
- Use internal CA for internal services (avoid exposing FQDNs to public CAs)
- Set CAA DNS records to restrict which CAs can issue certificates
- Avoid wildcard certificates across trust boundaries
- Use ACME (Let's Encrypt) for automated certificate management where applicable
- Store private keys with restrictive filesystem permissions (0600, owned by valkey user)
- Monitor certificate expiry and automate renewal

---

## 4. CVE History - Redis/Valkey Security Advisories

### Valkey-Specific Security Advisories (from GitHub)

| Advisory | Severity | Description | Fix Version |
|----------|----------|-------------|-------------|
| GHSA-93p9-5vc7-8wgr | High | Pre-authentication DoS via empty request causing assertion failure | Patched |
| GHSA-c677-q3wr-gggq | High | Remote DoS via malformed cluster bus message causing out-of-bounds read | Patched |
| GHSA-p876-p7q5-hv2m | Medium | RESP protocol injection via Lua error_reply null character handling | Patched |
| GHSA-9rfg-jx7v-52p6 | Critical | Lua use-after-free via GC manipulation - potential RCE | Patched |
| GHSA-24vm-hv6g-2mj5 | High | DoS via unlimited output buffer growth by unauthenticated client | Patched |
| GHSA-p4rf-xgfj-c2gq | High | DoS via unbounded pattern matching on KEYS, SCAN, PSUBSCRIBE, FUNCTION LIST, COMMAND LIST, ACL definitions | 7.2.7, 8.0.1 |
| GHSA-3864-2g29-c6pm | Medium | DoS via malformed ACL selectors triggering server panic | 7.2.7, 8.0.1 |
| GHSA-cjwh-fcpr-v5r7 | Critical | Stack buffer overflow in Lua bit library - potential RCE | 7.2.7, 8.0.1 |

### Critical Redis CVEs (Inherited Attack Surface)

Since Valkey is forked from Redis, these historical CVEs represent the inherited attack surface. Operators should verify their Valkey version includes fixes for all applicable issues.

| CVE | Year | CVSS | Description |
|-----|------|------|-------------|
| CVE-2015-4335 | 2015 | 10.0 | Arbitrary Lua bytecode execution via eval command (Redis < 2.8.21, < 3.0.2) |
| CVE-2016-8339 | 2016 | 9.8 | Buffer overflow via CONFIG SET client-output-buffer-limit (Redis 3.2.x < 3.2.4) |
| CVE-2016-10517 | 2016 | 7.4 | Cross-protocol scripting via missing POST/Host header check |
| CVE-2017-15047 | 2017 | 9.8 | OOB array index in clusterLoadConfig (Redis 4.0.2) |
| CVE-2018-11218 | 2018 | 9.8 | Memory corruption in cmsgpack Lua library - stack buffer overflow |
| CVE-2018-11219 | 2018 | 9.8 | Integer overflow in struct Lua library - bounds checking failure |
| CVE-2018-12326 | 2018 | 8.4 | Buffer overflow in redis-cli |
| CVE-2018-12453 | 2018 | 7.5 | Type confusion in XGROUP command (streams) |
| CVE-2021-32675 | 2021 | 7.5 | RESP request parsing DoS via multi-bulk header allocation |

### Patch Priority Matrix

**Immediate (CVSS >= 9.0):**
- Any Lua subsystem RCE (CVE-2015-4335, CVE-2018-11218, CVE-2018-11219, GHSA-9rfg-jx7v-52p6, GHSA-cjwh-fcpr-v5r7)
- Buffer overflow RCE (CVE-2016-8339, CVE-2017-15047)

**High Priority (CVSS 7.0-8.9):**
- Pre-auth DoS (GHSA-93p9-5vc7-8wgr, GHSA-24vm-hv6g-2mj5)
- Cluster bus attacks (GHSA-c677-q3wr-gggq)
- Pattern matching DoS (GHSA-p4rf-xgfj-c2gq)
- Cross-protocol scripting (CVE-2016-10517)

**Medium Priority (CVSS 4.0-6.9):**
- Protocol injection (GHSA-p876-p7q5-hv2m)
- ACL selector crashes (GHSA-3864-2g29-c6pm)
- CLI vulnerabilities (CVE-2018-12326)

---

## 5. OWASP Guidance for In-Memory Data Stores

### From OWASP Database Security Cheat Sheet

**Protecting the backend database:**
- Isolate from other servers, connect with as few hosts as possible
- Disable network (TCP) access where possible; use unix sockets
- Bind to localhost or specific internal IPs
- Restrict access with firewall rules
- Place database in separate DMZ from application servers
- Never allow direct thick-client connections to the database

**Transport layer protection:**
- Configure database to only allow encrypted connections
- Use TLSv1.2+ with AEAD ciphers (AES-GCM or ChaCha20-Poly1305)
- Verify server certificate from client side
- Install trusted certificates (not self-signed in production)

**Secure authentication:**
- Always require authentication, including from localhost
- Use strong, unique passwords per service account
- Configure minimum required permissions
- Regular access reviews and decommissioning

**Credentials storage:**
- Never hardcode credentials in application code
- Use secret managers (Vault, AWS Secrets Manager, Azure Key Vault)
- Avoid baking credentials into container images
- Rotate credentials regularly

**Permissions - Principle of Least Privilege:**
- Do not use built-in root/admin/default accounts for applications
- Create specific accounts per service
- Grant only the minimum commands and key patterns needed
- Separate admin, backup, monitoring, and application accounts

### From OWASP NoSQL Security Cheat Sheet

**Threats specific to NoSQL/in-memory stores:**
- Exposed management interfaces (admin ports, REST endpoints)
- Weak or no authentication with default open access
- Insecure network exposure (no TLS, open ports, no segmentation)
- Insecure defaults (default admin accounts, unsecured configs)
- Poor access control models (coarse roles enabling lateral abuse)
- Unsafe server-side code execution (Lua scripting)
- Credential and secret leaks in code, images, CI logs
- Unsafe backup exposure (unencrypted, publicly accessible)

**NoSQL Security Checklist (adapted for Valkey):**
- [ ] Enable authentication and RBAC (ACLs)
- [ ] Enforce TLS for client and node communication
- [ ] Bind to internal IPs / use private networks
- [ ] Use least-privilege service accounts
- [ ] Restrict dangerous commands via ACL categories
- [ ] Restrict Lua scripting (EVAL/EVALSHA) to trusted users only
- [ ] Store credentials in secret manager and rotate them
- [ ] Harden configuration (disable unsafe defaults)
- [ ] Encrypt and secure RDB/AOF backups
- [ ] Monitor and audit access and admin actions
- [ ] Keep Valkey and client libraries patched

---

## 6. Compliance Considerations

### PCI DSS Requirements Applicable to Valkey

| Requirement | PCI DSS Control | Valkey Implementation |
|-------------|----------------|----------------------|
| 1.3 | Restrict direct public access to cardholder data | Network segmentation; never expose Valkey port to internet |
| 2.1 | Change vendor defaults | Disable default user or set strong password; change default port |
| 2.2.4 | Configure system security parameters | Harden valkey.conf per this guide |
| 3.4 | Render PAN unreadable wherever stored | Do not store raw PAN in Valkey; use tokenization. If caching card data, use application-level encryption |
| 4.1 | Use strong TLS for transmission | Enable `tls-port`, disable `port 0`, use TLS 1.2+ only |
| 6.2 | Patch known vulnerabilities | Maintain Valkey at latest patch level; monitor CVEs and advisories |
| 7.1 | Limit access on need-to-know | ACL per-user key patterns and command restrictions |
| 7.2 | Restrict access based on job function | Separate ACL users per application/service role |
| 8.1 | Unique ID per user | Named ACL users (not shared default user) |
| 8.2 | Strong authentication | `ACL GENPASS` for 256-bit passwords; mTLS where possible |
| 8.5 | No shared/generic accounts | Unique ACL user per service |
| 10.1 | Audit trail for access | `ACL LOG`, Valkey slow log, OS-level audit logging |
| 10.2 | Automated audit trail | Log all admin actions via ACL LOG + external SIEM |
| 10.5 | Secure audit trails | Forward logs to tamper-evident SIEM; restrict local log access |
| 11.5 | Change-detection | Monitor valkey.conf and ACL file for unauthorized changes |

**PCI DSS TLS requirement:** PCI DSS explicitly forbids TLS 1.0. Use TLS 1.2 minimum, prefer TLS 1.3.

### SOC 2 Trust Service Criteria

| Criteria | Valkey Controls |
|----------|----------------|
| CC6.1 - Logical access | ACLs with per-user permissions, key patterns, command restrictions |
| CC6.2 - Authentication | Strong passwords via ACL GENPASS, mTLS certificate auth |
| CC6.3 - Access authorization | Principle of least privilege via ACL command categories and key patterns |
| CC6.6 - System boundaries | Network segmentation, bind to internal interfaces, firewall rules |
| CC7.1 - Monitoring | ACL LOG, slow log, OS audit logging, SIEM integration |
| CC7.2 - Anomaly detection | Monitor for failed auth attempts, unusual command patterns |
| CC8.1 - Change management | Version-controlled valkey.conf and ACL files, CONFIG REWRITE auditing |
| A1.1 - Availability | Sentinel/Cluster HA, persistence (RDB/AOF), replica promotion |

### GDPR Considerations

| GDPR Principle | Valkey Implementation |
|---------------|----------------------|
| Data minimization | Use TTLs aggressively; cache only necessary data |
| Purpose limitation | Separate Valkey instances or ACL-isolated key namespaces per purpose |
| Storage limitation | `maxmemory` with eviction policies; TTLs on all personal data keys |
| Integrity and confidentiality | TLS in transit; ACLs for access control; no personal data in key names |
| Data subject rights (erasure) | Application-level DEL commands; document key patterns containing personal data |
| Data breach notification | ACL LOG monitoring; SIEM alerting on suspicious access patterns |
| Data protection by design | Encrypt personal data at the application layer before storing in Valkey |
| International transfers | Ensure Valkey instances are in compliant regions; TLS for any cross-region replication |

---

## 7. Network Segmentation Patterns

### Reference Architecture - Single Region

```
                    Internet
                       |
                  [WAF / LB]
                       |
                  [App Tier]  <-- DMZ / Public Subnet
                       |
               [Security Group]  <-- Only allow App Tier IPs on port 6379
                       |
                [Valkey Tier]  <-- Private Subnet (no internet route)
                       |
               [Security Group]  <-- Only allow Valkey-to-Valkey (cluster bus 16379)
                       |
              [Valkey Replicas]  <-- Separate AZ for HA
```

### Network Controls

**Firewall rules (iptables/nftables/security groups):**
```
# Only allow application servers to connect
iptables -A INPUT -p tcp --dport 6379 -s 10.0.1.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 6379 -j DROP

# Cluster bus - only other Valkey nodes
iptables -A INPUT -p tcp --dport 16379 -s 10.0.2.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 16379 -j DROP

# Sentinel - only other sentinels and app servers
iptables -A INPUT -p tcp --dport 26379 -s 10.0.1.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 26379 -s 10.0.2.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 26379 -j DROP
```

**Bind configuration:**
```
# Bind to specific internal interface only
bind 10.0.2.10

# Or bind to localhost + internal interface
bind 127.0.0.1 10.0.2.10
```

### Kubernetes Network Policies

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: valkey-ingress
  namespace: data
spec:
  podSelector:
    matchLabels:
      app: valkey
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              tier: application
        - podSelector:
            matchLabels:
              app: valkey  # Allow cluster peer communication
      ports:
        - protocol: TCP
          port: 6379
        - protocol: TCP
          port: 16379  # Cluster bus
```

### Segmentation Best Practices

- Place Valkey in a dedicated private subnet with no internet gateway
- Use separate security groups for client access (6379) and cluster bus (16379)
- Sentinel should be in the same network zone as Valkey nodes
- Monitoring systems should access via read-only ACL user through a bastion/jump host
- Never expose Valkey ports via public load balancers
- Use VPC peering or private link for cross-VPC access
- In multi-tenant environments, use separate Valkey instances per tenant (not just ACL isolation)

---

## 8. Audit Logging and Forensics

### Built-in Logging Capabilities

**ACL LOG - Failed command and auth tracking:**
```
# Set maximum log entries
acllog-max-len 128

# View recent failures
ACL LOG [count]

# Reset the log
ACL LOG RESET
```

ACL LOG entries include:
- Timestamp
- Username
- Client info (IP, port)
- Reason (auth failure, command denied, key denied)
- The command that was denied

**Slow Log - Performance audit trail:**
```
# Log commands exceeding 10ms
slowlog-log-slower-than 10000

# Keep last 128 entries
slowlog-max-len 128

# View entries
SLOWLOG GET [count]
```

**MONITOR command - Real-time command stream:**
```
# Stream all commands (use only for debugging, significant performance impact)
MONITOR
```
WARNING: MONITOR has significant performance overhead (up to 50% throughput reduction). Use only for short debugging sessions, never in continuous production monitoring.

**CLIENT LIST - Connection audit:**
```
CLIENT LIST
```
Returns: connection ID, IP, port, name, age, idle time, flags, database, commands processed, authenticated user.

### External Audit Logging Strategy

**Valkey log file configuration:**
```
# Log level: debug, verbose, notice, warning
loglevel notice

# Log file path
logfile /var/log/valkey/valkey.log

# Syslog integration
syslog-enabled yes
syslog-ident valkey
syslog-facility local0
```

**Log aggregation pipeline:**
1. Valkey writes to syslog or log file
2. Log shipper (Filebeat, Fluentd, Vector) collects and forwards
3. SIEM/log platform (Elasticsearch, Splunk, Datadog) indexes and alerts
4. Alert rules trigger on: failed auth patterns, dangerous command execution, configuration changes

### Forensic Indicators to Monitor

| Indicator | Detection Method | Response |
|-----------|-----------------|----------|
| Brute-force auth attempts | ACL LOG entries with repeated auth failures from same IP | Rate limit, block IP, investigate |
| Unauthorized command execution | ACL LOG entries for denied commands | Review ACL configuration, investigate intent |
| Data exfiltration | Unusual DUMP, MIGRATE, or large SCAN operations | Alert, review access patterns |
| Configuration tampering | CONFIG SET commands in audit log | Restrict CONFIG to admin users only |
| Unusual connection patterns | CLIENT LIST showing unexpected IPs or high connection count | Review firewall rules, investigate |
| Persistence manipulation | BGSAVE, BGREWRITEAOF from non-admin users | Restrict persistence commands via ACL |
| Replication hijacking | REPLICAOF commands from unexpected sources | Restrict REPLICAOF via ACL, monitor replication status |

### RDB/AOF Forensics

- RDB snapshots capture point-in-time state - preserve as evidence
- AOF files contain full command history - critical for forensic reconstruction
- Protect backup files: restrict filesystem access, encrypt at rest
- Timestamp correlation: use NTP-synchronized clocks across all nodes
- Preserve `dump.rdb` and `appendonly.aof` files as forensic artifacts during incident response

---

## 9. Comprehensive Security Hardening Checklist

### Pre-Deployment

- [ ] Build Valkey with TLS support enabled
- [ ] Create dedicated `valkey` system user (non-root, no login shell)
- [ ] Set restrictive file permissions on valkey.conf (0640), ACL file (0640), data directory (0750)
- [ ] Generate TLS certificates (minimum RSA 2048 or ECDSA P-256)
- [ ] Plan ACL user structure per application role
- [ ] Generate strong passwords with `ACL GENPASS`

### valkey.conf Hardening

```
# --- Network ---
bind 127.0.0.1 <internal-ip>
protected-mode yes
port 0

# --- TLS ---
tls-port 6379
tls-cert-file /etc/valkey/tls/valkey.crt
tls-key-file /etc/valkey/tls/valkey.key
tls-ca-cert-file /etc/valkey/tls/ca.crt
tls-auth-clients yes
tls-protocols "TLSv1.2 TLSv1.3"
tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
tls-ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
tls-prefer-server-ciphers yes
tls-auto-reload-interval 86400
tls-replication yes
tls-cluster yes

# --- ACL ---
aclfile /etc/valkey/users.acl
acllog-max-len 256

# --- Memory ---
maxmemory <80% of available RAM>
maxmemory-policy allkeys-lru

# --- Client limits ---
maxclients 10000
client-output-buffer-limit normal 256mb 128mb 60
client-output-buffer-limit replica 512mb 256mb 60
client-output-buffer-limit pubsub 64mb 32mb 60
timeout 300

# --- Persistence security ---
dir /var/lib/valkey
dbfilename dump.rdb
rdbchecksum yes

# --- Logging ---
loglevel notice
logfile /var/log/valkey/valkey.log
syslog-enabled yes

# --- Slow log ---
slowlog-log-slower-than 10000
slowlog-max-len 256

# --- Disable dangerous commands for default user via ACL instead of rename ---
# Do NOT use rename-command (deprecated) - use ACLs
```

### Example users.acl File

```
# Admin - full access, separate from default
user admin on #<sha256-hash> ~* &* +@all

# Default user - locked down
user default on #<sha256-hash> ~* &* +@all -@admin -@dangerous -debug

# Application read-write user
user app-rw on #<sha256-hash> ~app:* &app:events:* +@all -@admin -@dangerous

# Application read-only user
user app-ro on #<sha256-hash> ~app:* -@all +@read +@connection +ping

# Cache worker
user cache on #<sha256-hash> ~cache:* -@all +get +set +del +mget +mset +expire +ttl +exists +ping +select

# Queue worker
user queue on #<sha256-hash> ~queue:* -@all +@list +@connection +lpush +rpush +lpop +rpop +llen +ping

# Monitoring
user monitoring on #<sha256-hash> -@all +info +ping +client|list +client|info +slowlog|get +latency|latest +dbsize +memory|stats +memory|usage +config|get

# Sentinel
user sentinel on #<sha256-hash> allchannels +multi +slaveof +ping +exec +subscribe +config|rewrite +role +publish +info +client|setname +client|kill +script|kill

# Replica
user replica on #<sha256-hash> +psync +replconf +ping
```

### Post-Deployment Validation

- [ ] Verify TLS is working: `valkey-cli --tls --cert ... --key ... --cacert ... ping`
- [ ] Verify protected mode: attempt connection from external IP without auth
- [ ] Verify ACL restrictions: attempt denied commands with each user
- [ ] Verify ACL LOG captures denials: `ACL LOG 10`
- [ ] Run `INFO server` and verify TLS-only connections
- [ ] Test certificate rotation: replace certs and verify auto-reload
- [ ] Verify firewall rules: port scan from outside allowed networks
- [ ] Test failover: verify Sentinel/Cluster failover preserves ACL configuration
- [ ] Verify backup encryption: check RDB file access permissions
- [ ] Run `CONFIG GET *` and audit all settings against this checklist

### Ongoing Operations

- [ ] Patch Valkey within 30 days of security advisory (critical: 72 hours)
- [ ] Rotate ACL passwords quarterly (or on personnel changes)
- [ ] Rotate TLS certificates before expiry (automate with ACME or tls-auto-reload-interval)
- [ ] Review ACL LOG weekly for anomalies
- [ ] Review CLIENT LIST for unexpected connections
- [ ] Audit ACL users quarterly (remove unused accounts)
- [ ] Test disaster recovery procedures quarterly
- [ ] Update TLS cipher configuration annually to match current best practices
- [ ] Subscribe to Valkey security advisories (GitHub watch on valkey-io/valkey)
- [ ] Subscribe to Redis CVE notifications (inherited attack surface)

---

## 10. Configuration Quick Reference

### Dangerous Commands to Restrict

These commands should be restricted to admin users only via ACLs:

| Command | Risk | Recommendation |
|---------|------|----------------|
| FLUSHALL / FLUSHDB | Complete data loss | Admin only |
| CONFIG SET | Runtime reconfiguration | Admin only (allow `config|get` for monitoring) |
| DEBUG | Crash, memory dump, performance impact | Admin only or fully disabled |
| KEYS | Performance DoS on large datasets | Use SCAN instead; restrict via ACL |
| SHUTDOWN | Service termination | Admin only |
| REPLICAOF / SLAVEOF | Replication hijacking | Admin only |
| MIGRATE | Data exfiltration | Admin only |
| RESTORE | Arbitrary data injection | Admin only |
| MODULE LOAD/UNLOAD | Arbitrary code execution | Admin only |
| SAVE / BGSAVE | Disk I/O spike, potential data write to arbitrary paths | Admin only |
| ACL SETUSER / ACL DELUSER | Privilege escalation | Admin only |
| EVAL / EVALSHA | Lua code execution (RCE risk per CVE history) | Trusted users only |
| SCRIPT | Lua script management | Trusted users only |
| CLIENT KILL / CLIENT SETNAME | Connection manipulation | Admin/monitoring only |
| MONITOR | Performance impact, data exposure | Debugging only, never in production |

### Valkey Security vs Redis Comparison

Valkey inherits Redis security model and extends it. Key Valkey-specific additions:
- `tls-auth-clients-user` - Map TLS client certificates to ACL users
- `tls-auto-reload-interval` - Automatic certificate rotation
- TLS material validation on load (certificate-key matching, validity period)
- Continued active maintenance and security patching post-Redis fork
