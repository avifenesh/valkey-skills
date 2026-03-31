# ACL Configuration

Use when setting up access control for Valkey - creating users, assigning
permissions, restricting commands and keys, managing ACL files, and auditing
access denials.

Source-verified against `src/acl.c` and `src/server.h` in valkey-io/valkey.

## Contents

- Tested Example: ACL User Creation (line 24)
- ACL SETUSER Syntax (line 55)
- Command Categories (line 93)
- Selectors (Multi-Permission Sets) (line 126)
- User Role Examples (line 142)
- ACL Persistence (line 200)
- ACL Management Commands (line 239)
- Default User (line 266)
- Key Permission Granularity (line 285)
- See Also (line 294)

---

## Tested Example: ACL User Creation

```bash
# Start Valkey
docker run -d --name valkey-acl -p 6379:6379 valkey/valkey:9

# Create an app user with key-restricted access
valkey-cli ACL SETUSER appuser on '>mypassword' ~app:* +get +mget +set +del +ping

# Test authentication and access (--user and --pass authenticate the connection)
valkey-cli --user appuser --pass mypassword SET app:name "hello"
# Expected: OK (key matches ~app:*)
valkey-cli --user appuser --pass mypassword GET app:name
# Expected: "hello"
valkey-cli --user appuser --pass mypassword SET other:key "fail"
# Expected: NOPERM - key does not match ~app:*

# Create a monitoring user (read-only, info only)
valkey-cli ACL SETUSER monitor on '>monpass' -@all +info +ping +dbsize ~*

# Verify users
valkey-cli ACL LIST
# Expected: lists default, appuser, and monitor with their rules

# Persist ACL changes
valkey-cli CONFIG SET aclfile /data/users.acl
valkey-cli ACL SAVE
```

---

## ACL SETUSER Syntax

```
ACL SETUSER <username> [rule [rule ...]]
```

Rules are processed left to right. Each rule modifies the user state:

| Rule | Effect |
|------|--------|
| `on` | Enable the user (allow AUTH) |
| `off` | Disable the user (reject AUTH, kill existing connections) |
| `>password` | Add a cleartext password (hashed with SHA-256 internally) |
| `<password` | Remove a cleartext password |
| `#hash` | Add a pre-hashed SHA-256 password |
| `!hash` | Remove a pre-hashed password |
| `nopass` | Allow authentication with any password |
| `resetpass` | Clear all passwords and remove nopass flag |
| `+command` | Allow a specific command |
| `-command` | Deny a specific command |
| `+@category` | Allow all commands in a category |
| `-@category` | Deny all commands in a category |
| `+command\|subcommand` | Allow a specific subcommand |
| `allcommands` | Alias for `+@all` |
| `nocommands` | Alias for `-@all` |
| `~pattern` | Allow read+write access to keys matching the glob pattern |
| `%R~pattern` | Allow read-only access to matching keys |
| `%W~pattern` | Allow write-only access to matching keys |
| `allkeys` | Alias for `~*` |
| `resetkeys` | Clear all key patterns |
| `&pattern` | Allow Pub/Sub channel access matching the pattern |
| `allchannels` | Alias for `&*` |
| `resetchannels` | Clear all channel patterns |
| `alldbs` | Allow access to all databases |
| `reset` | Reset user to default state (off, no passwords, no permissions) |

---

## Command Categories

Defined in `src/acl.c` and `src/server.h`. The full list from source:

| Category | Description |
|----------|-------------|
| `@keyspace` | Key management commands (RENAME, DEL, EXISTS, TYPE, etc.) |
| `@read` | Commands that read data |
| `@write` | Commands that modify data |
| `@set` | Set data type commands |
| `@sortedset` | Sorted set commands |
| `@list` | List commands |
| `@hash` | Hash commands |
| `@string` | String commands |
| `@bitmap` | Bitmap commands |
| `@hyperloglog` | HyperLogLog commands |
| `@geo` | Geospatial commands |
| `@stream` | Stream commands |
| `@pubsub` | Pub/Sub commands |
| `@admin` | Administrative commands |
| `@fast` | O(1) or O(log N) commands |
| `@slow` | Commands that are not @fast |
| `@blocking` | Commands that can block (BLPOP, WAIT, etc.) |
| `@dangerous` | Potentially destructive or resource-intensive commands |
| `@connection` | Connection management (AUTH, SELECT, CLIENT, etc.) |
| `@transaction` | MULTI/EXEC/DISCARD |
| `@scripting` | Lua scripting and functions |

View categories at runtime: `ACL CAT`
View commands in a category: `ACL CAT dangerous`

---

## Selectors (Multi-Permission Sets)

Selectors allow a single user to have multiple independent permission sets.
Each selector is enclosed in parentheses. If any selector matches, access
is granted (OR logic).

```
ACL SETUSER myuser on >pass +GET ~data:* (+SET ~cache:*)
```

This user can GET from `data:*` keys via the root selector, OR SET on `cache:*`
keys via the second selector. Verified in `src/acl.c` - selectors are stored
as a linked list per user and evaluated sequentially.

---

## User Role Examples

### Admin - full access

```
ACL SETUSER admin on >verystrongpassword ~* &* +@all
```

### Application - all data commands, no dangerous or scripting

```
ACL SETUSER application on >strongpassword +@all -@dangerous -@scripting ~*
```

### Read-only monitor

```
ACL SETUSER monitor on >monitorpass +get +mget +info +ping ~*
```

### Cache writer with key restrictions

```
ACL SETUSER cache_writer on >cachepass ~cached:* +get +set +del +expire
```

### Replication user (on primary)

```
ACL SETUSER replica on >replicapass +psync +replconf +ping
```

### Pub/Sub only user

```
ACL SETUSER pubsub-client on >pubsubpass resetchannels &notifications:* -@all +subscribe +publish +ping
```

### Queue worker (list operations on job keys)

```
ACL SETUSER worker on >workerpass ~jobs:* -@all +@list +@connection +ping +del
```

### Monitoring/observability user (read-only system info)

```
ACL SETUSER monitor on >monitorpass -@all +info +ping +client|list +slowlog|get +latency|latest +dbsize +memory|usage +memory|stats +config|get
```

### Sentinel user (minimal permissions)

```
ACL SETUSER sentinel on >sentinelpass allchannels +multi +slaveof +ping +exec +subscribe +config|rewrite +role +publish +info +client|setname +client|kill +script|kill
```

---

## ACL Persistence

### Option 1: ACL file (recommended)

Store ACL definitions in a dedicated file, separate from `valkey.conf`:

```
# valkey.conf
aclfile /etc/valkey/users.acl
```

The ACL file config parameter is immutable - it cannot be changed at runtime
(verified: `IMMUTABLE_CONFIG` flag in `src/config.c`).

Manage at runtime:

```
ACL LOAD    # Reload ACL file from disk
ACL SAVE    # Write current ACL state to disk
```

`ACL LOAD` validates all users atomically - if any user definition is invalid,
the entire load fails and the old configuration remains active.

### Option 2: Inline in valkey.conf

```
# valkey.conf
user application on >strongpassword +@all -@dangerous ~*
user monitor on >monitorpass +get +info +ping ~*
```

When using inline config, `CONFIG REWRITE` persists ACL changes.

Important: Do not mix both methods. If `aclfile` is set, inline `user`
directives in `valkey.conf` are ignored.

---

## ACL Management Commands

```bash
# List all users with their rules
ACL LIST

# Get detailed info for a specific user
ACL GETUSER application

# Delete a user
ACL DELUSER olduser

# Generate a cryptographically secure password
ACL GENPASS
ACL GENPASS 128    # specify bit length

# View the security log (access denials)
ACL LOG
ACL LOG 20         # last 20 entries
ACL LOG RESET      # clear the log

# Check which user current connection uses
ACL WHOAMI
```

---

## Default User

Every new connection starts as the `default` user. The default user has full
permissions by default (`+@all ~* &* on nopass alldbs`). In production,
restrict or disable it:

```
# Disable the default user entirely
ACL SETUSER default off

# Or set a password and restrict permissions
ACL SETUSER default on >strongpassword +@all -@dangerous ~*
```

When `requirepass` is set in config, it applies to the default user's password.
ACLs are the preferred authentication mechanism over `requirepass`.

---

## Key Permission Granularity

- `%R~<pattern>` - Read-only: data from key is read, copied, or returned
- `%W~<pattern>` - Write-only: data in key is updated or deleted
- Full access: `~<pattern>` or `%RW~<pattern>`

Metadata operations (STRLEN, TYPE, SISMEMBER, EXISTS) do not require read
permission - only that the user has some key access matching the pattern.

## See Also

- [Security Hardening](hardening.md) - defense in depth, network security
- [TLS Configuration](tls.md) - certificate-based authentication
- [Command Restriction](rename-commands.md) - rename-command vs ACL comparison
- [Prometheus Setup](../monitoring/prometheus.md) - minimal-privilege ACL user for the exporter
- [Monitoring Metrics](../monitoring/metrics.md) - ACL LOG for access denial auditing
- [Alerting Rules](../monitoring/alerting.md) - alerts for rejected connections and anomalies
- [Commandlog](../monitoring/commandlog.md) - audit command patterns alongside ACL LOG
- [Troubleshooting Diagnostics](../troubleshooting/diagnostics.md) - 7-phase diagnostic runbook including ACL review
- [See valkey-dev: acl](../../../valkey-dev/reference/security/acl.md) - user structs, selector evaluation, bitmap permission internals
