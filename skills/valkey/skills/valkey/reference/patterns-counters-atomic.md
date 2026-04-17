# Atomic and Sharded Counters

Use when implementing atomic counters, sharded counters for high-throughput hot keys, or idempotency keys to prevent duplicate processing.

## Atomic Counters

`INCR`, `INCRBY`, `DECR`, `DECRBY`, and `INCRBYFLOAT` are atomic single-key operations. No race conditions, no read-modify-write cycles.

### Basic Counter

```
INCR page:views:homepage
# (integer) 1

INCRBY page:views:homepage 5
# (integer) 6

INCRBYFLOAT metric:temperature:avg 19.99
# "19.99"  (new key starts at 0, then adds 19.99)

DECR page:views:homepage
# (integer) 5
```

### Overflow and precision limits

- **INCR / INCRBY / DECR / DECRBY** operate on 64-bit signed integers (`LLONG_MIN .. LLONG_MAX`, roughly `-9.22 × 10^18 .. 9.22 × 10^18`). An operation that would cross the boundary returns `increment or decrement would overflow` - the counter does NOT silently wrap. Plan a rotation strategy (key-per-window + EXPIRE) for long-running counters that could exhaust int64.
- **INCRBYFLOAT** uses `long double` accumulation. It errors only on NaN / Infinity results, not on magnitude. But repeated fractional additions drift (the classic `0.1 + 0.2 ≠ 0.3`). **Don't use INCRBYFLOAT for money.** Store the smallest currency unit (cents, satoshis) as an integer and use INCRBY; that's both exact and matches financial-rounding conventions.
- **Replication rewrite**: INCRBYFLOAT propagates to replicas and AOF as `SET <key> <final_value> KEEPTTL` - the float math happens once on the primary and the replica just stores the result. Operators grepping replication or AOF for `INCRBYFLOAT` won't find it under that name.

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

`INCR` on a non-existent key sets it to 1, but `EXPIRE` is separate - a crash between INCR and EXPIRE leaves a permanent key. Use a pipeline:

```javascript
const pipeline = redis.pipeline();
pipeline.incr(key);
pipeline.expire(key, 7200);
await pipeline.exec();
```

Safe because EXPIRE on an existing key just resets the TTL (acceptable for windowed counters).

---

## Sharded Counters

A single key receiving tens of thousands of increments per second becomes a hot key. Even though each `INCR` is O(1), they all serialize on the single object and its replication stream - you can't parallelize writes to one key.

Sharded counters distribute writes across N **distinct keys** and sum on read. The goal is avoiding the single-key bottleneck, not cluster-node distribution - two separate concerns:

- **Avoid the hot-key bottleneck**: N keys → N independent objects → writes parallelize (even within a single node).
- **Distribute across cluster nodes**: only matters when one node can't keep up with aggregate traffic.

You usually want the first; the second is rarer. The examples below put the counter name inside a single shared hash tag (`counter:{pageviews}:N`) so every shard hashes to the same slot - that keeps the hot-key fix while letting one `MGET` read all shards. Drop the hash tag only if you need genuine cross-node fan-out (and accept the MGET-per-slot complexity on read - see below).

### How It Works

```
# Write: pick a random shard (0-15)
INCRBY counter:{pageviews}:7 1

# Read: sum all shards (all land on the same slot because the hash tag is "pageviews")
MGET counter:{pageviews}:0 counter:{pageviews}:1 ... counter:{pageviews}:15
# Sum the results client-side
```

### Node.js

```javascript
const SHARD_COUNT = 16;

async function incrementSharded(redis, name) {
  const shard = Math.floor(Math.random() * SHARD_COUNT);
  return redis.incr(`counter:{${name}}:${shard}`);
}

async function getShardedCount(redis, name) {
  const keys = Array.from({ length: SHARD_COUNT },
    (_, i) => `counter:{${name}}:${i}`
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
    return await redis.incr(f'counter:{{{name}}}:{shard}')

async def get_sharded_count(redis, name: str) -> int:
    keys = [f'counter:{{{name}}}:{i}' for i in range(SHARD_COUNT)]
    values = await redis.mget(*keys)
    return sum(int(v) for v in values if v is not None)
```

### When to Shard

| Throughput | Approach |
|-----------|----------|
| < 10K writes/sec | Single INCR key is fine |
| 10K-100K writes/sec | Shard to 8-16 keys |
| > 100K writes/sec | Shard to 32-64 keys, consider client-side batching |

**Cluster read without hash tags**: If you drop the hash tags to spread shards across cluster nodes, you lose atomic `MGET` across them (cross-slot error). Replace the MGET with a client-side fan-out: group shard keys by slot, issue one `MGET` per slot in a pipeline, and sum the results. A cluster-aware GLIDE or smart-client library can do this automatically with per-shard pipelines.

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
    // Another caller already claimed this operation.
    const cached = await redis.get(key);
    // cached === 'processing' means the other worker is still running
    // (or finished in the brief window between our SET NX and GET).
    // Caller responsibility: back off and retry until the cached value is the final JSON.
    if (cached === null || cached === 'processing') return null;
    return JSON.parse(cached);
  }

  try {
    const result = await fn();
    // Store result for future lookups (XX = only update the existing claim)
    await redis.set(key, JSON.stringify(result), 'XX', 'EX', 86400);
    return result;
  } catch (err) {
    // On failure, remove claim so retry can proceed.
    // Prefer DELIFEQ (9.0+) so you only delete if the claim is still yours:
    //   DELIFEQ idempotent:<operationId> "processing"
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
