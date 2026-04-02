# Command Restriction with rename-command

Use when disabling or renaming dangerous commands in Valkey.

Standard Redis `rename-command` behavior applies - config-file only, applies globally, breaks replication if configs differ across nodes, no audit trail. See Redis docs for full details.

## Valkey Recommendation

ACLs are strongly preferred over `rename-command`. ACLs are per-user, changeable at runtime, replication-safe, and logged.

```
# Preferred: ACL approach
ACL SETUSER app on >password +@all -@dangerous ~*

# Legacy: rename-command (global, config-file only)
rename-command FLUSHALL ""
rename-command DEBUG ""
```

## Valkey-Specific: @dangerous Category

In Valkey, `ACL CAT dangerous` includes the same commands as Redis plus Valkey-specific admin commands. Use `ACL CAT dangerous` at runtime to see the current list.

## Rename-Command Still Useful For

- Default user lockdown when legacy clients cannot AUTH
- Defense in depth alongside ACLs
- Module protection (modules may bypass ACL checks)

## Limitations

Cannot be changed at runtime. Breaks AOF replay if command names differ at replay time vs recording time. Breaks replication if primary and replica configs differ.
