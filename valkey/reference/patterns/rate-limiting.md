# Rate Limiting Patterns

Use when implementing API rate limiting, throttling user actions, or protecting backend services from traffic spikes.

---

## Fixed Window Counter

The simplest rate limiting approach. Count requests in a fixed time window using `INCR` and `EXPIRE`.

### How It Works

Each time window (e.g., each minute) gets a counter key. Increment on each request. Reject when the counter exceeds the limit.

### Implementation

**Pseudocode**:
```
key = "ratelimit:user:42:" + current_minute
count = INCR key
if count == 1:
    EXPIRE key 60    # Set TTL on first request
if count > 100:
    reject request
```

**Node.js**:
```javascript
async function checkRateLimit(userId, limit, windowSecs) {
  const window = Math.floor(Date.now() / (windowSecs * 1000));
  const key = `ratelimit:${userId}:${window}`;

  const count = await redis.incr(key);
  if (count === 1) {
    await redis.expire(key, windowSecs + 1); // +1 for safety margin
  }
  return count <= limit;
}
```

**Python**:
```python
async def check_rate_limit(user_id: str, limit: int, window_secs: int) -> bool:
    window = int(time.time()) // window_secs
    key = f"ratelimit:{user_id}:{window}"

    count = await redis.incr(key)
    if count == 1:
        await redis.expire(key, window_secs + 1)
    return count <= limit
```

### Trade-offs

| Strength | Weakness |
|----------|----------|
| Simple, O(1) per check | Boundary problem: 2x burst at window edges |
| Low memory (one key per user per window) | Not perfectly smooth |
| Easy to understand and debug | Windows are fixed, not rolling |

**Boundary problem**: A user can send 100 requests at 0:59 and 100 more at 1:00, getting 200 requests in 2 seconds despite a 100/minute limit.

---

## Sliding Window Counter

Smooths the boundary problem by weighting the previous window's count.

### How It Works

Use two windows (current and previous) and calculate a weighted count based on how far into the current window we are.

### Implementation

**Pseudocode**:
```
current_count = GET ratelimit:user:42:current_window
previous_count = GET ratelimit:user:42:previous_window
elapsed_ratio = seconds_into_current_window / window_size
effective_count = current_count + (previous_count * (1 - elapsed_ratio))
if effective_count >= limit:
    reject request
else:
    INCR ratelimit:user:42:current_window
```

**Node.js**:
```javascript
async function slidingWindowCheck(userId, limit, windowSecs) {
  const now = Date.now() / 1000;
  const currentWindow = Math.floor(now / windowSecs);
  const previousWindow = currentWindow - 1;

  const [currentCount, previousCount] = await redis.mget(
    `ratelimit:${userId}:${currentWindow}`,
    `ratelimit:${userId}:${previousWindow}`
  );

  const elapsedRatio = (now % windowSecs) / windowSecs;
  const effectiveCount =
    (parseInt(currentCount) || 0) +
    (parseInt(previousCount) || 0) * (1 - elapsedRatio);

  if (effectiveCount >= limit) return false;

  const key = `ratelimit:${userId}:${currentWindow}`;
  const count = await redis.incr(key);
  if (count === 1) await redis.expire(key, windowSecs * 2);
  return true;
}
```

### Trade-offs

| Strength | Weakness |
|----------|----------|
| Smooths boundary bursts | Two keys per user |
| Low memory, O(1) operations | Approximation (not exact sliding window) |
| Good accuracy for most use cases | Slightly more complex than fixed window |

---

## Sliding Window Log (Sorted Set)

Exact sliding window using a sorted set to track individual request timestamps.

### How It Works

Store each request timestamp as a sorted set member. Remove entries older than the window. Count remaining entries.

### Implementation

**Pseudocode**:
```
now = current_timestamp_ms
key = "ratelimit:user:42"

# Remove entries outside the window
ZREMRANGEBYSCORE key 0 (now - window_ms)

# Count entries in the window
count = ZCARD key

if count >= limit:
    reject request
else:
    ZADD key now now    # score = timestamp, member = timestamp
    EXPIRE key window_seconds
```

**Node.js (pipeline for atomicity)**:
```javascript
async function slidingLogCheck(userId, limit, windowMs) {
  const now = Date.now();
  const key = `ratelimit:${userId}`;
  const windowStart = now - windowMs;

  const pipeline = redis.pipeline();
  pipeline.zremrangebyscore(key, 0, windowStart);
  pipeline.zcard(key);
  pipeline.zadd(key, now, `${now}:${Math.random()}`);
  pipeline.expire(key, Math.ceil(windowMs / 1000) + 1);
  const results = await pipeline.exec();

  const count = results[1][1]; // ZCARD result
  if (count >= limit) {
    // Remove the entry we just added
    await redis.zpopmax(key);
    return false;
  }
  return true;
}
```

### Trade-offs

| Strength | Weakness |
|----------|----------|
| Exact sliding window, no boundary issues | O(N) memory per user (stores every request) |
| Precise counting | Higher memory usage at high request rates |
| Can inspect exact request history | ZREMRANGEBYSCORE is O(log N + M) per check |

---

## Token Bucket (Lua Script)

Allows bursts up to a maximum while enforcing a sustained rate. Uses a Lua script for atomic check-and-update.

### How It Works

A bucket holds tokens (up to a max capacity). Each request consumes one token. Tokens are added at a fixed refill rate. If the bucket is empty, the request is rejected.

### Implementation

**Lua Script**:
```lua
-- KEYS[1] = rate limit key
-- ARGV[1] = max tokens (bucket capacity)
-- ARGV[2] = refill rate (tokens per second)
-- ARGV[3] = current timestamp (seconds, float)
-- ARGV[4] = tokens to consume (usually 1)

local key = KEYS[1]
local max_tokens = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local requested = tonumber(ARGV[4])

local data = server.call('HMGET', key, 'tokens', 'last_refill')
local tokens = tonumber(data[1]) or max_tokens
local last_refill = tonumber(data[2]) or now

-- Calculate token refill
local elapsed = now - last_refill
local new_tokens = math.min(max_tokens, tokens + (elapsed * refill_rate))

if new_tokens >= requested then
    new_tokens = new_tokens - requested
    server.call('HMSET', key, 'tokens', new_tokens, 'last_refill', now)
    server.call('EXPIRE', key, math.ceil(max_tokens / refill_rate) + 1)
    return 1  -- allowed
else
    server.call('HMSET', key, 'tokens', new_tokens, 'last_refill', now)
    server.call('EXPIRE', key, math.ceil(max_tokens / refill_rate) + 1)
    return 0  -- rejected
end
```

**Calling the script from Node.js**:
```javascript
// Load the script once, then call by SHA
const sha = await redis.script('LOAD', TOKEN_BUCKET_SCRIPT);

async function tokenBucketCheck(userId, maxTokens, refillRate) {
  const key = `ratelimit:bucket:${userId}`;
  const now = Date.now() / 1000;
  const result = await redis.evalsha(sha, 1, key, maxTokens, refillRate, now, 1);
  return result === 1;
}
```

### Trade-offs

| Strength | Weakness |
|----------|----------|
| Allows controlled bursts | More complex implementation |
| Smooth rate limiting | Requires Lua script for atomicity |
| Configurable burst capacity and sustained rate | Two fields per user key |
| Industry standard (used by AWS, Google, Stripe) | Script blocks server during run |

---

## Per-Field Rate Limiting (Valkey 9.0+)

Use hash field expiration to track rate limits per endpoint (or per action) within a single hash per user. Each field auto-expires independently.

### How It Works

Store one hash per user. Each field represents an endpoint or action, and its value is the request count. Set a per-field TTL using HSETEX so the counter auto-expires at the end of the window.

### Implementation

```
# First request to /api/orders - create field with 60-second TTL
HSETEX rate:user:42 FNX EX 60 FIELDS 1 /api/orders 1

# Subsequent requests - increment the counter
HINCRBY rate:user:42 /api/orders 1

# Check if limit exceeded
count = HGET rate:user:42 /api/orders
if count > limit: reject request

# Check TTL remaining on the field
HTTL rate:user:42 FIELDS 1 /api/orders
```

### Trade-offs

| Strength | Weakness |
|----------|----------|
| All rate limits for a user in one key | Requires Valkey 9.0+ |
| Fields auto-expire independently | HINCRBY does not set a TTL - must set TTL on first request |
| Low memory - no sorted sets or Lua scripts | Same boundary problem as fixed window |
| Easy per-endpoint inspection with HGETALL | HSET strips field TTLs - use HSETEX with KEEPTTL for updates |

**Tip**: Combine with HGETEX to read the count and refresh the TTL in one atomic command for sliding-window-like behavior:

```
HGETEX rate:user:42 EX 60 FIELDS 1 /api/orders
```

---

## Comparison Table

| Pattern | Memory per User | Accuracy | Burst Handling | Complexity |
|---------|----------------|----------|----------------|------------|
| Fixed window | 1 key | Approximate | 2x burst at boundary | Low |
| Sliding window counter | 2 keys | Good approximation | Smoothed boundary | Low |
| Sliding window log | O(N) entries | Exact | No burst at boundary | Medium |
| Token bucket | 1 hash (2 fields) | Exact | Controlled bursts | Medium |

### Choosing a Pattern

- **Fixed window**: Good enough for most APIs. Simple and efficient.
- **Sliding window counter**: When you need better accuracy without the memory cost of the log.
- **Sliding window log**: When exact counting matters (billing, compliance).
- **Token bucket**: When you want to allow bursts (e.g., 10 requests instantly, then 1/second sustained).

---

## Production Tips

- **Always set TTL on rate limit keys** - prevents orphaned keys from accumulating
- **Use the user/API key as the rate limit identifier** - not IP address (IPs can be shared or spoofed)
- **Return rate limit headers** in HTTP responses: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`
- **Use pipelining** when checking multiple rate limits (e.g., per-user AND per-API-key)
- **Cluster hash tags**: In cluster mode, use `{user:42}:ratelimit` to ensure the rate limit key lands on the right shard

---

## See Also

- [String Commands](../commands/strings.md) - INCR, EXPIRE for fixed window counters
- [Sorted Set Commands](../commands/sorted-sets.md) - ZADD, ZREMRANGEBYSCORE for sliding window log
- [Scripting and Functions](../commands/scripting.md) - Lua scripts for token bucket
- [Hash Field Expiration](../valkey-features/hash-field-ttl.md) - per-field TTL for hash-based rate limiting
- [Performance Best Practices](../best-practices/performance.md) - pipelining for rate limit checks
- [Lock Patterns](locks.md) - distributed locks for related concurrency control
- [Key Best Practices](../best-practices/keys.md) - key naming and TTL strategies
