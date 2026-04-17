# Key Best Practices

Use when designing key schemas, diagnosing hot key or big key problems, planning key expiration strategies, or analyzing key characteristics in production.

## Contents

- Key Naming Conventions
- Avoiding Hot Keys
- Avoiding Big Keys
- Key Expiration Strategies
- Key Analysis Commands
- Quick Reference: Key Anti-Patterns

---

## Key Naming Conventions

Use colon-delimited namespaces for readability and operability:

```
# Good: clear, organized, scannable
user:1000:profile
user:1000:sessions
order:5678:items
cache:api:products:page:1
ratelimit:user:42:2026-03-29T15

# Bad: abbreviated, no structure
u1000p
o5678i
rl42
```

Short keys save negligible memory. A 20-byte vs 5-byte key name saves 15 bytes - irrelevant when values are hundreds of bytes or more. Readability and operational tooling (SCAN patterns, monitoring) matter far more.

### Naming Guidelines

| Guideline | Example | Reason |
|-----------|---------|--------|
| Use colons as separators | `user:1000:profile` | Convention recognized by most tooling |
| Start with entity type | `order:5678` | Groups related keys in SCAN results |
| Include IDs explicitly | `session:abc123` | Makes debugging straightforward |
| Prefix cache keys | `cache:api:products` | Distinguishes cache from persistent data |
| Use lowercase | `user:profile` not `User:Profile` | Consistency, avoids case-sensitivity bugs |

### Cluster Hash Tags

In cluster mode, all operations on a key go to one shard based on the key's hash slot. To co-locate related keys on the same shard (required for multi-key commands like `MGET` or Lua scripts), use hash tags:

```
# These land on the same shard (hash slot computed from "user:1000")
{user:1000}:profile
{user:1000}:sessions
{user:1000}:preferences

# Multi-key operation now works in cluster
MGET {user:1000}:profile {user:1000}:sessions
```

**Warning**: Over-using a single hash tag concentrates all those keys on one shard, creating a hot shard. Use hash tags only when you need multi-key atomicity, not as a general organizational pattern.

---

## Avoiding Hot Keys

A hot key receives extreme read/write traffic. In cluster mode, all operations on a key route to one shard, creating a bottleneck.

### Detection

```bash
# Identify hot keys (requires CONFIG SET maxmemory-policy with LFU)
valkey-cli --hotkeys

# Check access frequency of a specific key (requires LFU policy)
OBJECT FREQ mykey

# Monitor commands in real-time (use briefly - impacts performance)
MONITOR
```

### Mitigation Strategies

**1. Shard the key logically**:

Instead of one counter hash, distribute across shards:

```
# Before: single hot key
HINCRBY counters page_views 1

# After: shard by hash to spread across cluster nodes
HINCRBY counters:{0} page_views 1
HINCRBY counters:{1} page_views 1
# Pick shard: hash(request_id) % num_shards
# Sum at read time: HGET counters:{0} page_views + HGET counters:{1} page_views
```

**2. Read replicas for read-heavy hot keys**:

Route read traffic to replicas in Sentinel and cluster setups.

**3. Client-side caching**:

Use `CLIENT TRACKING` to cache hot read-only keys locally, eliminating server round-trips. See [patterns/caching](patterns-caching-strategies.md).

**4. Local application cache with short TTL**:

For data tolerating slight staleness, cache in application memory for 1-5 seconds.

---

## Avoiding Big Keys

Big keys (millions of elements or multi-MB values) cause latency spikes on `HGETALL`, `SMEMBERS`, or `DEL`.

### Detection

```bash
# Find keys with the most elements
valkey-cli --bigkeys

# Find keys consuming the most memory
valkey-cli --memkeys

# Check specific key size
MEMORY USAGE mykey
OBJECT ENCODING mykey
```

### Size Guidelines

| Data Type | Recommended Max | Reason |
|-----------|----------------|--------|
| Hash | < 10,000 fields | `HGETALL` latency, encoding thresholds |
| Set | < 100,000 members | `SMEMBERS` blocks, intersection cost |
| Sorted Set | < 100,000 members | Range query performance |
| List | < 100,000 elements | `LRANGE` performance |
| String value | < 1 MB | Network + memory pressure |

### Mitigation

**Split large collections**:

```
# Instead of one hash with 1M fields
HSET user:events field1 val1 ... field1000000 val1000000

# Split into date-based buckets
HSET user:1000:events:2026-03 field1 val1 ...
HSET user:1000:events:2026-04 field1 val1 ...
```

**Incremental deletion for existing big keys**:

```
# Don't DEL a hash with 1M fields (even UNLINK queues a large free)
# Instead, drain incrementally:
HSCAN bigkey 0 COUNT 100
# For each batch of fields returned:
HDEL bigkey field1 field2 ... field100
# Repeat until empty, then:
UNLINK bigkey
```

---

## Key Expiration Strategies

### Active vs Passive Expiration

Valkey uses two expiration mechanisms:

- **Passive**: Expired keys are deleted when a client accesses them
- **Active**: A periodic background task samples random keys with TTLs and deletes expired ones

Expired keys may linger in memory until accessed or sampled. With many short-lived keys, active expiration keeps memory in check.

### Expiration Commands

| Command | Precision | Use |
|---------|-----------|-----|
| `EXPIRE key seconds` | Seconds | Add TTL to existing key |
| `PEXPIRE key ms` | Milliseconds | High-precision TTL |
| `EXPIREAT key timestamp` | Seconds (Unix epoch) | Expire at specific time |
| `PERSIST key` | - | Remove TTL (make permanent) |
| `TTL key` | Seconds | Check remaining TTL (-1 = no TTL, -2 = key gone) |
| `PTTL key` | Milliseconds | High-precision TTL check |

### Set TTL at Write Time

Set TTL at write time to avoid the race between write and expire:

```
# Atomic: write + TTL in one command
SET cache:key value EX 3600

# Race-prone: key exists without TTL briefly
SET cache:key value
EXPIRE cache:key 3600    # If this fails, key lives forever
```

---

## Key Analysis Commands

### OBJECT Subcommands

| Command | Returns | Use Case |
|---------|---------|----------|
| `OBJECT HELP` | Available subcommands | Discovery |
| `OBJECT ENCODING key` | Internal encoding (listpack, hashtable, etc.) | Memory optimization |
| `OBJECT FREQ key` | LFU access frequency counter | Hot key detection (requires LFU policy) |
| `OBJECT IDLETIME key` | Seconds since last access | Cold key detection (requires LRU policy) |
| `OBJECT REFCOUNT key` | Reference count | Internal debugging |

### Practical Analysis Workflow

```bash
# 1. Find big keys
valkey-cli --bigkeys

# 2. Check encoding of suspicious keys
OBJECT ENCODING mykey
# If "hashtable" - check if it could be "listpack" (smaller hash)

# 3. Check memory usage
MEMORY USAGE mykey
# Returns bytes including overhead

# 4. Check access patterns
OBJECT FREQ mykey      # With LFU policy
OBJECT IDLETIME mykey  # With LRU policy

# 5. Memory-level analysis
MEMORY DOCTOR
# Human-readable memory health report
```

---

## Quick Reference: Key Anti-Patterns

| Anti-Pattern | Impact | Fix |
|-------------|--------|-----|
| Short cryptic key names | Minimal savings, poor operability | Use `user:1000:profile` style |
| Single hot key for counters | Shard bottleneck | Shard: `counter:{0}`, `counter:{1}` |
| Hash with millions of fields | Latency spikes on bulk ops | Split into buckets |
| No TTL on cache keys | Unbounded memory growth | Always set TTL at write time |
| Over-using hash tags | Hot shard | Only use for multi-key atomicity |
| `HGETALL` on unknown-size hashes | Potential latency spike | Use `HMGET` for known fields or `HSCAN` |

---

