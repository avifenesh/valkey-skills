# Learning Guide: Valkey for Application Developers

**Generated**: 2026-03-29
**Sources**: 40 resources analyzed
**Depth**: deep

## Prerequisites

What you should know before diving in:
- Basic understanding of key-value data stores
- Familiarity with at least one programming language (Node.js, Python, Java, or Go)
- Networking fundamentals (TCP, latency, connection management)
- If migrating from Redis: your existing Redis knowledge transfers directly

## TL;DR

- Valkey is a Linux Foundation fork of Redis 7.2.4, fully open source under BSD 3-clause license
- Drop-in compatible with Redis OSS through 7.2 - existing clients, RDB/AOF files, and protocols work unchanged
- Valkey 8.0 tripled throughput to 1.2M RPS via enhanced I/O multithreading; Valkey 9.0 reaches 1 billion RPS across 2,000 nodes
- Key Valkey-only features: `SET IFEQ` (conditional update), `DELIFEQ` (conditional delete), hash field expiration, numbered databases in cluster mode, polygon geospatial queries, atomic slot migration
- Always prefer `UNLINK` over `DEL`, `SCAN` over `KEYS`, pipelining over sequential commands, and connection pooling over per-request connections

---

## 1. What Is Valkey

Valkey is a high-performance, open-source, in-memory key-value data store. It was forked from Redis 7.2.4 in March 2024 after Redis switched to a source-available license. Valkey is governed by the Linux Foundation and uses the permissive BSD 3-clause license.

### Key Facts

| Property | Value |
|----------|-------|
| License | BSD 3-clause (fully open source) |
| Governance | Linux Foundation |
| Forked from | Redis 7.2.4 (March 2024) |
| Latest versions | 8.1.x (stable), 9.0.x (latest) |
| Protocol | RESP2 / RESP3 (fully compatible) |
| Contributors | 346+ active contributors (2025) |

### Compatibility Story

Valkey is compatible with Redis OSS versions 2.x through 7.2.x. Existing Redis clients (ioredis, Jedis, redis-py, go-redis) work without modification. RDB and AOF files transfer directly. **Redis Community Edition 7.4+ uses proprietary code and incompatible data formats** - direct migration from those versions requires tools like RIOT or RedisShake.

### What Valkey Does NOT Have (vs Redis 8+)

Redis 8 added proprietary features not available in Valkey: Redis Query Engine, secondary indexing, vector search, and built-in time series. If you need these, evaluate Valkey modules or alternative solutions.

---

## 2. Data Types and Commands Reference

### Core Data Types

**Strings** - Binary-safe byte sequences. The simplest type, used for caching, counters, flags, and serialized objects.

| Command | Purpose | Complexity |
|---------|---------|------------|
| `SET key value [EX seconds] [NX\|XX]` | Set a value with optional TTL and condition | O(1) |
| `GET key` | Retrieve a value | O(1) |
| `MSET key1 val1 key2 val2 ...` | Set multiple keys atomically | O(N) |
| `MGET key1 key2 ...` | Get multiple values | O(N) |
| `INCR key` / `INCRBY key n` | Atomic increment | O(1) |
| `SETNX key value` | Set only if key does not exist | O(1) |
| `SET key value IFEQ old_value` | **Valkey 8.1+**: Conditional update if current value matches | O(1) |

**Hashes** - Field-value maps, ideal for representing objects.

| Command | Purpose | Complexity |
|---------|---------|------------|
| `HSET key field value [field value ...]` | Set one or more fields | O(N) |
| `HGET key field` | Get a single field | O(1) |
| `HMGET key field1 field2 ...` | Get multiple fields | O(N) |
| `HGETALL key` | Get all fields and values | O(N) |
| `HINCRBY key field n` | Atomic field increment | O(1) |
| `HDEL key field [field ...]` | Delete fields | O(N) |
| `HEXPIRE key seconds FIELDS n field [field ...]` | **Valkey 9.0+**: Set per-field TTL | O(N) |
| `HSETEX key [EX seconds] FVS n field value ...` | **Valkey 9.0+**: Set fields with TTL | O(N) |
| `HGETEX key [EX seconds] FIELDS n field ...` | **Valkey 9.0+**: Get fields and refresh TTL | O(N) |

**Lists** - Ordered sequences, insertion-order maintained. Use for queues, stacks, and event logs.

| Command | Purpose | Complexity |
|---------|---------|------------|
| `LPUSH key value [value ...]` | Push to head | O(N) |
| `RPUSH key value [value ...]` | Push to tail | O(N) |
| `LPOP key [count]` | Pop from head | O(N) |
| `RPOP key [count]` | Pop from tail | O(N) |
| `LRANGE key start stop` | Get range of elements | O(S+N) |
| `BLPOP key [key ...] timeout` | Blocking pop from head | O(N) |
| `LPOS key element` | Find element position | O(N) |

**Sets** - Unordered collections of unique strings. Use for tags, membership, and deduplication.

| Command | Purpose | Complexity |
|---------|---------|------------|
| `SADD key member [member ...]` | Add members | O(N) |
| `SISMEMBER key member` | Check membership | O(1) |
| `SMEMBERS key` | Get all members (caution: blocking) | O(N) |
| `SINTER key1 key2 ...` | Intersection | O(N*M) |
| `SUNION key1 key2 ...` | Union | O(N) |
| `SCARD key` | Count members | O(1) |

**Sorted Sets** - Ordered by score. Use for leaderboards, priority queues, and time-series indexes.

| Command | Purpose | Complexity |
|---------|---------|------------|
| `ZADD key score member [score member ...]` | Add with score | O(log N) |
| `ZRANGE key min max [BYSCORE\|BYLEX] [LIMIT offset count]` | Get range | O(log N + M) |
| `ZREVRANGE key start stop` | Get range, high to low | O(log N + M) |
| `ZRANK key member` / `ZREVRANK key member` | Get rank | O(log N) |
| `ZINCRBY key increment member` | Increment score | O(log N) |
| `ZSCORE key member` | Get score | O(1) |
| `ZPOPMIN key [count]` / `ZPOPMAX key [count]` | Pop min/max score | O(log N * M) |

**Streams** - Append-only log with consumer groups. Use for event sourcing, messaging, and activity feeds.

| Command | Purpose | Complexity |
|---------|---------|------------|
| `XADD key * field value [field value ...]` | Append entry | O(1) |
| `XREAD COUNT n BLOCK ms STREAMS key id` | Read entries (optionally blocking) | O(N) |
| `XRANGE key start end [COUNT n]` | Get entries by ID range | O(log N + M) |
| `XLEN key` | Stream length | O(1) |
| `XGROUP CREATE key group id` | Create consumer group | O(1) |
| `XREADGROUP GROUP group consumer COUNT n STREAMS key >` | Read via consumer group | O(M) |
| `XACK key group id [id ...]` | Acknowledge message processing | O(N) |
| `XTRIM key MAXLEN\|MINID [~] threshold` | Trim stream | O(N) |

### Pub/Sub

| Command | Purpose |
|---------|---------|
| `SUBSCRIBE channel [channel ...]` | Subscribe to channels |
| `PUBLISH channel message` | Publish to a channel |
| `PSUBSCRIBE pattern [pattern ...]` | Pattern-based subscribe |
| `SSUBSCRIBE shardchannel` | Sharded pub/sub (cluster-friendly) |
| `SPUBLISH shardchannel message` | Publish to sharded channel |

**Key distinction**: Regular pub/sub broadcasts to all cluster nodes. Sharded pub/sub (via `SSUBSCRIBE`/`SPUBLISH`) routes messages only within the shard owning the channel, dramatically reducing cluster bus traffic.

**Critical**: Pub/sub is fire-and-forget (at-most-once). Messages are lost if no subscriber is listening. For durable messaging, use Streams.

### Scripting and Functions

| Command | Purpose |
|---------|---------|
| `EVAL script numkeys key [key ...] arg [arg ...]` | Execute Lua script |
| `EVALSHA sha1 numkeys key [key ...] arg [arg ...]` | Execute cached script by SHA1 |
| `FUNCTION LOAD [REPLACE] function_code` | Load a persistent function library |
| `FCALL function numkeys key [key ...] arg [arg ...]` | Call a loaded function |

**Functions vs EVAL**: Functions persist across restarts and are replicated. EVAL scripts are volatile and must be reloaded. Prefer Functions for production workloads.

### Transactions

| Command | Purpose |
|---------|---------|
| `MULTI` | Begin transaction |
| `EXEC` | Execute queued commands |
| `DISCARD` | Abort transaction |
| `WATCH key [key ...]` | Optimistic lock (abort EXEC if keys change) |

### Specialized Types

| Type | Key Commands | Use Case |
|------|-------------|----------|
| **HyperLogLog** | `PFADD`, `PFCOUNT`, `PFMERGE` | Cardinality estimation (unique counts) |
| **Bitmaps** | `SETBIT`, `GETBIT`, `BITCOUNT`, `BITOP` | Flags, presence tracking, analytics |
| **Geospatial** | `GEOADD`, `GEOSEARCH`, `GEODIST` | Location queries (radius, box, polygon) |
| **JSON** (module) | `JSON.SET`, `JSON.GET`, `JSON.ARRAPPEND` | Native JSON document storage with JSONPath |
| **Bloom Filter** (module) | `BF.ADD`, `BF.EXISTS`, `BF.RESERVE` | Probabilistic membership testing |

---

## 3. Best Practices and Optimization

### UNLINK vs DEL

`DEL` is synchronous and blocks the main thread. For large keys (big lists, sets, hashes), this causes latency spikes.

`UNLINK` removes the key reference in O(1) on the main thread, then reclaims memory asynchronously in a background thread.

```
-- Prefer this:
UNLINK mykey

-- Over this:
DEL mykey
```

**Valkey 8.0+ note**: The default config sets `lazyfree-lazy-user-del yes`, making `DEL` behave like `UNLINK` automatically. However, explicitly using `UNLINK` is still recommended for clarity and backward compatibility.

### SCAN vs KEYS

`KEYS pattern` blocks the server while scanning the entire keyspace. With millions of keys, this freezes all clients for seconds.

`SCAN cursor [MATCH pattern] [COUNT hint]` iterates incrementally in small batches.

```
-- NEVER do this in production:
KEYS user:*

-- Do this instead:
SCAN 0 MATCH user:* COUNT 100
-- Continue with returned cursor until cursor = 0
```

Variants exist for each data type: `SSCAN` (sets), `HSCAN` (hashes), `ZSCAN` (sorted sets).

**Important**: SCAN may return duplicates and zero-element pages. Your application must handle both: deduplicate results and keep iterating until the cursor returns 0.

### Pipeline Batching

Each command without pipelining incurs a full network round-trip. Pipelining sends multiple commands in one batch and reads all responses at once.

```
-- Without pipelining: N round-trips
SET key1 val1  -> OK
SET key2 val2  -> OK
SET key3 val3  -> OK

-- With pipelining: 1 round-trip
[SET key1 val1, SET key2 val2, SET key3 val3] -> [OK, OK, OK]
```

**Performance impact**: Pipelining can achieve up to 10x the baseline throughput. Benchmarks show throughput increases almost linearly with pipeline depth.

**Batch size recommendation**: Send batches of ~10,000 commands, read replies, then send the next batch. This balances throughput against server memory usage for queued responses.

### Connection Pooling

Creating a new TCP connection per request is expensive (TLS handshake, AUTH, SELECT). Use connection pools.

**Valkey GLIDE** (the official client) uses a single multiplexed connection per cluster node with auto-pipelining, avoiding the pool management overhead entirely.

**For traditional clients** (ioredis, Jedis, redis-py):
- Pool size: start with (number of CPU cores * 2) connections
- Set idle timeouts to reclaim unused connections
- Use separate pools for pub/sub (subscriber connections are monopolized)

### Memory-Efficient Data Structure Choices

Valkey uses compact encodings for small collections, saving up to 10x memory:

| Data Type | Compact Encoding Threshold (defaults) |
|-----------|--------------------------------------|
| Hashes | <= 128 entries AND values <= 64 bytes (`hash-max-listpack-entries 128`, `hash-max-listpack-value 64`) |
| Sorted Sets | <= 128 entries AND values <= 64 bytes |
| Sets (strings) | <= 128 entries AND values <= 64 bytes |
| Sets (integers) | <= 512 entries (`set-max-intset-entries 512`) |

**Practical strategy**: Keep hashes under 100 fields where possible. Instead of one key per object field, pack related fields into a single hash. For example, instead of `user:1000:name`, `user:1000:email` as separate keys, use `HSET user:1000 name "Alice" email "alice@example.com"`.

**Advanced**: Split large ID ranges into buckets. Store `object:1234` as field `34` in hash key `object:12`. This keeps ~100 fields per hash - optimal for the compact encoding.

### Lua Scripting vs MULTI/EXEC

Both provide atomicity, but with different capabilities:

| Feature | MULTI/EXEC | Lua Scripts | Functions |
|---------|-----------|-------------|-----------|
| Atomicity | Yes | Yes | Yes |
| Read-then-write | No (can't use results mid-transaction) | Yes | Yes |
| Conditional logic | No (use WATCH for optimistic locking) | Yes | Yes |
| Persists across restart | N/A | No (cache is volatile) | Yes |
| Network overhead | One round-trip (queued) | One round-trip | One round-trip |

**Use MULTI/EXEC** when you just need to batch independent writes atomically.

**Use Lua scripts** when you need to read a value, make a decision, and write - all atomically. Example: rate limiting, compare-and-swap.

**Use Functions** (via `FUNCTION LOAD` / `FCALL`) for production Lua code that should persist and replicate.

**Warning**: Scripts block the server during execution. Keep them fast. Avoid loops over large datasets inside scripts.

### Key Naming Conventions

Use colon-delimited namespaces for organization:

```
-- Good: clear, readable, organized
user:1000:profile
user:1000:sessions
order:5678:items
cache:api:products:page:1

-- Bad: abbreviated, no structure
u1000p
o5678i
```

Short keys save negligible memory compared to the value. Readability and operability matter more.

**Cluster consideration**: Use hash tags `{tag}` to co-locate related keys on the same shard: `{user:1000}:profile`, `{user:1000}:sessions`.

### TTL Strategies and Eviction Policies

**Setting TTLs**:
- Always set TTLs on cache entries - keys without TTLs live forever
- Use `SET key value EX seconds` (or `PX milliseconds`) to set TTL at write time
- Use `EXPIRE key seconds` to add TTL to existing keys
- The `allkeys-lru` policy removes least-recently-used keys under memory pressure even without TTLs, but explicit TTLs give you more control

**Eviction policies** (set via `maxmemory-policy`):

| Policy | Scope | Strategy | Best For |
|--------|-------|----------|----------|
| `allkeys-lru` | All keys | Least Recently Used | General caching (recommended default) |
| `allkeys-lfu` | All keys | Least Frequently Used | Power-law access patterns |
| `volatile-lru` | Keys with TTL | LRU on TTL keys only | Mixed cache + persistent data |
| `volatile-ttl` | Keys with TTL | Shortest TTL first | Explicit TTL-based priority |
| `noeviction` | N/A | Reject writes when full | Data must never be lost |

**Always set `maxmemory`**. Without it, Valkey grows until the OS kills it. Set it to ~75% of available RAM to leave room for fragmentation and fork overhead.

**Tune `maxmemory-samples`**: Default 5 is a good balance. Set to 10 for closer-to-true LRU at slight CPU cost.

### Avoiding Hot Keys and Big Keys

**Hot keys**: A single key receiving extreme read/write traffic becomes a bottleneck. In cluster mode, all operations on a key go to one shard.

- Mitigation: Shard the key logically. Instead of one `counters` hash, use `counters:{shard_id}` and distribute across shards.
- Detection: Use `valkey-cli --hotkeys` to identify hot keys.

**Big keys**: Keys with millions of elements or multi-MB values cause latency spikes on operations like `HGETALL` or `DEL`.

- Mitigation: Keep hashes under 10K fields, lists under 100K elements. Split large collections.
- Detection: Use `valkey-cli --bigkeys` or `--memkeys` to find problematic keys.
- Deletion: Use `UNLINK` (non-blocking) instead of `DEL` for big keys. Use `HSCAN` + `HDEL` to delete big hashes incrementally.

### Persistence Configuration

| Strategy | Data Safety | Performance | When to Use |
|----------|------------|-------------|-------------|
| RDB only | Minutes of potential loss | Best | Caching, non-critical data |
| AOF `everysec` | Up to 1 second of loss | Good | Most applications |
| AOF `always` | Minimal loss | Slowest | Financial data, critical writes |
| RDB + AOF | Best of both | Good | Production recommended |
| None | Total loss on restart | Best | Pure ephemeral cache |

```
# Recommended production configuration
save 900 1                    # RDB: snapshot every 15 min if >= 1 key changed
save 300 10                   # RDB: snapshot every 5 min if >= 10 keys changed
appendonly yes                # Enable AOF
appendfsync everysec          # Fsync every second (good balance)
aof-use-rdb-preamble yes     # Hybrid: RDB preamble in AOF for faster loads
```

### I/O Threading (Valkey 8.0+)

Valkey 8.0 introduced enhanced I/O multithreading that tripled throughput. The main thread still handles command execution (single-threaded for simplicity), but I/O threads handle reading/parsing requests and writing responses concurrently.

```
# Default: 2 threads (main + 1 I/O). Increase for high-throughput workloads:
io-threads 4        # Total threads: main + 3 I/O
                     # Start here for most deployments

# For maximum throughput on dedicated hardware:
io-threads 9        # Total threads: main + 8 I/O
                     # Requires 9+ available CPU cores
```

Valkey 8.1 further offloads TLS negotiation to I/O threads, improving new connection acceptance rates by 300%.

---

## 4. Common Patterns

### Caching (Cache-Aside)

The most common pattern. Application checks cache first, falls back to database on miss, and populates cache on read.

```
value = GET cache:user:1000
if value is nil:
    value = db.query("SELECT * FROM users WHERE id = 1000")
    SET cache:user:1000 value EX 3600    # Cache for 1 hour
return value
```

**Client-side caching**: Valkey supports server-assisted client-side caching via the Tracking feature. The server remembers which keys each client accessed and sends invalidation messages when those keys change. This eliminates network round-trips for frequently accessed data entirely.

Two modes:
- **Default mode**: Server tracks per-client key access. Targeted invalidation. Uses server memory.
- **Broadcast mode (BCAST)**: Clients subscribe to key prefixes. No server memory overhead. More invalidation messages.

### Rate Limiting

**Fixed window** (simplest):

```
-- Allow 100 requests per minute per user
key = "ratelimit:user:42:" + current_minute
count = INCR key
if count == 1:
    EXPIRE key 60
if count > 100:
    reject request
```

**Sliding window counter** (more accurate, two keys):

```
-- Use current + previous window with weighted overlap
current_count = GET ratelimit:user:42:current_window
previous_count = GET ratelimit:user:42:previous_window
weight = (seconds_remaining_in_window / window_size)
effective_count = current_count + (previous_count * weight)
```

**Token bucket** (burst-tolerant): Store token count and last refill timestamp. Use Lua script for atomic check-and-update.

### Leaderboards

Sorted sets are purpose-built for leaderboards:

```
-- Add/update scores
ZADD leaderboard 1500 "player:alice"
ZADD leaderboard 2200 "player:bob"
ZINCRBY leaderboard 100 "player:alice"     # Alice scores 100 more points

-- Top 10
ZREVRANGE leaderboard 0 9 WITHSCORES

-- Player rank (0-indexed, highest score = rank 0)
ZREVRANK leaderboard "player:alice"

-- Players ranked 50-60
ZREVRANGE leaderboard 49 59 WITHSCORES
```

O(log N) for all operations. No scanning, no sorting - it is always sorted.

### Session Storage

```
-- Store session as hash with TTL
HSET session:abc123 user_id 1000 role admin last_seen 1711670400
EXPIRE session:abc123 1800    # 30-minute session timeout

-- Refresh on activity
EXPIRE session:abc123 1800    # Reset TTL

-- Read session
HGETALL session:abc123

-- Valkey 9.0+: Per-field expiration for sensitive data
HSETEX session:abc123 EX 300 FVS 1 csrf_token "xyz789"    # CSRF token expires in 5 min
```

### Distributed Locks

**Simple lock** (single instance):

```
-- Acquire: SET with NX (only if not exists) and PX (millisecond TTL)
SET lock:resource my_random_value NX PX 30000

-- Release: Only if we still hold the lock (Valkey 9.0+)
DELIFEQ lock:resource my_random_value

-- Release: Pre-9.0 (Lua script)
EVAL "if server.call('get',KEYS[1]) == ARGV[1] then return server.call('del',KEYS[1]) else return 0 end" 1 lock:resource my_random_value
```

**Redlock** (distributed, multi-instance): Acquire locks on N/2+1 independent Valkey instances within a time window. Use this when a single instance failure could violate mutual exclusion.

**Important**: Always use a random value as the lock value. Always set a TTL. Always verify ownership before release.

### Queues

**Simple FIFO queue** with lists:

```
-- Producer
RPUSH queue:tasks '{"type":"email","to":"user@example.com"}'

-- Consumer (blocking pop, 30s timeout)
BLPOP queue:tasks 30
```

**Reliable queue** with streams and consumer groups:

```
-- Create stream and consumer group
XGROUP CREATE queue:tasks workers $ MKSTREAM

-- Producer
XADD queue:tasks * type email to user@example.com

-- Consumer (blocks for new messages)
XREADGROUP GROUP workers consumer1 COUNT 1 BLOCK 5000 STREAMS queue:tasks >

-- Acknowledge after processing
XACK queue:tasks workers 1711670400000-0
```

Streams with consumer groups provide at-least-once delivery, automatic redelivery of unacknowledged messages, and load balancing across consumers.

### Pub/Sub Messaging

```
-- Subscriber (in one connection)
SUBSCRIBE notifications:user:1000

-- Publisher (in another connection)
PUBLISH notifications:user:1000 '{"type":"message","from":"user:2000"}'

-- Pattern subscription (matches any user)
PSUBSCRIBE notifications:user:*

-- Cluster-friendly sharded pub/sub (Valkey 7.0+)
SSUBSCRIBE orders:region:us-east
SPUBLISH orders:region:us-east '{"order_id": 5678}'
```

---

## 5. Valkey-Specific Features

These features are unique to Valkey or diverge significantly from Redis.

### SET IFEQ - Conditional Update (Valkey 8.1+)

Atomically update a value only if the current value matches an expected value. Eliminates the GET-compare-SET round-trip pattern.

```
SET mykey "initial"
SET mykey "updated" IFEQ "initial"    # Returns OK (match)
SET mykey "again" IFEQ "initial"      # Returns nil (no match - value is now "updated")

-- With GET: returns old value regardless of match outcome
SET mykey "new" IFEQ "updated" GET    # Returns "updated", sets to "new"
```

**Use case**: Distributed systems where multiple services update a cached value. Race condition prevention without Lua scripts.

### DELIFEQ - Conditional Delete (Valkey 9.0+)

Atomically delete a key only if its value matches. Replaces the Lua script pattern for safe lock release.

```
SET mylock "owner_abc123"
DELIFEQ mylock "owner_abc123"     # Returns 1 (deleted)
DELIFEQ mylock "wrong_owner"      # Returns 0 (not deleted)
```

### Hash Field Expiration (Valkey 9.0+)

Set TTLs on individual hash fields instead of the entire key. Previously, you had to split data across multiple keys or delete entire hashes.

```
-- Set field with TTL
HSETEX user:1000 EX 3600 FVS 2 auth_token "tok_abc" csrf_token "csrf_xyz"

-- Set TTL on existing fields
HEXPIRE user:1000 300 FIELDS 1 csrf_token

-- Get field and refresh TTL
HGETEX user:1000 EX 3600 FIELDS 1 auth_token

-- Check remaining TTL
HTTL user:1000 FIELDS 1 csrf_token
```

**New commands**: `HEXPIRE`, `HEXPIREAT`, `HEXPIRETIME`, `HGETEX`, `HPERSIST`, `HPEXPIRE`, `HPEXPIREAT`, `HPEXPIRETIME`, `HPTTL`, `HSETEX`, `HTTL`

**Use cases**: Feature flags with per-flag expiration, session data with sensitive field timeouts, link curation with per-link relevance windows.

**Memory overhead**: 16-29 bytes per expiring field. No measurable performance regression on standard hash operations.

### Numbered Databases in Cluster Mode (Valkey 9.0+)

Previously, cluster mode was limited to database 0. Valkey 9.0 adds full support for numbered databases in cluster mode.

```
SELECT 0
SET mykey "db0_value"

SELECT 5
SET mykey "db5_value"    # Different namespace, same key name, same slot
```

**Use cases**: Logical data separation, debugging (compare behavior across databases), atomic key replacement via `MOVE`.

**Limitations**: No resource isolation (noisy neighbor problem), limited ACL controls, and per-node scope for commands like `FLUSHDB` and `SCAN`.

### Atomic Slot Migration (Valkey 9.0+)

Cluster scaling used to migrate keys one at a time, causing redirects and potential errors. Valkey 9.0 migrates entire slots atomically using the AOF format. Once complete, clients redirect instantly to the target node with no downtime.

### Polygon Geospatial Queries (Valkey 9.0+)

`GEOSEARCH` now supports `BYPOLYGON` in addition to `BYRADIUS` and `BYBOX`:

```
GEOADD locations -122.4194 37.7749 "SF"
GEOADD locations -118.2437 34.0522 "LA"

GEOSEARCH locations BYPOLYGON 4 -123 38 -117 38 -117 34 -123 34 ASC WITHCOORD
```

### Performance Improvements Summary

| Version | Feature | Impact |
|---------|---------|--------|
| 8.0 | I/O multithreading overhaul | 3x throughput (360K -> 1.2M RPS) |
| 8.0 | Command batching | Reduced CPU cache misses |
| 8.1 | New hashtable implementation | 20-30 bytes less memory per key |
| 8.1 | Iterator prefetching | 3.5x faster iteration |
| 8.1 | TLS offload to I/O threads | 300% faster TLS connection acceptance |
| 8.1 | ZRANK optimization | 45% faster |
| 8.1 | BITCOUNT (AVX2) | 514% faster |
| 8.1 | PFMERGE/PFCOUNT (AVX) | 12x faster |
| 9.0 | Pipeline memory prefetch | Up to 40% higher throughput |
| 9.0 | Zero-copy responses | Up to 20% higher throughput for large values |
| 9.0 | SIMD BITCOUNT/HLL | Up to 200% higher throughput |
| 9.0 | Multipath TCP | Up to 25% latency reduction |

---

## 6. Migration from Redis

### What Does NOT Change

- **Protocol**: RESP2 and RESP3 are identical
- **Client libraries**: ioredis, Jedis, redis-py, go-redis, Lettuce - all work unchanged
- **Data files**: RDB and AOF files from Redis OSS <= 7.2 load directly
- **Configuration**: Most valkey.conf directives match redis.conf
- **Commands**: All Redis OSS commands through 7.2 are available
- **Lua scripts**: All existing scripts work unchanged

### What Changes

- **Binary name**: `redis-server` -> `valkey-server`, `redis-cli` -> `valkey-cli`
- **Config file**: `redis.conf` -> `valkey.conf` (format is the same)
- **Default config**: `lazyfree-lazy-user-del` defaults to `yes` in Valkey 8.0+ (DEL acts as UNLINK)
- **New features**: SET IFEQ, DELIFEQ, hash field expiration, numbered databases in cluster - only available in Valkey
- **Terminology**: Some legacy terms updated (e.g., replication terminology)

### Migration Strategies

**1. Physical migration (fastest, requires downtime)**:

```bash
# On Redis
redis-cli SAVE                           # Create RDB snapshot
cp /var/lib/redis/dump.rdb /tmp/

# On Valkey
cp /tmp/dump.rdb /var/lib/valkey/
valkey-server /etc/valkey/valkey.conf     # Loads RDB on startup
```

**2. Replication (minimal downtime)**:

```bash
# On Valkey instance
valkey-cli REPLICAOF redis-host 6379     # Sync from Redis
# Wait for sync: check INFO replication -> master_link_status:up
# When ready:
valkey-cli REPLICAOF NO ONE              # Promote to primary
# Redirect application connections to Valkey
```

**3. Cluster migration**:
1. Add Valkey nodes as replicas in existing Redis cluster
2. Promote Valkey replicas via `CLUSTER FAILOVER`
3. Remove old Redis nodes via `CLUSTER FORGET`
4. Add Valkey replicas for redundancy

### Incompatible Versions

Redis Community Edition 7.4+ (post-license-change) uses proprietary code and incompatible RDB formats. Migration from these versions requires third-party tools like RIOT or RedisShake, not direct file copy or replication.

---

## 7. Client Libraries

### Valkey GLIDE (Official, Recommended)

Built in Rust with language bindings. Single multiplexed connection per node with auto-pipelining.

| Language | Package | Status |
|----------|---------|--------|
| Java | `valkey-glide` | GA |
| Python | `valkey-glide` | GA |
| Node.js | `@valkey/valkey-glide` | GA |
| Go | `github.com/valkey-io/valkey-glide/go` | GA |
| C# | `valkey-glide-csharp` | Preview |
| PHP | `valkey-glide-php` | Preview |

### Existing Redis Clients (Compatible)

| Language | Client | Notes |
|----------|--------|-------|
| Node.js | ioredis | Works unchanged, widely used |
| Python | redis-py / valkey-py | valkey-py is the fork with Valkey-specific features |
| Java | Jedis, Lettuce, Redisson | All compatible |
| Go | go-redis, rueidis | All compatible |
| .NET | StackExchange.Redis | Compatible |

### When to Choose GLIDE vs Existing Clients

- **New projects**: Use GLIDE for best performance and Valkey-specific features
- **Existing projects**: Keep current client - it works. Migrate to GLIDE when convenient
- **Need Valkey 8.1+/9.0 features**: GLIDE has first-class support for new commands

---

## 8. Monitoring and Debugging

### Key Commands

```bash
# Server info (memory, clients, stats, replication, keyspace)
INFO [section]

# Slow query log
SLOWLOG GET 10                    # Last 10 slow queries
CONFIG SET slowlog-log-slower-than 10000    # Log queries > 10ms

# Latency monitoring
CONFIG SET latency-monitor-threshold 5      # Track events > 5ms
LATENCY LATEST                              # Recent latency events
LATENCY DOCTOR                              # Human-readable diagnosis

# Memory analysis
MEMORY USAGE key                  # Memory used by a specific key
MEMORY DOCTOR                     # Memory health report
DEBUG OBJECT key                  # Encoding details for a key

# Client connections
CLIENT LIST                       # All connected clients
CLIENT INFO                       # Current connection info
```

### CLI Diagnostic Tools

```bash
valkey-cli --bigkeys              # Find keys with many elements
valkey-cli --memkeys              # Find keys consuming most memory
valkey-cli --hotkeys              # Find most-accessed keys
valkey-cli --latency              # Continuous latency measurement
valkey-cli --stat                 # Real-time stats (ops/sec, memory, clients)
```

### COMMANDLOG (Valkey 8.1+)

Extends SLOWLOG to also track large requests and replies, providing end-to-end latency visibility.

---

## 9. Security Essentials

### Authentication

```
# In valkey.conf: set password for default user
requirepass your_strong_password

# Or use ACLs for fine-grained control
ACL SETUSER appuser on >password ~app:* +@read +@write -@admin

# Client connection
AUTH username password
```

### ACL Best Practices

- Create dedicated users per application with minimum required permissions
- Restrict key patterns: `~cache:*` limits the user to keys prefixed with `cache:`
- Restrict commands: `+@read` allows read commands only
- Disable dangerous commands for non-admin users: `-@admin -FLUSHDB -FLUSHALL -KEYS -DEBUG`

### TLS

```
# In valkey.conf
tls-port 6380
tls-cert-file /path/to/valkey.crt
tls-key-file /path/to/valkey.key
tls-ca-cert-file /path/to/ca.crt
```

Valkey 8.1+ offloads TLS negotiation to I/O threads, so TLS overhead is minimal on multi-threaded deployments.

### Network Security

- Bind to specific interfaces: `bind 127.0.0.1 10.0.0.1`
- Never expose Valkey directly to the internet
- Use `protected-mode yes` (default) to reject non-localhost connections when no password is set
- Rename or disable dangerous commands: `rename-command FLUSHALL ""`

---

## 10. Quick Reference: Anti-Patterns

| Anti-Pattern | Problem | Do Instead |
|-------------|---------|------------|
| `KEYS *` in production | Blocks server for seconds | `SCAN` with cursor |
| `DEL` on big keys | Main thread freeze | `UNLINK` (non-blocking) |
| `HGETALL` on huge hashes | Latency spike + bandwidth | `HSCAN` or `HMGET` specific fields |
| `SMEMBERS` on huge sets | Same as above | `SSCAN` with cursor |
| No `maxmemory` set | OOM kill by OS | Set to ~75% of available RAM |
| No authentication | Anyone can read/write | Set `requirepass` or use ACLs |
| One connection per request | Connection overhead, exhaustion | Connection pool or GLIDE multiplexing |
| `FLUSHALL` accessible | Accidental data wipe | Rename or disable the command |
| Short cryptic key names | Minimal space savings, poor operability | Use `user:1000:profile` style |
| Single hot key for counters | Shard bottleneck | Shard: `counter:{0}`, `counter:{1}`, ... |
| Storing huge values (>1MB) | Network + memory pressure | Compress or store in object storage |
| Multiple numbered databases in production | Confusing, no isolation | Use separate instances or cluster namespacing |
