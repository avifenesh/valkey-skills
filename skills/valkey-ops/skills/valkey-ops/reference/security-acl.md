# ACL Configuration

Use when setting up access control for Valkey - creating users, assigning permissions, restricting commands and keys.

Standard Redis ACL model applies - SETUSER syntax, categories, selectors, ACL file vs inline config. See Redis docs for full ACL reference.

## Valkey-Specific: Sentinel ACL (9.0+)

The Sentinel user requires `+failover` in addition to the standard Redis Sentinel permissions:

```
ACL SETUSER sentinel on >sentinelpass allchannels \
  +multi +slaveof +ping +exec +subscribe \
  +config|rewrite +role +publish +info \
  +client|setname +client|kill +script|kill \
  +failover
```

The `+failover` requirement was added in Valkey 9.0. Without it, Sentinel cannot execute the failover command on the monitored instance.

## Default User (same as Redis)

Full permissions by default. Restrict or disable in production:

```
ACL SETUSER default off
```

When `requirepass` is set, it applies to the default user's password. ACLs are preferred over `requirepass`.

## ACL Persistence

```
aclfile /etc/valkey/users.acl   # immutable config option
```

Manage at runtime: `ACL LOAD` (reload from file), `ACL SAVE` (write to file).

## Monitoring

```bash
valkey-cli ACL LOG       # access denial audit trail
valkey-cli ACL WHOAMI    # current connection's user
```
