# Approximate Counting and Deduplication

Use when counting unique elements with HyperLogLog, packing compact counters with BITFIELD, or deduplicating events and requests.

## HyperLogLog for Approximate Unique Counting

HyperLogLog counts unique elements with 0.81% standard error using up to 12 KB of memory at full cardinality. Small counts use a sparse encoding and take much less - a fresh HLL with ~100 unique elements is dozens of bytes, not 12 KB. It auto-promotes to dense once the sparse encoding runs out of space.

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

# Merge multiple days for weekly count (creates a new HLL key)
PFMERGE visitors:week:13 visitors:2026-03-29 visitors:2026-03-28 visitors:2026-03-27
PFCOUNT visitors:week:13

# Or: on-the-fly merge without creating a destination key
PFCOUNT visitors:2026-03-29 visitors:2026-03-28 visitors:2026-03-27
```

**Read-routing note.** `PFCOUNT` is `READONLY` at the command level but `RW` at the key-spec level - it may mutate the HLL (caching cardinality in the header) and propagate to replicas. Treat it as write-path for cluster read-routing decisions and ACLs that forbid writes.

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

### Type-width limits

Signed integers go up to `i64`. **Unsigned integers max out at `u63`, not `u64`** - `BITFIELD key INCRBY u64 #0 1` errors with *"Invalid bitfield type. Note that u64 is not supported but i64 is."* RESP can't reliably represent unsigned integers above `INT64_MAX`, so for 64-bit counters use `i64` or stay at `u63` max.

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

### SMISMEMBER for Set-Based Deduplication

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
# Bounded memory: filter rejects new adds past capacity (BF.ADD returns 0 or errors).
BF.RESERVE dedup:events 0.0001 1000000 NONSCALING

# Default (scaling): filter grows by adding sub-filters past capacity.
# The 0.0001 error rate only applies to the first sub-filter -
# effective FPR compounds across sub-filters, and memory is unbounded.
BF.RESERVE dedup:events 0.0001 1000000

# Add and check
BF.ADD dedup:events "evt-abc123"
# (integer) 1 -> newly added

BF.EXISTS dedup:events "evt-abc123"
# (integer) 1 -> probably exists

BF.EXISTS dedup:events "evt-never-seen"
# (integer) 0 -> definitely does not exist
```

Full syntax: `BF.RESERVE key error_rate capacity [EXPANSION n] [NONSCALING]`. Pick `NONSCALING` when the stated error rate must hold for the life of the filter; use default scaling (optionally with `EXPANSION`) when capacity uncertainty matters more than FPR stability.

Bloom filters never have false negatives. `BF.EXISTS` returning 0 means the element was definitely never added. Returning 1 means it was probably added (configurable false positive rate).

### Choosing a Deduplication Strategy

| Strategy | Memory | Accuracy | TTL Support | Best For |
|----------|--------|----------|-------------|----------|
| SET NX EX | High (one key per event) | Exact | Yes | Low-medium volume, must be exact |
| SISMEMBER | Medium (one set) | Exact | Per-set only | Batch dedup, bounded sets |
| Bloom filter | Low (fixed size) | Probabilistic | No (recreate) | High volume, some false positives OK |
| HyperLogLog | Lowest (12 KB) | Count only | Per-key | Only need "how many unique" |

---
