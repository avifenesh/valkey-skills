# Cache Invalidation and TTL Patterns

Use when setting up cache invalidation strategies, choosing eviction policies, or designing TTL schemes.

## CLIENT TRACKING (Server-Assisted Invalidation)

Valkey notifies clients when a tracked key changes, enabling precise cache invalidation without polling or keyspace notifications:

```
# Enable tracking; server sends invalidation messages on writes to watched keys
CLIENT TRACKING ON BCAST PREFIX cache:
```

In RESP3, invalidation messages arrive on the same connection. In RESP2, use a separate invalidation channel with `REDIRECT <client-id>`.

`BCAST` mode broadcasts invalidations for all keys matching PREFIX patterns - no per-key tracking overhead. Use for shared caches accessed by multiple clients.

## Eviction Policies

Set via `maxmemory-policy`. Valkey defaults unchanged from Redis 7:

- `allkeys-lru` - general caching default
- `allkeys-lfu` - stable hot set; tune `lfu-log-factor` (default 10)
- `volatile-lru` - mixed persistent + cache data
- `noeviction` - reject writes when full (use for non-cache data)

With `allkeys-lru` you do not need to set TTLs to make keys evictable - skipping the per-TTL-key entry in the `expires` table saves memory compared to a `volatile-lru` deployment that requires every cache key to carry a TTL.

## TTL Patterns

Add random jitter to prevent stampedes: `base_ttl + random(0, jitter)`. Use `UNLINK` on explicit invalidation (see `best-practices-performance-commands.md`). Keyspace notifications (`notify-keyspace-events Exg`) are fire-and-forget - not reliable as sole invalidation.
