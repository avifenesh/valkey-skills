# Atomic and Sharded Counters

Use when implementing atomic counters, sharded counters for high-throughput hot keys, or idempotency keys to prevent duplicate processing.

## Contents

- Atomic Counters (line 13)
- Sharded Counters (line 81)
- Idempotency Keys (line 146)

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
