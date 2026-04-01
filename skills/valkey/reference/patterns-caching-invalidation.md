# Cache Invalidation and TTL Patterns

Use when setting up cache invalidation strategies, choosing eviction policies, or designing TTL schemes for Valkey caching layers.

## Contents

- Cache Invalidation Strategies (line 13)
- Eviction Policy Guidance (line 59)
- TTL Patterns (line 83)

---

## Cache Invalidation Strategies

### TTL-Based (Simplest)

Set a TTL and accept stale data until expiration. No explicit invalidation logic.

```
SET cache:user:1000 "{...}" EX 3600    # Stale for up to 1 hour
```

**Best for**: Data where slight staleness is acceptable (product catalogs, user profiles).

### Event-Driven Invalidation

Invalidate the cache key when underlying data changes. The write path must know about the cache.

```python
async def update_user(user_id, data):
    await db.execute("UPDATE users SET ... WHERE id = $1", user_id)
    await redis.unlink(f"cache:user:{user_id}")
    # Next read will trigger cache-aside repopulation
```

**Best for**: Data where freshness matters (account balances, permissions).

**Prefer `UNLINK` + re-populate on next read** over writing the new value directly. This avoids race conditions where concurrent writes could leave stale data in the cache.

### Keyspace Notifications

React to key changes via built-in notifications. Requires enabling `notify-keyspace-events`:

```
# Enable notifications for expired and generic events
CONFIG SET notify-keyspace-events Exg

# Subscribe to expiration events in database 0
SUBSCRIBE __keyevent@0__:expired
```

Keyspace notifications are fire-and-forget (pub/sub). If no subscriber is listening, the message is lost. Not reliable as a sole invalidation mechanism.

---

## Eviction Policy Guidance

With `maxmemory` configured, the eviction policy determines what happens when memory is full.

| Policy | Best For |
|--------|----------|
| `allkeys-lru` | General caching with power-law access patterns (good default) |
| `allkeys-lfu` | Stable hot set - evicts least frequently used keys |
| `volatile-lru` | Mixed cache + persistent data - only evicts keys with TTLs |
| `volatile-ttl` | Hint-based priority - evicts shortest remaining TTL first |
| `noeviction` | When data loss is unacceptable (rejects writes on memory limit) |

`allkeys-lru` is more memory-efficient than `volatile-lru` because keys do not need TTLs to be eviction candidates. TTLs consume extra memory for expiry metadata.

**LFU tuning**: `lfu-log-factor` (default 10) controls how many hits saturate the frequency counter. `maxmemory-samples` (default 5, increase for accuracy) controls LRU precision.

---

## TTL Patterns

### Fixed TTL

```
SET cache:key value EX 3600    # 1 hour
```

Simple, predictable. Good default for most cache entries.

### Jittered TTL

Prevent cache stampede when many keys expire at the same time:

```python
import random
base_ttl = 3600
jitter = random.randint(0, 300)  # +/- 5 minutes
await redis.set(key, value, ex=base_ttl + jitter)
```

### Hierarchical TTL

Different TTLs for different data freshness needs:

```
SET cache:realtime:stock_price "..." EX 5         # 5 seconds
SET cache:frequent:user_feed "..." EX 60          # 1 minute
SET cache:stable:product_details "..." EX 86400   # 1 day
```

---
