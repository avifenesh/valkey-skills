Use when you need to disable or rename dangerous commands in Valkey. Covers

# Command Restriction with rename-command
the legacy `rename-command` directive and the preferred ACL alternative.

Source-verified against `src/config.c` in valkey-io/valkey.

## Contents

- rename-command Syntax (line 22)
- Common Patterns (line 43)
- Limitations of rename-command (line 91)
- ACL Alternative (Preferred) (line 105)
- When rename-command Is Still Useful (line 163)
- Migration from rename-command to ACL (line 195)
- Full Dangerous Command Reference (line 219)
- Troubleshooting (line 241)
- See Also (line 252)

---

## rename-command Syntax

The `rename-command` directive is a config-file-only setting. It cannot be
changed at runtime via `CONFIG SET` - it is parsed during config file loading
(line 545 in config.c).

```
rename-command <original-name> <new-name>
```

To disable a command entirely, rename it to an empty string:

```
rename-command <original-name> ""
```

The command must exist - renaming a non-existent command produces an error:
`"No such command in rename-command"` (line 549 in config.c).

---

## Common Patterns

### Disable Dangerous Commands

```
# Prevent accidental data loss
rename-command FLUSHALL ""
rename-command FLUSHDB ""

# Disable debugging in production
rename-command DEBUG ""

# Block expensive full-keyspace scan
rename-command KEYS ""

# Prevent runtime config changes
rename-command CONFIG ""

# Block SHUTDOWN via client
rename-command SHUTDOWN ""
```

### Rename to Secret Names

Instead of disabling, rename to an obscure string that only administrators
know:

```
rename-command CONFIG "CONFIG_a8f3b2c1d4e5"
rename-command FLUSHALL "FLUSH_secret_7x9k2m"
```

This allows emergency use while preventing accidental invocation.

### Minimal Production Lockdown

```
rename-command FLUSHALL ""
rename-command FLUSHDB ""
rename-command DEBUG ""
rename-command KEYS ""
```

This blocks the most common operational mistakes while leaving CONFIG and
SHUTDOWN accessible to administrators.

---

## Limitations of rename-command

| Limitation | Impact |
|------------|--------|
| Config file only | Cannot be changed at runtime |
| Applies globally | All users affected equally |
| Breaks replication | Renamed commands on primary don't match replica if configs differ |
| Breaks scripts | Lua scripts and modules using renamed commands fail silently |
| Breaks tooling | Monitoring tools that use KEYS, CONFIG, or DEBUG will fail |
| No logging | No audit trail of who attempted the renamed command |
| Persistence incompatible | AOF files contain original command names - replay breaks if commands are renamed differently |

---

## ACL Alternative (Preferred)

ACLs provide fine-grained command control per user without the drawbacks of
rename-command. Available since Valkey 7.0 (inherited from Redis 6.0).

### Equivalent ACL Patterns

Instead of `rename-command FLUSHALL ""`:

```
# Application user - deny dangerous commands
ACL SETUSER app on >password +@all -@dangerous ~*

# Admin user - full access
ACL SETUSER admin on >adminpassword +@all ~*
```

Instead of `rename-command CONFIG ""`:

```
# Deny CONFIG for non-admin users
ACL SETUSER app on >password +@all -config ~*
```

Instead of `rename-command KEYS ""`:

```
# Deny KEYS but allow SCAN (safer alternative)
ACL SETUSER app on >password +@all -keys ~*
```

### ACL Advantages Over rename-command

| Feature | rename-command | ACL |
|---------|---------------|-----|
| Per-user control | No | Yes |
| Runtime changes | No | Yes (`ACL SETUSER`) |
| Replication safe | No | Yes |
| Audit logging | No | Yes (`ACL LOG`) |
| Subcommand control | No | Yes (`+config|get -config|set`) |
| Category-based rules | No | Yes (`-@dangerous`) |
| Key pattern restrictions | No | Yes (`~pattern`) |

### The @dangerous Category

The `@dangerous` ACL category includes commands that are potentially destructive
or resource-intensive:

```
ACL CAT dangerous
```

This typically includes: FLUSHALL, FLUSHDB, DEBUG, KEYS, SORT, MIGRATE,
RESTORE, CLUSTER, REPLICAOF, CONFIG, SHUTDOWN, SAVE, BGSAVE, BGREWRITEAOF,
SLOWLOG, ACL, MODULE, and others.

---

## When rename-command Is Still Useful

Despite ACLs being preferred, rename-command has valid use cases:

1. **Default user lockdown**: The `default` user in Valkey has full access.
   If you cannot enforce ACL authentication (legacy clients that don't AUTH),
   rename-command provides a safety net.

2. **Defense in depth**: Combine both - ACLs for primary control, rename-command
   as a secondary barrier for the most dangerous commands.

3. **Backward compatibility**: Environments that haven't migrated to ACL-based
   auth can still benefit from rename-command.

4. **Module protection**: Some modules may bypass ACL checks. Renaming the
   command at the server level is more thorough.

### Combined Example

```
# valkey.conf - belt and suspenders

# Rename as secondary protection
rename-command DEBUG ""

# Primary protection via ACL
user app on >password +@all -@dangerous ~*
user admin on >adminpassword +@all ~*
```

---

## Migration from rename-command to ACL

1. **Audit current renames**: Check `valkey.conf` for all `rename-command` lines
2. **Map to ACL rules**: For each disabled command, create equivalent `-command`
   ACL rules
3. **Create user roles**: Define admin, application, and read-only users
4. **Test with ACL LOG**: Enable `ACL LOG` to verify denials match expectations
5. **Remove rename-command lines**: After ACL rules are validated
6. **Update clients**: Ensure all clients AUTH with appropriate user credentials

```
# Before (rename-command)
rename-command FLUSHALL ""
rename-command DEBUG ""
rename-command KEYS ""

# After (ACL)
user default off
user app on >password +@all -flushall -flushdb -debug -keys ~*
user admin on >adminpassword +@all ~*
```

---

## Full Dangerous Command Reference

Commands that should be restricted to admin users only via ACLs:

| Command | Risk |
|---------|------|
| FLUSHALL / FLUSHDB | Complete data loss |
| CONFIG SET | Runtime reconfiguration |
| DEBUG | Crash, memory dump, performance impact |
| KEYS | Performance DoS on large datasets (use SCAN) |
| SHUTDOWN | Service termination |
| REPLICAOF / SLAVEOF | Replication hijacking |
| MIGRATE | Data exfiltration |
| RESTORE | Arbitrary data injection |
| MODULE LOAD/UNLOAD | Arbitrary code execution |
| SAVE / BGSAVE | Disk I/O spike |
| ACL SETUSER / ACL DELUSER | Privilege escalation |
| EVAL / EVALSHA | Lua code execution (RCE risk per CVE history) |
| MONITOR | Performance impact, data exposure |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ERR unknown command` on renamed command | Command was renamed or disabled | Use the new name or re-enable |
| Replication broken after rename | Primary and replica have different renames | Ensure identical `rename-command` on all nodes |
| AOF replay fails | AOF contains original command names | Remove rename-command, replay AOF, re-add renames |
| Monitoring tool errors | Tool uses disabled commands | Use ACL instead - grant monitoring user access |

---
