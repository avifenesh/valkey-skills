# Eviction Policies

Use when choosing or tuning the maxmemory eviction policy.

Standard Redis eviction model applies. All 8 policy names are identical in Valkey (`noeviction`, `allkeys-lru`, `allkeys-lfu`, `allkeys-random`, `volatile-lru`, `volatile-lfu`, `volatile-random`, `volatile-ttl`). See Redis docs for full policy descriptions.

## Valkey Defaults (same as Redis)

- `maxmemory`: `0` (unlimited) - always set explicitly in production
- `maxmemory-policy`: `noeviction`
- `maxmemory-samples`: `5`

## Valkey-Specific Parameter

`maxmemory-clients` (not in Redis) - caps aggregate client buffer memory:

```
maxmemory-clients 5%
```

Defaults to `0` (disabled). Set to prevent misbehaving clients from consuming data memory.

## Monitoring

```bash
valkey-cli INFO stats | grep evicted_keys
valkey-cli CONFIG GET maxmemory-policy
valkey-cli INFO memory | grep -E 'used_memory_human|maxmemory_human'
```

## Common Mistakes

- Leaving `maxmemory 0` in production - process grows until OOM killer fires
- Using `volatile-*` with no TTL-bearing keys - behaves like `noeviction`
- Setting `maxmemory-samples` above 10 - diminishing returns, wastes CPU
