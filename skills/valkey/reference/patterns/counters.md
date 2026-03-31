# Counter and Deduplication Patterns

Use when implementing atomic counters, unique event counting, idempotency keys, sharded counters for high-throughput hot keys, or deduplication of requests and events.

## Contents

- Atomic Counters (line 17)
- Sharded Counters (line 85)
- Idempotency Keys (line 150)
- HyperLogLog for Approximate Unique Counting (line 222)
- BITFIELD-Based Packed Counters (line 283)
- Deduplication (line 338)
- See Also (line 395)

---

## Atomic Counters

`INCR`, `INCRBY`, and `INCRBYFLOAT` are atomic single-key operations. No race conditions, no read-modify-write cycles.

### Basic Counter

```
INCR page:views:homepage
# (integer) 1

INCRBY page:views:homepage 5
# (integer) 6

INCRBYFLOAT account:balance:42 19.99
# "25.99"

DECR page:views:homepage
# (integer) 5
```

### Node.js

```javascript
// Page view counter
const views = await redis.incr('page:views:homepage');

// Bounded counter with Lua
const incrementIfBelow = `
  local current = tonumber(server.call('GET', KEYS[1]) or 0)
  if current < tonumber(ARGV[1]) then
    return server.call('INCR', KEYS[1])
  end
  return -1
`;
const result = await redis.eval(incrementIfBelow, 1, 'seats:event:500', '100');
```

### Python

```python
# Page view counter
views = await redis.incr('page:views:homepage')

# Increment by custom amount
await redis.incrby('api:calls:user:42', 1)
```

### Counter with TTL (Windowed)

```
# Count events per hour, auto-expire old windows
INCR events:2026-03-29T15
EXPIRE events:2026-03-29T15 7200    # 2-hour TTL for safety margin
```

**Gotcha**: `INCR` on a non-existent key sets it to 1. But `EXPIRE` is a separate command - if the process crashes between INCR and EXPIRE, the key lives forever. Use a pipeline:

```javascript
const pipeline = redis.pipeline();
pipeline.incr(key);
pipeline.expire(key, 7200);
await pipeline.exec();
```

This is safe because even if EXPIRE runs on an already-existing key, it just resets the TTL (which is acceptable for windowed counters).

---

## Sharded Counters

When a single key receives extremely high write throughput (thousands of increments per second), it becomes a hot key. The Valkey main thread processes all writes to that key sequentially, creating a bottleneck.

Sharded counters distribute writes across N keys and sum them on read.

### How It Works

```
# Write: pick a random shard (0-15)
INCRBY counter:pageviews:{shard:7} 1

# Read: sum all shards
MGET counter:pageviews:{shard:0} counter:pageviews:{shard:1} ... counter:pageviews:{shard:15}
# Sum the results client-side
```

### Node.js

```javascript
const SHARD_COUNT = 16;

async function incrementSharded(redis, name) {
  const shard = Math.floor(Math.random() * SHARD_COUNT);
  return redis.incr(`counter:${name}:{shard:${shard}}`);
}

async function getShardedCount(redis, name) {
  const keys = Array.from({ length: SHARD_COUNT },
    (_, i) => `counter:${name}:{shard:${i}}`
  );
  const values = await redis.mget(...keys);
  return values.reduce((sum, v) => sum + (parseInt(v) || 0), 0);
}
```

### Python

```python
import random

SHARD_COUNT = 16

async def increment_sharded(redis, name: str):
    shard = random.randint(0, SHARD_COUNT - 1)
    return await redis.incr(f'counter:{name}:{{shard:{shard}}}')

async def get_sharded_count(redis, name: str) -> int:
    keys = [f'counter:{name}:{{shard:{i}}}' for i in range(SHARD_COUNT)]
    values = await redis.mget(*keys)
    return sum(int(v) for v in values if v is not None)
```

### When to Shard

| Throughput | Approach |
|-----------|----------|
| < 10K writes/sec | Single INCR key is fine |
| 10K-100K writes/sec | Shard to 8-16 keys |
| > 100K writes/sec | Shard to 32-64 keys, consider client-side batching |

**Cluster note**: The `{shard:N}` hash tag in the examples above co-locates all shards on the same node, allowing MGET to work. If you want to distribute load across cluster nodes, remove the hash tags - but then you must read each shard individually or use a pipeline.

---

## Idempotency Keys

Prevent duplicate processing of the same operation using `SET NX EX` as an atomic "claim" mechanism.

### Pattern

```
# Before processing request, try to claim the idempotency key
SET idempotent:payment:order-5678 "processing" NX EX 3600
# Returns OK -> first time, proceed with processing
# Returns nil -> duplicate, return cached result

# After processing, store the result
SET idempotent:payment:order-5678 "{\"status\":\"success\",\"id\":\"pay_abc\"}" XX EX 86400
```

### Node.js

```javascript
async function executeIdempotent(redis, operationId, fn) {
  const key = `idempotent:${operationId}`;

  // Try to claim
  const claimed = await redis.set(key, 'processing', 'NX', 'EX', 3600);
  if (!claimed) {
    // Already processed or in progress - return cached result
    const cached = await redis.get(key);
    return cached === 'processing' ? null : JSON.parse(cached);
  }

  try {
    const result = await fn();
    // Store result for future lookups
    await redis.set(key, JSON.stringify(result), 'XX', 'EX', 86400);
    return result;
  } catch (err) {
    // On failure, remove claim so retry can proceed
    await redis.del(key);
    throw err;
  }
}
```

### Python

```python
async def execute_idempotent(redis, operation_id: str, fn):
    key = f'idempotent:{operation_id}'

    claimed = await redis.set(key, 'processing', nx=True, ex=3600)
    if not claimed:
        cached = await redis.get(key)
        if cached == b'processing':
            return None  # Still in progress
        return json.loads(cached)

    try:
        result = await fn()
        await redis.set(key, json.dumps(result), xx=True, ex=86400)
        return result
    except Exception:
        await redis.delete(key)
        raise
```

### Gotchas

- **TTL is essential**: Without it, a crashed process leaves a permanent claim that blocks all retries.
- **Valkey 9.0+ alternative**: Use `DELIFEQ` to safely clean up claims: `DELIFEQ idempotent:op123 "processing"` deletes only if the value is still "processing".

---

## HyperLogLog for Approximate Unique Counting

HyperLogLog counts unique elements with 0.81% standard error using only 12 KB of memory - regardless of whether you count 100 or 100 million unique elements.

### When to Use

- Unique visitors per page/day
- Distinct IP addresses
- Unique search queries
- Any cardinality estimation where exact counts are not required

### Basic Usage

```
# Count unique visitors
PFADD visitors:2026-03-29 "user:100" "user:200" "user:300"
PFADD visitors:2026-03-29 "user:100"    # duplicate, ignored

PFCOUNT visitors:2026-03-29
# (integer) 3

# Merge multiple days for weekly count
PFMERGE visitors:week:13 visitors:2026-03-29 visitors:2026-03-28 visitors:2026-03-27
PFCOUNT visitors:week:13
```

### Node.js

```javascript
async function trackUniqueVisitor(redis, page, userId) {
  const dateKey = new Date().toISOString().split('T')[0];
  await redis.pfadd(`visitors:${page}:${dateKey}`, userId);
}

async function getUniqueCount(redis, page, date) {
  return redis.pfcount(`visitors:${page}:${date}`);
}
```

### Python

```python
from datetime import date

async def track_unique_visitor(redis, page: str, user_id: str):
    key = f'visitors:{page}:{date.today().isoformat()}'
    await redis.pfadd(key, user_id)

async def get_unique_count(redis, page: str, date_str: str) -> int:
    return await redis.pfcount(f'visitors:{page}:{date_str}')
```

### Memory Comparison

| Method | 1M unique elements | Memory |
|--------|-------------------|--------|
| SET (exact) | SADD per element | ~50 MB |
| HyperLogLog (approximate) | PFADD per element | 12 KB |

---

## BITFIELD-Based Packed Counters

`BITFIELD` packs multiple small counters into a single string key. Each counter occupies a fixed number of bits.

### Use Cases

- Per-user feature usage counters (many counters per user, each 0-255)
- Compact analytics (hourly counters for 24 hours in one key)
- Game stats (multiple small stats per player)

### Example: 24 Hourly Counters in One Key

```
# Increment hour 14's counter (8-bit unsigned, max 255)
BITFIELD stats:page:homepage INCRBY u8 #14 1

# Read all 24 hours
BITFIELD stats:page:homepage GET u8 #0 GET u8 #1 ... GET u8 #23
```

The `#N` syntax means "Nth counter of the specified width". `u8 #14` means the 14th 8-bit unsigned integer.

### Node.js

```javascript
async function incrementHourlyCounter(redis, page, hour) {
  return redis.bitfield(
    `stats:hourly:${page}`, 'INCRBY', 'u8', `#${hour}`, 1
  );
}

async function getHourlyCounts(redis, page) {
  const args = [];
  for (let h = 0; h < 24; h++) {
    args.push('GET', 'u8', `#${h}`);
  }
  return redis.bitfield(`stats:hourly:${page}`, ...args);
}
```

### Overflow Control

```
# Wrap around on overflow (default)
BITFIELD key OVERFLOW WRAP INCRBY u8 #0 1

# Saturate at max value
BITFIELD key OVERFLOW SAT INCRBY u8 #0 1

# Fail on overflow (returns nil)
BITFIELD key OVERFLOW FAIL INCRBY u8 #0 1
```

---

## Deduplication

### SET NX for Exact Deduplication

Use `SET NX EX` to track processed event IDs. If SET returns nil, the event was already processed.

```
# Check-and-mark as processed, atomically
SET dedup:event:evt-abc123 1 NX EX 86400
# OK -> new event, process it
# nil -> duplicate, skip it
```

### SISMEMBER for Set-Based Deduplication

When you need to check many items against a known set:

```
SADD processed:batch:42 "evt-1" "evt-2" "evt-3"
SMISMEMBER processed:batch:42 "evt-1" "evt-4" "evt-2"
# [1, 0, 1] -> evt-1 and evt-2 already processed, evt-4 is new
```

### Bloom Filters for Probabilistic Deduplication

When exact deduplication uses too much memory (millions of event IDs), Bloom filters provide space-efficient membership testing with a configurable false positive rate.

Requires the valkey-bloom module.

```
# Create filter: 0.01% false positive rate, 1M expected elements
BF.RESERVE dedup:events 0.0001 1000000

# Add and check
BF.ADD dedup:events "evt-abc123"
# (integer) 1 -> newly added

BF.EXISTS dedup:events "evt-abc123"
# (integer) 1 -> probably exists

BF.EXISTS dedup:events "evt-never-seen"
# (integer) 0 -> definitely does not exist
```

**Key property**: Bloom filters never have false negatives. If `BF.EXISTS` returns 0, the element was definitely never added. If it returns 1, the element was probably added (with a configurable false positive rate).

### Choosing a Deduplication Strategy

| Strategy | Memory | Accuracy | TTL Support | Best For |
|----------|--------|----------|-------------|----------|
| SET NX EX | High (one key per event) | Exact | Yes | Low-medium volume, must be exact |
| SISMEMBER | Medium (one set) | Exact | Per-set only | Batch dedup, bounded sets |
| Bloom filter | Low (fixed size) | Probabilistic | No (recreate) | High volume, some false positives OK |
| HyperLogLog | Lowest (12 KB) | Count only | Per-key | Only need "how many unique" |

---

## See Also

- [String Commands](../basics/data-types.md) - INCR, INCRBY, SET NX EX for atomic counters
- [Specialized Types](../basics/data-types.md) - HyperLogLog, Bitmaps, BITFIELD
- [Scripting and Functions](../basics/server-and-scripting.md) - Lua scripts for bounded counters
- [Conditional Operations](../valkey-features/conditional-ops.md) - DELIFEQ for safe idempotency key cleanup (Valkey 9.0+)
- [Rate Limiting Patterns](rate-limiting.md) - windowed counters for rate limiting
- [Lock Patterns](locks.md) - SET NX for mutual exclusion (related to idempotency keys)
- [Queue Patterns](queues.md) - idempotent queue processing with deduplication
- [Leaderboard Patterns](leaderboards.md) - scored counting with sorted sets
- [Key Best Practices](../best-practices/keys.md) - hot key mitigation strategies
- [Memory Best Practices](../best-practices/memory.md) - encoding thresholds for compact storage
- [Performance Best Practices](../best-practices/performance.md) - pipelining for counter-with-TTL patterns
- [Cluster Best Practices](../best-practices/cluster.md) - hash tags for sharded counters in cluster mode
- [High Availability Best Practices](../best-practices/high-availability.md) - idempotency considerations for counter retries during failover
- [Anti-Patterns Quick Reference](../anti-patterns/quick-reference.md) - single hot key for counters, missing pipelining
