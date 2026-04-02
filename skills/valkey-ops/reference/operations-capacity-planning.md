# Capacity Planning

Use when sizing Valkey instances, planning memory allocation, or deciding when to scale a cluster.

Standard Redis capacity planning applies - per-key memory overhead, fork COW headroom, connection count sizing. See Redis docs for full formulas.

## Valkey Defaults (source-verified)

| Parameter | Default |
|-----------|---------|
| `maxmemory` | `0` (unlimited) |
| `maxclients` | `10000` |
| Client output buffer - replica | `256mb hard, 64mb soft, 60s` |
| Client output buffer - pubsub | `32mb hard, 8mb soft, 60s` |

## Valkey-Specific: hash-max-listpack-entries

Valkey defaults `hash-max-listpack-entries 512` (vs Redis 128). This means hash memory estimates may be lower than Redis for the same workload - more hashes stay in compact listpack encoding.

## maxmemory Sizing Rule

Set `maxmemory` to 60-70% of available RAM. The remainder covers fork COW (up to 100% of used memory during BGSAVE), client buffers, replication backlog, and OS overhead.

## Total Memory Formula

```
total = maxmemory + fork COW (30-100% of maxmemory) + replica buffers (N * 256MB)
      + pubsub buffers (subscribers * 32MB) + replication backlog + OS (1-2GB)
```

## Cluster Sizing

Prefer more smaller nodes. Smaller nodes mean faster BGSAVE, faster failover, faster slot migration, and lower blast radius. Start scaling when any node exceeds 60% of `maxmemory`.
