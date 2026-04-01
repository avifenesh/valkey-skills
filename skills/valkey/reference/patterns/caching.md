# Caching Patterns

Use when implementing a caching layer with Valkey, setting up cache invalidation, or evaluating client-side caching for hot data.

## Contents

- Cache-Aside (Lazy Loading) (line 17)
- Write-Through (line 104)
- Write-Behind (Write-Back) (line 130)
- Client-Side Caching (CLIENT TRACKING) (line 146)
- Cache Invalidation Strategies (line 272)
- TTL Patterns (line 315)

---

## Cache-Aside (Lazy Loading)

The most common caching pattern. The application checks cache first, falls back to the database on miss, and populates the cache on read.

### Flow

```
1. GET cache:user:1000
2. If hit -> return cached value
3. If miss -> query database
4. SET cache:user:1000 <value> EX 3600
5. Return value
```

### Code Examples

**Node.js**:
```javascript
async function getUser(userId) {
  const cacheKey = `cache:user:${userId}`;
  const cached = await redis.get(cacheKey);
  if (cached) return JSON.parse(cached);

  const user = await db.query('SELECT * FROM users WHERE id = ?', [userId]);
  if (user) {
    await redis.set(cacheKey, JSON.stringify(user), 'EX', 3600);
  }
  return user;
}
```

**Python**:
```python
async def get_user(user_id: int) -> dict:
    cache_key = f"cache:user:{user_id}"
    cached = await redis.get(cache_key)
    if cached:
        return json.loads(cached)

    user = await db.fetch_one("SELECT * FROM users WHERE id = $1", user_id)
    if user:
        await redis.set(cache_key, json.dumps(user), ex=3600)
    return user
```

### Strengths and Weaknesses

| Strength | Weakness |
|----------|----------|
| Only caches what is actually read | First request always misses (cold start) |
| Simple to implement | Stale data until TTL expires or explicit invalidation |
| Naturally adapts to access patterns | Cache stampede risk on popular keys |

### Cache Stampede Prevention

When a popular key expires, many concurrent requests hit the database simultaneously. Mitigation strategies:

**1. Lock-based refresh** (recommended for expensive queries):
```javascript
async function getWithLock(key, fetchFn, ttl) {
  const cached = await redis.get(key);
  if (cached) return JSON.parse(cached);

  // Try to acquire refresh lock
  const lockKey = `lock:${key}`;
  const acquired = await redis.set(lockKey, '1', 'NX', 'EX', 10);
  if (acquired) {
    const value = await fetchFn();
    await redis.set(key, JSON.stringify(value), 'EX', ttl);
    await redis.unlink(lockKey);
    return value;
  }

  // Another request is refreshing - wait briefly and retry
  await sleep(50);
  return getWithLock(key, fetchFn, ttl);
}
```

**2. Early refresh** (proactive): Refresh the cache before TTL expires. Use a background job or check remaining TTL on reads:
```
TTL cache:user:1000
# If TTL < 300 (5 minutes left), trigger async refresh
```

---

## Write-Through

Every write goes to both the cache and the database. The cache is always up to date.

```
1. Application writes to database
2. Application writes to cache
3. Return success
```

**Pseudocode**:
```python
async def update_user(user_id: int, data: dict):
    # Write to database first (source of truth)
    await db.execute("UPDATE users SET ... WHERE id = $1", user_id)

    # Update cache
    await redis.set(f"cache:user:{user_id}", json.dumps(data), ex=3600)
```

**Strengths**: Cache is always fresh. No stale reads.

**Weaknesses**: Every write has cache overhead. Writes to cache that are never read waste resources.

---

## Write-Behind (Write-Back)

Writes go to the cache first, then asynchronously propagate to the database. Reduces write latency but increases complexity.

```
1. Application writes to cache
2. Return success immediately
3. Background process writes to database (batched)
```

**When to use**: High write throughput where database writes are the bottleneck. Acceptable to lose very recent writes on crash (the cache-to-database propagation is async).

**Warning**: If the Valkey instance crashes before the background write completes, data is lost. This pattern requires careful durability planning.

---

## Client-Side Caching (CLIENT TRACKING)

Valkey supports server-assisted client-side caching. The server tracks which keys each client has read and sends invalidation messages when those keys change. This eliminates network round-trips for frequently accessed data entirely.

### Default Mode (Key-Based)

The server remembers every key served to a client and sends precise invalidation when those specific keys are modified.

```
# Enable tracking on the client connection
CLIENT TRACKING ON

# Read a key (server remembers this client read it)
GET user:1000:profile

# When another client modifies user:1000:profile,
# this client receives an invalidation push message
```

- Precise invalidation - only keys the client actually read
- Higher server memory (one entry per key per client)
- Best for read-heavy workloads with moderate key diversity

### Broadcasting Mode (Prefix-Based)

Clients subscribe to key prefixes. The server sends invalidation for any key matching the prefix when modified, regardless of whether the client read it.

```
# Subscribe to all keys starting with "user:"
CLIENT TRACKING ON BCAST PREFIX user:

# Any modification to any user:* key triggers invalidation
```

- Less precise - may invalidate keys the client never cached
- Lower server memory (tracks prefixes, not individual keys)
- Best for high-cardinality keyspaces where key-level tracking is too expensive

### OPTIN Mode

Track only explicitly selected reads. Useful when most reads do not benefit from caching.

```
CLIENT TRACKING ON OPTIN

# Only this next read will be tracked
CLIENT CACHING YES
GET user:1000:profile
```

### Protocol Setup

**RESP3 (single connection)**: Push invalidation messages arrive on the same connection. Simpler setup - recommended when your client supports RESP3.

```
Client -> Server: HELLO 3
Client -> Server: CLIENT TRACKING ON
Client -> Server: GET foo
(Server remembers Client may have "foo" cached)

-- When another client modifies foo:
Server -> Client: INVALIDATE "foo"
(Client evicts "foo" from local cache)
```

**RESP2 (two-connection model)**: RESP2 does not support push messages, so invalidation is delivered via a dedicated Pub/Sub connection:

```
-- Connection 1 (invalidation channel):
CLIENT ID
:4
SUBSCRIBE __redis__:invalidate

-- Connection 2 (data):
CLIENT TRACKING ON REDIRECT 4
GET foo

-- When foo is modified by any client:
-- Connection 1 receives invalidation via Pub/Sub
```

The `__redis__:invalidate` channel is the standard channel name for invalidation messages. The REDIRECT option sends invalidation to connection 1 (client ID 4) instead of the data connection.

**NOLOOP option**: Prevents invalidation messages for keys modified by the same connection. Useful when a client both reads and writes to avoid self-invalidation noise.

```
CLIENT TRACKING ON NOLOOP
```

### When to Use Client-Side Caching

| Scenario | Recommendation |
|----------|---------------|
| Hot keys read thousands of times per second | Default mode - eliminates server round-trips |
| Immutable or rarely-changed data | Default mode - few invalidations |
| Many distinct keys with prefix patterns | Broadcast mode with specific prefixes |
| Mixed hot/cold reads | OPTIN mode - track only hot keys |

### Eviction Policy Guidance for Caching

When using Valkey as a cache with `maxmemory` configured, the eviction policy determines what happens when memory is full.

| Policy | Best For |
|--------|----------|
| `allkeys-lru` | General caching with power-law access patterns (good default) |
| `allkeys-lfu` | Stable hot set - evicts least frequently used keys |
| `volatile-lru` | Mixed cache + persistent data - only evicts keys with TTLs |
| `volatile-ttl` | Hint-based priority - evicts shortest remaining TTL first |
| `noeviction` | When data loss is unacceptable (rejects writes on memory limit) |

**Key insight**: `allkeys-lru` is more memory-efficient than `volatile-lru` because keys do not need TTLs to be eviction candidates. Setting TTLs consumes extra memory for the expiry metadata.

**LFU tuning**: `lfu-log-factor` (default 10) controls how many hits saturate the frequency counter. `maxmemory-samples` (default 5, increase for accuracy) controls LRU precision.

### Client Library Support for Client-Side Caching

| Client | Support |
|--------|---------|
| valkey-go | Yes (server-assisted) |
| redisson | Yes |
| valkey-glide | Not yet (planned) |
| iovalkey / ioredis | No |
| valkey-py / redis-py | No |

---

## Cache Invalidation Strategies

### TTL-Based (Simplest)

Set a TTL and accept stale data until expiration. No explicit invalidation logic.

```
SET cache:user:1000 "{...}" EX 3600    # Stale for up to 1 hour
```

**Best for**: Data where slight staleness is acceptable (product catalogs, user profiles).

### Event-Driven Invalidation

Invalidate the cache key when the underlying data changes. Requires your write path to know about the cache.

```python
async def update_user(user_id, data):
    await db.execute("UPDATE users SET ... WHERE id = $1", user_id)
    await redis.unlink(f"cache:user:{user_id}")
    # Next read will trigger cache-aside repopulation
```

**Best for**: Data where freshness matters (account balances, permissions).

**Prefer `UNLINK` + re-populate on next read** over writing the new value directly. This avoids race conditions where concurrent writes could leave stale data in the cache.

### Keyspace Notifications

React to key changes using Valkey's built-in notification system. Requires enabling `notify-keyspace-events`:

```
# Enable notifications for expired and generic events
CONFIG SET notify-keyspace-events Exg

# Subscribe to expiration events in database 0
SUBSCRIBE __keyevent@0__:expired
```

**Caution**: Keyspace notifications are fire-and-forget (pub/sub). If no subscriber is listening, the message is lost. Not suitable as a reliable invalidation mechanism on its own.

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

