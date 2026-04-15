# Rate Limiting: Token Bucket and Advanced Patterns

Use when implementing token bucket rate limiting, per-field rate limits with Valkey 9.0+, or choosing between rate limiting algorithms for production APIs.

## Token Bucket (Lua Script)

Allows bursts up to a maximum while enforcing a sustained rate. Uses a Lua script for atomic check-and-update.

### How It Works

A bucket holds tokens up to a max capacity. Each request consumes one token. Tokens refill at a fixed rate. Empty bucket = rejected request.

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

One hash per user. Each field represents an endpoint/action with a request count value. Per-field TTL via HSETEX auto-expires counters at window end.

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
