# Caching Strategies

Use when implementing a caching layer with Valkey - choosing between cache-aside, write-through, and write-behind patterns, setting up client-side caching for hot data, or configuring invalidation and eviction policies.

## Contents

- Cache-Aside (Lazy Loading)
- Write-Through
- Write-Behind (Write-Back)
- Client-Side Caching (CLIENT TRACKING)
- Invalidation, Eviction Policies, and TTL Patterns

---

## Cache-Aside (Lazy Loading)

The most common pattern. Check cache first, fall back to database on miss, populate cache on read.

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

When a popular key expires, many concurrent requests hit the database simultaneously. Mitigations:

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

Every write goes to both cache and database. Cache is always current.

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

Writes go to cache first, then asynchronously propagate to the database. Lower write latency, higher complexity.

```
1. Application writes to cache
2. Return success immediately
3. Background process writes to database (batched)
```

**When to use**: High write throughput where database writes are the bottleneck. Acceptable to lose very recent writes on crash (the cache-to-database propagation is async).

**Warning**: If the Valkey instance crashes before the background write completes, data is lost. This pattern requires careful durability planning.

---

## Client-Side Caching (CLIENT TRACKING)

Server-assisted client-side caching. The server tracks which keys each client reads and sends invalidation messages when those keys change, eliminating network round-trips for frequently accessed data.

### Default Mode (Key-Based)

The server remembers every key served to a client and sends invalidation when those keys are modified.

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

Clients subscribe to key prefixes. The server sends invalidation for any matching key when modified, regardless of whether the client read it.

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

**RESP3 (single connection)**: Push invalidation on the same connection. Simpler setup, recommended when the client supports RESP3.

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

**NOLOOP option**: Prevents self-invalidation when a client both reads and writes.

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

### Client Library Support

| Client | Support |
|--------|---------|
| valkey-go | Yes (server-assisted) |
| redisson | Yes |
| iovalkey / ioredis | No |
| valkey-py / redis-py | No |

---

## Invalidation, Eviction Policies, and TTL Patterns

### CLIENT TRACKING (server-assisted invalidation)

Covered above. Short recap: `CLIENT TRACKING ON BCAST PREFIX cache:` broadcasts invalidation messages for all keys matching the PREFIX pattern - no per-key server state, good for shared caches across many clients.

### Eviction policies

Set via `maxmemory-policy`. Valkey defaults match Redis 7:

- `allkeys-lru` - general caching default
- `allkeys-lfu` - stable hot set; tune `lfu-log-factor` (default 10)
- `volatile-lru` - mixed persistent + cache data
- `noeviction` - reject writes when full (use for non-cache data)

With `allkeys-lru`, you do not need to set TTLs to make keys evictable. Skipping the per-TTL entry in the `expires` table saves memory compared to a `volatile-lru` deployment where every cache key carries a TTL.

### TTL patterns

Add random jitter to prevent stampedes: `base_ttl + random(0, jitter)`. Use `UNLINK` on explicit invalidation (see `best-practices-performance-throughput.md`). Keyspace notifications (`notify-keyspace-events Exg`) are fire-and-forget - not reliable as a sole invalidation mechanism.
