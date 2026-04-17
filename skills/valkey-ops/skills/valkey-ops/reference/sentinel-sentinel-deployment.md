# Sentinel Deployment

Use when deploying Sentinel for the first time - configuration directives and step-by-step deployment.

Standard Redis Sentinel deployment process applies. See Redis Sentinel docs for general deployment guidance.

## Valkey-Specific Names

- Start with: `valkey-sentinel /etc/valkey/sentinel.conf` or `valkey-server /etc/valkey/sentinel.conf --sentinel`
- Config goes in `/etc/valkey/sentinel.conf`
- Data nodes run `valkey-server`
- Use `replicaof` (not `slaveof`) and `masterauth`/`primaryauth` (both work)

## Sentinel Config Directives (Valkey)

```
port 26379
sentinel monitor mymaster 192.168.1.10 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
sentinel parallel-syncs mymaster 1
sentinel auth-pass mymaster your-strong-password
sentinel auth-user mymaster sentinel-acl-user   # for ACL auth
```

## Verifying the Deployment

```bash
valkey-cli -p 26379 SENTINEL primaries
valkey-cli -p 26379 SENTINEL replicas mymaster
valkey-cli -p 26379 SENTINEL ckquorum mymaster
valkey-cli -p 26379 SENTINEL get-primary-addr-by-name mymaster
```

## Sentinel ACL user

`FAILOVER` and `CLUSTER FAILOVER` use the standard `@admin`/`@dangerous`/`@slow` categories - no special permission beyond what any admin command needs. See `security-acl.md` for the minimal per-command grant list that matches what Sentinel actually invokes.
