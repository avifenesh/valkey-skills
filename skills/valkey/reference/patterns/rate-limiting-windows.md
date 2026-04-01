# Rate Limiting: Window-Based Patterns

Use when implementing API rate limiting with fixed windows, sliding window counters, or exact sliding window logs using sorted sets.

## Contents

- Fixed Window Counter (line 13)
- Sliding Window Counter (line 71)
- Sliding Window Log (Sorted Set) (line 129)

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
