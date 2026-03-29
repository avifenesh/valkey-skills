# Valkey Usage Patterns, Best Practices, and Application Development

> Research compiled from Valkey official documentation, valkey-io/valkey-doc, Valkey GLIDE client docs, ioredis docs, and redis-py docs. Covers Valkey 8.x and 9.x features.

---

## 1. Valkey Data Types and Their Use Cases

Valkey provides 11 native data types. Each has specific performance characteristics and ideal use cases.

| Data Type | Complexity (typical) | Use Cases |
|-----------|---------------------|-----------|
| Strings | O(1) get/set | Caching, counters, flags, serialized objects |
| Lists | O(1) push/pop, O(N) index | Task queues, activity feeds, bounded logs |
| Sets | O(1) add/remove/check | Tags, unique visitors, set operations |
| Hashes | O(1) per field | Objects, user profiles, session data |
| Sorted Sets | O(log N) add/remove | Leaderboards, rate limiters, priority queues |
| Streams | O(1) add, O(N) range | Event sourcing, message queues, audit logs |
| Geospatial | O(log N) | Location-based queries, proximity search |
| Bitmaps | O(1) per bit | Feature flags, online status, analytics |
| Bitfields | O(1) per field | Compact counters, packed integers |
| HyperLogLog | O(1) add/count | Unique visitor counting (probabilistic) |
| Bloom Filter | O(k) | Membership testing (via valkey-bloom module) |

### Memory-Efficient Encoding

Small aggregate types use compact encoding (listpack) that uses up to 10x less memory. Defaults:

```
hash-max-listpack-entries 512
hash-max-listpack-value 64
zset-max-listpack-entries 128
zset-max-listpack-value 64
set-max-intset-entries 512
set-max-listpack-entries 128
set-max-listpack-value 64
```

**Gotcha**: Once a collection exceeds these thresholds, it converts to a full hash table and the memory savings are lost permanently for that key. Conversion is fast for small values but should be benchmarked for larger ones.

### Hash-Based Key-Value Optimization

Use hashes to model a memory-efficient plain key-value store. Instead of `object:1234` as a standalone key, split into:
- Key: `object:12`
- Field: `34`

```
HSET object:12 34 somevalue
```

Each hash ends up with ~100 fields, which stays within listpack encoding. This approach uses significantly less memory than individual string keys - often 5-10x less.

---

## 2. Valkey-Specific Commands (Not in Redis)

Valkey 9.0 introduced several commands that do not exist in Redis.

### SET IFEQ (Conditional Set)

Sets a key only if its current value matches a comparison value. Atomic compare-and-swap without Lua scripts.

```
SET foo "Initial Value"
OK

SET foo "New Value" IFEQ "Initial Value"
OK

GET foo
"New Value"

# Fails if value doesn't match
SET foo "Another" IFEQ "Wrong Value"
(nil)
```

**Use case**: Optimistic locking, state machines, safe value updates without Lua.

**Edge case**: Returns an error if the value stored at the key is not a string.

### DELIFEQ (Conditional Delete)

Deletes a key only if its value matches the given string. Atomic check-and-delete.

```
SET mykey abc123
OK

DELIFEQ mykey abc123
(integer) 1

DELIFEQ mykey abc123
(integer) 0
```

**Use case**: Safe distributed lock release without Lua scripts.

Replaces the traditional Lua pattern:

```lua
-- Old way (Lua script required)
if redis.call('GET', KEYS[1]) == ARGV[1] then
    return redis.call('DEL', KEYS[1])
else
    return 0
end
```

```
-- New way (single command, Valkey 9.0+)
DELIFEQ resource_name my_random_value
```

**Edge case**: Returns WRONGTYPE error if key holds a non-string value (e.g., a set).

### Hash Field Expiration (Valkey 9.0)

Per-field TTL on hash keys - a major feature not available in Redis.

#### HEXPIRE / HPEXPIRE

Set expiration time on specific hash fields:

```
HSET myhash f1 v1 f2 v2 f3 v3
(integer) 3

HEXPIRE myhash 10 FIELDS 2 f2 f3
1) (integer) 1
2) (integer) 1

HTTL myhash FIELDS 3 f1 f2 f3
1) (integer) -1    # f1: no expiration
2) (integer) 8     # f2: 8 seconds remaining
3) (integer) 8     # f3: 8 seconds remaining
```

Options: NX (only if no expiry), XX (only if existing expiry), GT (only if new > current), LT (only if new < current).

#### HSETEX (Set + Expire in one command)

```
# Set fields with 10-second expiration
HSETEX myhash FXX EX 10 FIELDS 2 f2 v2 f3 v3
(integer) 1

# FNX: only set if fields don't exist
HSETEX myhash FNX EX 10 FIELDS 2 f2 v2 f3 v3
(integer) 0

# KEEPTTL: update values without changing expiration
HSETEX myhash FXX KEEPTTL FIELDS 2 f2 new_v2 f3 new_v3
(integer) 1
```

#### HGETEX (Get + Expire in one command)

```
HGETEX myhash EX 10 FIELDS 2 f2 f3
1) "v2"
2) "v3"

# Also supports PERSIST to remove expiration on read
HGETEX myhash PERSIST FIELDS 2 f2 f3
```

#### Gotchas for Hash Field Expiration

1. **HSET/HMSET remove field expiration** - Overwriting a field with HSET strips its TTL. Use HSETEX with KEEPTTL to preserve it.
2. **Expired fields still consume memory** briefly - Deletion happens via periodic job, not instantly.
3. **HLEN may count expired fields** - Between logical expiry and physical deletion.
4. **HRANDFIELD on mostly-expired hashes** - May return empty results because it can't find non-expired fields.
5. **Setting EX 0 or past EXAT** - Immediately deletes the fields.

### GETDEL

Get and atomically delete a key:

```
SET mykey "Hello"
OK
GETDEL mykey
"Hello"
GET mykey
(nil)
```

**Use case**: One-time tokens, claim-and-consume patterns.

---

## 3. Distributed Lock Patterns

### Single-Instance Lock (Simple)

```
# Acquire: NX ensures only one holder, PX sets auto-release
SET resource_name <random_value> NX PX 30000

# Release (Valkey 9.0+):
DELIFEQ resource_name <random_value>

# Release (pre-9.0, Lua):
EVAL "if server.call('get',KEYS[1]) == ARGV[1] then return server.call('del',KEYS[1]) else return 0 end" 1 resource_name <random_value>
```

**Random value requirements**: 20 bytes from /dev/urandom recommended. Simpler alternative: UNIX timestamp with microsecond precision + client ID.

**Lock validity time** = auto-release TTL = time window for the client to complete its work.

### Redlock Algorithm (Multi-Instance)

For environments where a single point of failure is unacceptable.

**Setup**: N=5 independent Valkey primaries (no replication between them).

**Algorithm**:

1. Get current time in milliseconds (T1)
2. Try to acquire lock in all N instances sequentially, using same key name and random value
3. Use small per-instance timeout (5-50ms for 10s TTL) to avoid blocking on failed nodes
4. Lock acquired if: majority (N/2+1) instances locked AND total time < lock validity time
5. Effective validity = initial TTL - (T2 - T1)
6. On failure: unlock ALL instances (even those believed to have failed)

**Safety properties**:
- Mutual exclusion: Only one client holds lock at any time
- Deadlock-free: Keys expire even if holder crashes
- Fault-tolerant: Works as long as majority of nodes are up

**Retry strategy**: Random delay on failure to desynchronize competing clients. Use multiplexing to contact all N instances simultaneously.

#### Why Failover-Based Replication Is Unsafe

```
1. Client A acquires lock on primary
2. Primary crashes before replicating write
3. Replica promoted to primary
4. Client B acquires same lock -> SAFETY VIOLATION
```

This is why Redlock uses N independent primaries instead of replicated instances.

#### Crash Recovery Considerations

- **Without persistence**: Restarted node may allow duplicate lock acquisition. Mitigate by keeping crashed nodes unavailable for max-TTL duration.
- **With AOF (fsync always)**: Safe but impacts performance.
- **With AOF (fsync every second)**: May lose last second of data after power outage.
- **Delayed restart**: Safest without persistence - keep node down for at least max-TTL after crash.

#### Lock Extension

For long-running operations, extend lock by sending Lua script to all instances that extends TTL if key exists with correct random value. Only consider extended if majority succeeded within validity time. Limit reacquisition attempts to preserve liveness.

#### Fencing Tokens

For strong consistency, implement fencing tokens. The lock alone does not guarantee a process still holds it when performing work. Combine with monotonically increasing token checked by the resource being protected.

**Reference**: Martin Kleppmann's analysis and antirez's counterpoint are essential reading for production distributed lock implementations.

#### Implementation Libraries

| Language | Library | Notes |
|----------|---------|-------|
| Node.js | node-redlock | Lock extension support |
| Node.js | redlock-universal | node-redis, ioredis, Valkey GLIDE support |
| Python | Redlock-py | Standard implementation |
| Python | Pottery | Alternative implementation |
| Python | Aioredlock | Asyncio support |
| Go | Redsync | Standard Go implementation |
| Java | Redisson | Feature-rich Java implementation |
| Rust | Rslock | Async + lock extension |
| C# | RedLock.net | Async + lock extension |
| Ruby | Redlock-rb | Reference implementation |

---

## 4. Rate Limiting Implementations

### Pattern 1: Fixed Window Counter

```python
# Lua script for atomic rate limiting (Valkey GLIDE)
rate_limit_script = Script("""
    local key = KEYS[1]
    local limit = tonumber(ARGV[1])
    local window = tonumber(ARGV[2])

    local current = redis.call('GET', key)
    if current == false then
        redis.call('SET', key, 1)
        redis.call('EXPIRE', key, window)
        return {1, limit}
    end

    current = tonumber(current)
    if current < limit then
        local new_val = redis.call('INCR', key)
        local ttl = redis.call('TTL', key)
        return {new_val, limit}
    else
        local ttl = redis.call('TTL', key)
        return {current, limit, ttl}
    end
""")

result = await client.invoke_script(
    rate_limit_script,
    keys=["rate_limit:user:123"],
    args=["10", "60"]  # 10 requests per 60 seconds
)
```

**Gotcha**: Fixed window has a burst problem at window boundaries - a user could make 10 requests at second 59 and 10 more at second 61, effectively 20 requests in 2 seconds.

### Pattern 2: Sliding Window with Sorted Set

```
# Node.js / ioredis
const pipeline = redis.pipeline();
const now = Date.now();
const windowMs = 60000; // 1 minute

pipeline.zremrangebyscore(key, 0, now - windowMs);  // Remove old entries
pipeline.zadd(key, now, `${now}-${uuid}`);           // Add current request
pipeline.zcard(key);                                  // Count requests in window
pipeline.expire(key, Math.ceil(windowMs / 1000));    // Auto-cleanup

const results = await pipeline.exec();
const requestCount = results[2][1];
const allowed = requestCount <= limit;
```

More accurate than fixed window but uses more memory (one sorted set member per request).

### Pattern 3: Token Bucket with Lua

```lua
-- Token bucket rate limiter
local key = KEYS[1]
local rate = tonumber(ARGV[1])      -- tokens per second
local capacity = tonumber(ARGV[2])  -- max burst
local now = tonumber(ARGV[3])       -- current timestamp
local requested = tonumber(ARGV[4]) -- tokens requested (usually 1)

local data = redis.call('HMGET', key, 'tokens', 'last_time')
local tokens = tonumber(data[1]) or capacity
local last_time = tonumber(data[2]) or now

-- Add tokens based on elapsed time
local elapsed = math.max(0, now - last_time)
tokens = math.min(capacity, tokens + elapsed * rate)

local allowed = 0
if tokens >= requested then
    tokens = tokens - requested
    allowed = 1
end

redis.call('HMSET', key, 'tokens', tokens, 'last_time', now)
redis.call('EXPIRE', key, math.ceil(capacity / rate) * 2)

return {allowed, tokens}
```

### Pattern 4: Per-Field Rate Limiting with Hash Field Expiration (Valkey 9.0)

```
# Track per-endpoint rate limits in a single hash with auto-expiring fields
HSETEX rate:user:123 EX 60 FIELDS 1 /api/orders 1
HINCRBY rate:user:123 /api/orders 1

# Check if field still exists (not expired = within window)
HGET rate:user:123 /api/orders
```

**Advantage**: All rate limit data for a user in one key. Fields auto-expire independently.

---

## 5. Client-Side Caching

### How It Works

Client-side caching stores frequently accessed data in application memory, reducing network round trips to Valkey. Valkey implements server-assisted invalidation via the Tracking feature.

```
+-------------+                                +----------+
|             |                                |          |
| Application |       ( No network needed )    |  Valkey  |
|             |                                |          |
+-------------+                                +----------+
| Local cache |
| user:1234 = |
| "Alice"     |
+-------------+
```

### Performance Impact

- Local memory access: nanoseconds
- Network round-trip to Valkey: microseconds to milliseconds
- For hot keys accessed frequently, client-side caching can reduce latency by 100-1000x

### Two Tracking Modes

#### Default Mode (server remembers)

Server tracks which keys each client accessed. Sends invalidation only for keys the client may have cached.

```
Client 1 -> Server: CLIENT TRACKING ON
Client 1 -> Server: GET foo
(Server remembers Client 1 may have "foo" cached)

Client 2 -> Server: SET foo SomeOtherValue
Server -> Client 1: INVALIDATE "foo"
```

**Tradeoff**: Uses memory on the server to track client keys. Server uses an Invalidation Table with configurable max size. When full, evicts entries and sends invalidation even if data hasn't changed.

#### Broadcasting Mode (prefix-based)

No server-side memory cost. Clients subscribe to key prefixes.

```
CLIENT TRACKING ON BCAST PREFIX user: PREFIX session:
```

Receives invalidation for every key matching subscribed prefixes, regardless of whether the client cached it.

**Tradeoff**: May receive many unnecessary invalidation messages for keys the client never cached.

### Opt-In Mode

For clients that want fine-grained control:

```
CLIENT TRACKING ON REDIRECT 1234 OPTIN

# Only track the next command
CLIENT CACHING YES
GET foo
```

### Two-Connection Mode (RESP2 compatible)

```
# Connection 1: Invalidation channel
CLIENT ID
:4
SUBSCRIBE __redis__:invalidate

# Connection 2: Data
CLIENT TRACKING ON REDIRECT 4
GET foo
```

### Implementation Considerations

1. **What to cache**: Default mode tracks all read commands automatically. OPTIN mode requires explicit CLIENT CACHING YES before each cacheable read.
2. **Cache eviction**: Use LRU or LFU locally. Cache a fixed number of objects, discard oldest on overflow.
3. **Cross-database invalidation**: Tracking uses a single key namespace - invalidation fires even if the write was on a different database number.
4. **FLUSH commands**: Send a null invalidation message to clear all cached data.

---

## 6. Stream-Based Event Processing

### Basic Stream Operations

```
# Add entries to stream
XADD race:france * rider Castilla speed 30.2 position 1 location_id 1
"1692632086370-0"

# Read entries
XRANGE race:france - +
XRANGE race:france - + COUNT 2

# Paginated iteration (use exclusive range with '(' prefix)
XRANGE race:france (1692632094485-0 + COUNT 2

# Reverse read (latest first)
XREVRANGE race:france + - COUNT 1

# Blocking read for new entries
XREAD BLOCK 0 STREAMS race:france $

# Read from multiple streams
XREAD COUNT 100 BLOCK 5000 STREAMS stream1 stream2 0 0
```

### Entry IDs

Format: `<millisecondsTime>-<sequenceNumber>`

- Monotonically increasing even with clock skew
- 64-bit sequence number - unlimited entries per millisecond
- Enables time-range queries for free

### Consumer Groups

For workload distribution across multiple consumers (similar to Kafka consumer groups):

```
# Create consumer group ($ = only new messages, 0 = all history)
XGROUP CREATE race:italy italy_riders $ MKSTREAM

# Read as consumer in group
XREADGROUP GROUP italy_riders Alice COUNT 1 STREAMS race:italy >
XREADGROUP GROUP italy_riders Bob COUNT 1 STREAMS race:italy >

# Acknowledge processed message
XACK race:italy italy_riders 1692632639151-0
```

**Key properties**:
- Each message delivered to exactly one consumer in the group
- Consumers identified by name (case-sensitive string)
- Pending Entry List (PEL) tracks unacknowledged messages
- Multiple consumer groups can read the same stream independently
- Non-group XREAD can coexist with XREADGROUP on the same stream

### Node.js Stream Example (ioredis)

```javascript
const Redis = require("ioredis");
const redis = new Redis();
const sub = new Redis();

// Producer
await redis.xadd("user-stream", "*", "name", "John", "age", "20");

// Consumer with blocking read
async function listenForMessage(lastId = "$") {
  const results = await sub.xread(
    "BLOCK", 0, "STREAMS", "user-stream", lastId
  );
  const [key, messages] = results[0];

  messages.forEach(msg => {
    console.log("Id:", msg[0], "Data:", msg[1]);
  });

  // Continue from last received ID
  await listenForMessage(messages[messages.length - 1][0]);
}

listenForMessage();
```

### Stream Trimming Strategies

```
# Cap stream to approximately 1000 entries (efficient)
XADD mystream MAXLEN ~ 1000 * field value

# Cap by minimum entry ID
XADD mystream MINID ~ 1692632086370-0 * field value
```

The `~` makes trimming approximate (more efficient, may keep slightly more entries).

### Performance

- XADD: O(1) for adding entries
- XRANGE/XREAD: O(log N) seek + O(M) for M returned entries
- Streams are implemented as radix trees - highly efficient for ordered access
- No XSCAN needed - XRANGE serves as the stream iterator

### Gotchas

1. **Consumer group lag**: If consumers don't acknowledge, the PEL grows unbounded. Monitor with XPENDING.
2. **Stream memory**: Streams are append-only. Without trimming (MAXLEN/MINID), they grow forever.
3. **BLOCK 0 on XREAD**: Blocks indefinitely. Always use a timeout in production.
4. **$ ID on XREAD**: Only gets messages arriving AFTER the call. Use specific ID to not miss messages between calls.
5. **Consumer name persistence**: If consumer disconnects and reconnects with same name, it resumes its pending messages.

---

## 7. Session Storage with Per-Field TTL

Valkey 9.0's hash field expiration enables a powerful session storage pattern.

### Traditional Pattern (Pre-9.0)

```
# Entire session expires at once
HSET session:abc123 user_id 42 email "alice@example.com" cart_data "{...}"
EXPIRE session:abc123 3600  # 1 hour
```

**Problem**: All fields share the same TTL. Can't expire cart data after 15 minutes while keeping the session alive for 1 hour.

### Per-Field TTL Pattern (Valkey 9.0)

```
# Create session with different TTLs per field
HSETEX session:abc123 EX 3600 FIELDS 2 user_id 42 email "alice@example.com"
HSETEX session:abc123 EX 900 FIELDS 1 cart_data "{...}"
HSETEX session:abc123 EX 300 FIELDS 1 csrf_token "xyz789"

# Check remaining TTL per field
HTTL session:abc123 FIELDS 3 user_id cart_data csrf_token
1) (integer) 3595   # user_id: ~1 hour
2) (integer) 895    # cart_data: ~15 minutes
3) (integer) 295    # csrf_token: ~5 minutes
```

### Access-Based Expiration (Sliding Window)

```
# Read fields and reset their expiration in one atomic command
HGETEX session:abc123 EX 3600 FIELDS 2 user_id email
1) "42"
2) "alice@example.com"
# Both fields now have a fresh 1-hour TTL
```

### Session Data with Mixed Volatility

| Field | TTL | Rationale |
|-------|-----|-----------|
| user_id, email | Session lifetime (1h) | Core identity data |
| csrf_token | 5 minutes | Security, short-lived |
| cart_data | 15 minutes | Stale quickly, expensive to maintain |
| last_activity | No expiry (PERSIST) | Analytics, updated on each access |
| oauth_token | Matches token expiry | Auto-cleanup with token |

### Gotchas

1. **HSET strips TTL**: Plain HSET on a field with TTL removes the expiration. Always use HSETEX with KEEPTTL when updating volatile fields.
2. **Field-level EXPIRE is not key-level EXPIRE**: The key itself doesn't have an expiration set by HEXPIRE. Set a key-level EXPIRE as a safety net.
3. **Memory between expiry and deletion**: Expired fields are cleaned up by periodic job, not instantly.

---

## 8. Cache Invalidation Strategies

### Strategy 1: TTL-Based (Time-Bounded Staleness)

```
SET user:1234 "{...}" EX 300  # 5-minute cache
```

Simple, no invalidation logic needed. Acceptable when slight staleness is OK.

### Strategy 2: Event-Driven Invalidation

```
# On data change, delete the cache key
DEL user:1234

# Or update it (write-through)
SET user:1234 "{...}" EX 300
```

### Strategy 3: Server-Assisted Client-Side Caching

Use Valkey Tracking (see Section 5) for automatic invalidation notifications.

### Strategy 4: Pub/Sub Invalidation

```
# Publisher (on data change)
PUBLISH cache:invalidate "user:1234"

# Subscriber (cache layer)
SUBSCRIBE cache:invalidate
# On message: evict from local cache
```

**Downside**: Every client receives every invalidation message, even for keys they don't cache. Valkey Tracking is more efficient.

### Strategy 5: Conditional Update with IFEQ (Valkey 9.0)

```
# Only update cache if value hasn't changed (optimistic caching)
SET user:1234 "{new_data}" IFEQ "{old_data}"
```

Prevents overwriting a fresher cache value with stale data.

### Eviction Policies

When using Valkey as a cache with `maxmemory` configured:

| Policy | Description | Best For |
|--------|-------------|----------|
| allkeys-lru | Evict least recently used | Power-law access (default choice) |
| allkeys-lfu | Evict least frequently used | Stable hot set |
| volatile-lru | LRU among keys with TTL | Mixed cache + persistent data |
| volatile-lfu | LFU among keys with TTL | Mixed cache + persistent data |
| volatile-ttl | Evict shortest remaining TTL | Hint-based expiration priority |
| allkeys-random | Random eviction | Uniform access patterns |
| noeviction | Return errors on memory limit | When data loss is unacceptable |

**Tuning LRU/LFU**:

```
# LRU sample size (default 5, increase for accuracy at CPU cost)
maxmemory-samples 10

# LFU tuning
lfu-log-factor 10    # How many hits to saturate counter
lfu-decay-time 1     # Minutes between counter decay
```

LFU factor impact:

| Factor | 100 hits | 1K hits | 100K hits | 1M hits |
|--------|----------|---------|-----------|---------|
| 0 | 104 | 255 | 255 | 255 |
| 1 | 18 | 49 | 255 | 255 |
| 10 | 10 | 18 | 142 | 255 |
| 100 | 8 | 11 | 49 | 143 |

**Gotcha**: `allkeys-lru` is more memory-efficient than `volatile-lru` because keys don't need TTLs to be evicted. Setting TTLs consumes memory for the expiry metadata.

---

## 9. Pipeline Batching and Performance

### How Pipelining Works

Without pipelining, each command requires a full network round trip:

```
Client: INCR X  ->  Server: 1
Client: INCR X  ->  Server: 2
Client: INCR X  ->  Server: 3
```

With pipelining, commands are sent in batch:

```
Client: INCR X
Client: INCR X
Client: INCR X
Server: 1
Server: 2
Server: 3
```

### Performance Benchmarks

**Ruby benchmark** (loopback interface, 10,000 PINGs):

```
without pipelining: 1.185238 seconds
with pipelining:    0.250783 seconds
```

**5x improvement on loopback** (where RTT is already sub-millisecond). Over a network with real latency, improvements are even more dramatic.

**Scaling**: Throughput increases almost linearly with pipeline depth, eventually reaching **10x the non-pipelined baseline** before plateauing.

### Why It's Not Just RTT

Pipelining reduces system call overhead:
- Without pipelining: one `read()` + one `write()` syscall per command
- With pipelining: one `read()` + one `write()` for many commands
- The user-to-kernel context switch is a significant penalty

### Node.js (ioredis) Pipeline Examples

```javascript
// Manual pipeline
const pipeline = redis.pipeline();
pipeline.set("foo", "bar");
pipeline.get("foo");
pipeline.incr("counter");
const results = await pipeline.exec();
// results: [[null, 'OK'], [null, 'bar'], [null, 1]]

// Array constructor form
redis.pipeline([
  ["set", "foo", "bar"],
  ["get", "foo"],
]).exec();

// Auto-pipelining (groups commands from same event loop tick)
const redis = new Redis({ enableAutoPipelining: true });
// Concurrent requests automatically batched
```

### Valkey GLIDE Pipeline Examples

**Python**:
```python
pipeline = Batch(is_atomic=False)
pipeline.set("key1", "value1")
pipeline.set("key2", "value2")
pipeline.get("key1")
pipeline.get("key2")

result = await client.exec(pipeline, raise_on_error=False)
# Returns: [OK, OK, b'value1', b'value2']
```

**Node.js (GLIDE)**:
```typescript
import { Batch } from "@valkey/valkey-glide";

// Non-atomic pipeline
const pipeline = new Batch(false);
pipeline
    .set("key1", "value1")
    .set("key2", "value2")
    .get("key1")
    .get("key2");

const results = await client.exec(pipeline, false);
// Returns: ['OK', 'OK', 'value1', 'value2']
```

**Java (GLIDE)**:
```java
import glide.api.models.Batch;

Batch pipeline = new Batch(false);
pipeline
    .set("key1", "value1")
    .set("key2", "value2")
    .get("key1")
    .get("key2");

Object[] results = client.exec(pipeline, false).get();
// Returns: ["OK", "OK", "value1", "value2"]
```

**Go (GLIDE)**:
```go
import "github.com/valkey-io/valkey-glide/go/v2/pipeline"

pipe := pipeline.NewStandaloneBatch(false)
pipe.Set("key1", "value1").
    Set("key2", "value2").
    Get("key1").
    Get("key2")

result, err := client.Exec(context.Background(), *pipe, true)
// Returns: [OK OK value1 value2]
```

### Pipeline vs Transaction (Atomic Batch)

| Feature | Pipeline (non-atomic) | Transaction (atomic) |
|---------|-----------------------|---------------------|
| Atomicity | No - commands execute independently | Yes - all or nothing |
| Failure handling | One command can fail without affecting others | All fail on error |
| Use case | Batch reads/writes for performance | Operations that must be atomic |
| GLIDE API | `Batch(false)` / `Batch(is_atomic=False)` | `Batch(true)` / `Batch(is_atomic=True)` |

### Batching Best Practices

1. **Optimal batch size**: ~10,000 commands per pipeline. Read replies, then send next batch. Speed is nearly the same as unbounded pipelines, but memory usage is controlled.
2. **Memory warning**: Server queues all replies until the pipeline completes. Giant pipelines (millions of commands) can cause memory pressure.
3. **Don't pipeline everything**: If command B depends on command A's result, you can't pipeline them. Use Lua scripts instead.
4. **Auto-pipelining** (ioredis): `enableAutoPipelining: true` automatically batches commands issued in the same event loop iteration. Good for HTTP servers where many concurrent requests each issue a few commands.

### Pipelining vs Lua Scripting

| Pipelining | Lua Scripting |
|------------|---------------|
| Client sends batch, reads batch | Server executes all logic locally |
| Cannot use results of previous commands | Can read-compute-write atomically |
| Network RTT reduction | Minimal latency for multi-step logic |
| No server-side blocking | Blocks server during execution |

---

## 10. Persistence Strategies

### RDB (Point-in-Time Snapshots)

```
# Save every 60 seconds if at least 1000 keys changed
save 60 1000

# Disable RDB
save ""
```

- Compact single-file backups
- Faster restart than AOF
- May lose minutes of data on crash
- fork() can cause latency spikes on large datasets

### AOF (Append-Only File)

```
appendonly yes
appendfsync everysec  # Recommended balance of durability and performance
```

Durability options:
- `always`: fsync every command batch - very durable, slow
- `everysec`: fsync every second - good balance (default)
- `no`: OS-controlled - fastest, least durable

### Recommendation

Use both RDB + AOF for production. RDB for fast restarts and backups, AOF for durability.

For pure caching, persistence can be disabled entirely.

---

## 11. High Availability Patterns

### Sentinel

- Provides automatic failover, monitoring, and service discovery
- Minimum 3 Sentinel instances on independent machines
- Clients connect to Sentinel to discover current primary

**Critical considerations**:
- Replication is asynchronous - acknowledged writes may be lost on failover
- Docker port remapping breaks auto-discovery
- Test failover in development environments

### Cluster Mode

- Automatic sharding across multiple nodes
- 16,384 hash slots distributed across primaries
- Built-in replication and failover
- Multi-key commands only work within same hash slot (use `{hash_tag}`)

---

## 12. Memory and Performance Gotchas

### Key Expiration

- Expired keys are removed by both a lazy mechanism (on access) and a periodic active expiry cycle
- The active cycle samples keys - heavily loaded servers with many expiring keys may have memory pressure
- For Redlock, Valkey does NOT use monotonic clock for TTL expiration. Wall-clock shifts can affect lock safety.

### Memory Allocation

- Valkey does not always return freed memory to OS immediately. RSS may stay high after large deletes.
- Provision for peak memory usage, not average.
- Use `maxmemory` to cap usage. Without it, Valkey will consume all available memory.
- With replication, set maxmemory lower to account for replication buffers (not counted toward eviction).

### Connection Handling

- Each client connection has an output buffer. Many idle connections waste memory.
- Use connection pooling in applications.
- Monitor with `CLIENT LIST` and `INFO clients`.

### Large Keys

- HGETALL, SMEMBERS, LRANGE on large collections block the server.
- Use HSCAN, SSCAN, LPOS, or pagination with COUNT.
- Single large values (>10KB) can cause network saturation with many clients.

---

## Sources

| Source | URL | Content |
|--------|-----|---------|
| Valkey Official Docs | https://valkey.io/docs/ | Core documentation |
| Valkey Commands | https://valkey.io/commands/ | Full command reference |
| Valkey Data Types | https://valkey.io/topics/data-types/ | Type overview and use cases |
| Valkey Distributed Locks | https://valkey.io/topics/distlock/ | Redlock algorithm |
| Valkey Streams | https://valkey.io/topics/streams-intro/ | Stream data structure |
| Valkey Client-Side Caching | https://valkey.io/topics/client-side-caching/ | Tracking and invalidation |
| Valkey Pipelining | https://valkey.io/topics/pipelining/ | Batching and performance |
| Valkey Key Eviction | https://valkey.io/topics/lru-cache/ | LRU/LFU eviction policies |
| Valkey Memory Optimization | valkey-io/valkey-doc topics/memory-optimization.md | Memory efficiency patterns |
| Valkey Persistence | valkey-io/valkey-doc topics/persistence.md | RDB and AOF strategies |
| Valkey Sentinel | https://valkey.io/topics/sentinel/ | High availability |
| SET command | valkey-io/valkey-doc commands/set.md | IFEQ, IFGT options |
| DELIFEQ command | valkey-io/valkey-doc commands/delifeq.md | Conditional delete |
| HEXPIRE command | valkey-io/valkey-doc commands/hexpire.md | Hash field expiration |
| HSETEX command | valkey-io/valkey-doc commands/hsetex.md | Set + expire hash fields |
| HGETEX command | valkey-io/valkey-doc commands/hgetex.md | Get + expire hash fields |
| Hash Field Expiration | valkey-io/valkey-doc topics/hashes.md | Per-field TTL patterns |
| Valkey GLIDE Docs | valkey-io/valkey-glide | Official multi-language client |
| ioredis Docs | redis/ioredis | Node.js client patterns |
| Martin Kleppmann | https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html | Redlock analysis |
| antirez Response | http://antirez.com/news/101 | Redlock defense |
