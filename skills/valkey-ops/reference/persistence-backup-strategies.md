# Backup Strategies

Use when implementing automated backup strategies for Valkey - RDB snapshot scripts, AOF backup, or replica-based backup.

Standard Redis backup strategies apply - BGSAVE polling, AOF hardlink backup, off-site upload, replica-based backup. See Redis docs for general patterns.

## Valkey-Specific Names

| Redis CLI | Valkey CLI |
|-----------|-----------|
| `redis-cli` | `valkey-cli` |
| `dump.rdb` | `dump.rdb` (same) |
| `appendonlydir/` | `appendonlydir/` (same) |

## Replica-Based Backup Config

```
replicaof primary-host 6379
replica-priority 0    # never promote this replica
```

## RDB Backup Trigger

```bash
valkey-cli -a $VALKEY_PASSWORD BGSAVE
valkey-cli -a $VALKEY_PASSWORD LASTSAVE   # poll for completion
```

## AOF Backup Window Minimization

Disable auto-rewrite temporarily, create hardlinks, re-enable:

```bash
valkey-cli CONFIG SET auto-aof-rewrite-percentage 0
# ... hardlink appendonlydir/ ...
valkey-cli CONFIG SET auto-aof-rewrite-percentage 100
```

## Retention Tiers

Hourly (24h local), daily (30d local+offsite), weekly (90d offsite), monthly (1yr cold storage). Always verify restores - run `valkey-server` on backup file and check `DBSIZE`.
