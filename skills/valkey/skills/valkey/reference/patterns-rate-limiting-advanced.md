# Rate Limiting: Windows, Token Bucket, and Advanced Patterns

Use when implementing rate limiting on Valkey: choosing between window-based and token-bucket algorithms, using per-field TTL on hashes for per-endpoint limits, or comparing algorithm tradeoffs for production APIs.

## Window-Based Orientation

Three standard window-based patterns, all using generic Redis/Valkey commands. A model already trained on Redis knows the implementation shape - listed here so you can pick the right one before reading the production details below.

- **Fixed window** - `INCR` + `EXPIRE` on a per-window key. Simple, O(1), but allows 2x burst at window boundaries.
- **Sliding window counter** - two window keys weighted by elapsed ratio. Approximates a true sliding window with O(1) ops and low memory.
- **Sliding window log** - sorted set of timestamps per user. Exact, but O(N) memory and higher CPU at scale.

For production, prefer token bucket (burst allowance + sustained refill) or per-endpoint rate limits via Valkey 9.0+ hash-field TTL - both documented below.

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
| Allows controlled bursts | Requires a Lua script for atomicity |
| Smooth rate limiting | Script blocks the main thread during execution |
| Configurable burst capacity and sustained rate | Two fields per user key |

---

## Per-Field Rate Limiting (Valkey 9.0+)

Use hash field expiration to track rate limits per endpoint (or per action) within a single hash per user. Each field auto-expires independently.

### How It Works

One hash per user. Each field represents an endpoint/action with a request count value. Per-field TTL via HSETEX auto-expires counters at window end.

### Implementation

Branching pattern: try to create the counter with a TTL; if it already exists, increment.

```
# Attempt to create the field with value=1 and a 60s TTL.
# FNX = "set only if the field does not already exist".
# Reply: 1 if created (this request was the first in the window),
#        0 if the field was already there.
HSETEX rate:user:42 FNX EX 60 FIELDS 1 /api/orders 1

# If the HSETEX above returned 0 (field exists):
#   HINCRBY returns the new count directly - no follow-up HGET needed.
#   HINCRBY preserves the field's existing TTL, so the window keeps ticking down.
count = HINCRBY rate:user:42 /api/orders 1

if count > limit: reject request

# Optional: check remaining TTL (useful for X-RateLimit-Reset)
HTTL rate:user:42 FIELDS 1 /api/orders
```

**Post-increment rejection**: the increment has already persisted by the time you reject. A client hammering the endpoint while over the limit still bumps the counter higher for the rest of the window. That's fine for access-control use cases (still rejected) but fragile if the counter is also used for billing or SLA metrics - use the token-bucket pattern above if you need check-before-consume.

**HINCRBY replicates as HSETEX when the hash has volatile fields.** Replicas and AOF see `HSETEX ... PXAT ... FIELDS 1 <field> <new_value>`, not `HINCRBY`. Operators grepping AOF for the increment won't find it under that name.

### Trade-offs

| Strength | Weakness |
|----------|----------|
| All rate limits for a user in one key | Requires Valkey 9.0+ |
| Fields auto-expire independently | Fixed-window boundary problem (2x burst at boundary) |
| Low memory - no sorted sets or Lua scripts | Two-command protocol: HSETEX FNX then HINCRBY |
| HINCRBY preserves field TTL - counts tick toward the existing expiry | `HSET` strips field TTLs - use `HSETEX ... KEEPTTL` for in-place value updates |

**Sliding-window variant**: if you want the TTL to restart on every hit (so a steady stream of requests never expires the counter), replace `HINCRBY` with `HGETEX EX 60 ... ; HINCRBY ...` or use a script. Note this is **not** a true sliding window - it's an access-refreshed fixed window, which can let a steady 1-req/sec stream hold the counter open indefinitely.

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
