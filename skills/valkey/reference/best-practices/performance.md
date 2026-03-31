# Performance Best Practices

Use when optimizing Valkey throughput, reducing latency, or reviewing application-level performance patterns before production deployment.

---

## UNLINK vs DEL

`DEL` is synchronous by default - it frees memory on the main thread. For large keys (hashes with millions of fields, sorted sets with millions of members), this blocks all other clients for hundreds of milliseconds.

`UNLINK` removes the key reference in O(1) on the main thread and queues memory reclamation to a background thread.

```
# Always prefer UNLINK for large or unknown-size keys
UNLINK mykey

# DEL is fine for small keys, but UNLINK is never worse
DEL small_counter
```

**Valkey 8.0+ default behavior**: The config `lazyfree-lazy-user-del` defaults to `yes`, making `DEL` behave identically to `UNLINK`. However, explicitly using `UNLINK` is still recommended because:

1. It communicates intent clearly in your code
2. It protects against config changes - if someone sets `lazyfree-lazy-user-del no`, `UNLINK` calls remain non-blocking while `DEL` calls become blocking

**When DEL is acceptable**: Small keys (strings, hashes with a few fields). The overhead difference is negligible for keys under a few hundred elements.

### Code Examples

**Node.js (ioredis)**:
```javascript
// Prefer UNLINK for cleanup operations
await redis.unlink('session:expired:abc123');

// Batch cleanup with pipeline
const pipeline = redis.pipeline();
expiredKeys.forEach(key => pipeline.unlink(key));
await pipeline.exec();
```

**Python (valkey-py)**:
```python
# Single key
await client.unlink('cache:user:1000')

# Multiple keys
await client.unlink('key1', 'key2', 'key3')
```

---

## SCAN vs KEYS

`KEYS pattern` blocks the server while scanning the entire keyspace. With millions of keys, this freezes all clients for seconds. Never use `KEYS` in production.

`SCAN cursor [MATCH pattern] [COUNT hint]` iterates incrementally in small batches, allowing the server to process other commands between iterations.

```
# NEVER in production:
KEYS user:*

# ALWAYS use SCAN:
SCAN 0 MATCH user:* COUNT 100
# Returns: [next_cursor, [key1, key2, ...]]
# Continue with next_cursor until it returns 0
```

### SCAN Gotchas

- **Duplicates**: SCAN may return the same key in multiple iterations. Deduplicate in your application.
- **Empty pages**: SCAN may return zero results with a non-zero cursor. Keep iterating until cursor is 0.
- **COUNT is a hint**: The server may return more or fewer results than COUNT.
- **Consistency**: SCAN does not guarantee point-in-time snapshot. Keys added or removed during iteration may or may not appear.

### Data-Type Variants

| Command | Iterates Over |
|---------|---------------|
| `SCAN` | Top-level keyspace |
| `HSCAN key cursor` | Hash fields |
| `SSCAN key cursor` | Set members |
| `ZSCAN key cursor` | Sorted set members with scores |

### Code Examples

**Node.js (ioredis)**:
```javascript
async function scanAll(redis, pattern) {
  const results = [];
  let cursor = '0';
  do {
    const [nextCursor, keys] = await redis.scan(
      cursor, 'MATCH', pattern, 'COUNT', 100
    );
    cursor = nextCursor;
    results.push(...keys);
  } while (cursor !== '0');
  return [...new Set(results)]; // deduplicate
}
```

**Python (valkey-py)**:
```python
async def scan_all(client, pattern):
    results = set()
    cursor = 0
    while True:
        cursor, keys = await client.scan(cursor, match=pattern, count=100)
        results.update(keys)
        if cursor == 0:
            break
    return results
```

---

## Pipeline Batching

Each command without pipelining incurs a full network round-trip. Pipelining sends multiple commands in one batch and reads all responses together.

```
# Without pipelining: 3 round-trips
SET key1 val1  -> OK
SET key2 val2  -> OK
SET key3 val3  -> OK

# With pipelining: 1 round-trip
[SET key1 val1, SET key2 val2, SET key3 val3] -> [OK, OK, OK]
```

### Why Pipelining Helps (Not Just RTT)

Pipelining reduces system call overhead, not just network round-trip time:
- Without pipelining: one `read()` + one `write()` syscall per command
- With pipelining: one `read()` + one `write()` for many commands
- The user-to-kernel context switch is a significant penalty even on loopback

**Benchmark results** (10,000 PINGs on loopback):
- Without pipelining: ~1.2 seconds
- With pipelining: ~0.25 seconds
- **5x improvement on loopback** where RTT is already sub-millisecond. Over a real network, improvements are even more dramatic.

**Scaling**: Throughput increases nearly linearly with pipeline depth, eventually reaching **10x the non-pipelined baseline** before plateauing.

**Batch size**: Send batches of approximately 10,000 commands, read replies, then send the next batch. This balances throughput against server memory for queued responses.

### Code Examples

**Node.js (ioredis)**:
```javascript
// Manual pipeline
const pipeline = redis.pipeline();
for (const item of items) {
  pipeline.hset(`item:${item.id}`, item);
}
const results = await pipeline.exec();

// Auto-pipelining with Valkey GLIDE handles this transparently
```

**Python (valkey-py)**:
```python
async with client.pipeline(transaction=False) as pipe:
    for item in items:
        pipe.hset(f'item:{item["id"]}', mapping=item)
    results = await pipe.execute()
```

**Java (Jedis)**:
```java
try (Pipeline pipeline = jedis.pipelined()) {
    for (Item item : items) {
        pipeline.hset("item:" + item.getId(), item.toMap());
    }
    pipeline.sync();
}
```

### Auto-Pipelining

Some clients automatically batch commands issued in the same event loop tick, eliminating the need for explicit pipeline management.

**ioredis**:
```javascript
const redis = new Redis({ enableAutoPipelining: true });
// Concurrent requests from different async contexts are automatically batched
// Good for HTTP servers where many concurrent requests each issue a few commands
```

**Valkey GLIDE**: Uses auto-pipelining by default through its multiplexed connection design. No configuration needed.

Auto-pipelining is especially effective in HTTP servers where many concurrent requests each issue 1-3 commands - they are naturally batched without developer effort.

### Pipeline vs MULTI/EXEC

Pipelines are a client-side optimization that batches network I/O. `MULTI/EXEC` is a server-side transaction that executes commands atomically. You can combine them - send a `MULTI`, queued commands, and `EXEC` inside a single pipeline for both atomicity and network efficiency.

### Pipelining vs Lua Scripting

| Pipelining | Lua Scripting |
|------------|---------------|
| Client sends batch, reads batch | Server executes all logic locally |
| Cannot use results of previous commands | Can read-compute-write atomically |
| Network RTT reduction | Minimal latency for multi-step logic |
| No server-side blocking | Blocks server during execution |

Use pipelining when commands are independent. Use Lua scripts when command B depends on command A's result.

---

## Connection Pooling

Creating a new TCP connection per request is expensive: TCP handshake, optional TLS negotiation, AUTH, SELECT. Use connection pools.

### Valkey GLIDE (Official Client)

GLIDE uses a single multiplexed connection per cluster node with automatic pipelining. No pool management needed - it handles everything internally.

### Traditional Clients

For ioredis, Jedis, valkey-py, and go-redis, configure connection pools:

| Parameter | Recommended Starting Point |
|-----------|---------------------------|
| Pool size | `CPU cores * 2` connections |
| Idle timeout | 30-60 seconds |
| Connection timeout | 2-5 seconds |

**Critical rules**:

- Use separate pools for pub/sub - subscriber connections are monopolized and cannot serve regular commands
- Set connection timeouts to avoid hanging on unreachable servers
- Monitor pool utilization - if all connections are busy, increase pool size or investigate slow commands

**Node.js (ioredis)**:
```javascript
const Redis = require('ioredis');
const redis = new Redis({
  host: 'valkey-host',
  port: 6379,
  maxRetriesPerRequest: 3,
  // ioredis uses a single connection with auto-pipelining by default
});
```

**Python (valkey-py)**:
```python
import valkey.asyncio as valkey

pool = valkey.ConnectionPool(
    host='valkey-host',
    port=6379,
    max_connections=20,
    socket_timeout=5,
)
client = valkey.Valkey(connection_pool=pool)
```

---

## I/O Threading (User Perspective)

Valkey 8.0+ uses I/O multithreading to parallelize network read/write while keeping command execution single-threaded. This tripled throughput from ~360K to 1.2M requests per second on benchmark hardware.

**What this means for application developers**:

- No code changes needed - I/O threading is transparent to clients
- Your commands are still executed sequentially (atomicity guarantees unchanged)
- More I/O threads means higher throughput at the same latency
- The server dynamically activates threads based on load - idle threads do not consume CPU

**When I/O threading helps your application**:

- High request rates from many concurrent clients
- Large request/response payloads (more network I/O per command)
- TLS connections (Valkey 8.1+ offloads TLS to I/O threads - 300% faster connection acceptance)

**When I/O threading does not help**:

- Low request rates or few clients (not enough I/O to parallelize)
- Workloads bottlenecked by slow commands (the main thread is the limit)
- Memory-bound workloads (I/O threads do not help with eviction or persistence)

**Talk to your ops team** about enabling I/O threads if you observe high throughput needs. Typical production configs use 4-9 total threads depending on available CPU cores.

> Cross-reference: See valkey-ops [performance/io-threads](../../../valkey-ops/reference/performance/io-threads.md) for thread count guidelines, benchmarks, and CPU affinity tuning.

---

## Quick Reference: Performance Anti-Patterns

| Anti-Pattern | Impact | Fix |
|-------------|--------|-----|
| `KEYS *` in production | Blocks server for seconds | Use `SCAN` with cursor |
| `DEL` on big keys | Main thread freeze | Use `UNLINK` |
| One connection per request | Connection overhead, exhaustion | Connection pool or GLIDE |
| No pipelining | N round-trips for N commands | Batch with pipelines |
| `HGETALL` on huge hashes | Latency spike + bandwidth | `HSCAN` or `HMGET` specific fields |
| `SMEMBERS` on huge sets | Same as above | `SSCAN` with cursor |
| Storing values > 1MB | Network + memory pressure | Compress or use object storage |
| Sequential commands in a loop | Wasted round-trips | Pipeline the batch |

---

## See Also

**Best Practices**:
- [Memory Best Practices](memory.md) - encoding thresholds and memory-efficient data modeling
- [Key Best Practices](keys.md) - hot key mitigation and key design
- [Cluster Best Practices](cluster.md) - pipelining in cluster mode, per-node batching
- [Persistence Best Practices](persistence.md) - fork pauses, fsync latency impact on throughput
- [High Availability Best Practices](high-availability.md) - retry strategies, connection drop handling

**Commands**:
- [Scripting and Functions](../basics/server-and-scripting.md) - Lua scripts for atomic read-compute-write (vs pipelining)
- [Transaction Commands](../basics/server-and-scripting.md) - MULTI/EXEC atomicity (vs pipeline batching)
- [Server Commands](../basics/server-and-scripting.md) - SLOWLOG, LATENCY, INFO stats for diagnosis

**Patterns**:
- [Caching Patterns](../patterns/caching.md) - client-side caching to eliminate server round-trips
- [Counter Patterns](../patterns/counters.md) - pipelining counter-with-TTL operations
- [Queue Patterns](../patterns/queues.md) - pipelining for batch queue operations
- [Rate Limiting Patterns](../patterns/rate-limiting.md) - pipelining for rate limit checks
- [Session Patterns](../patterns/sessions.md) - pipelining session read + TTL refresh
- [Leaderboard Patterns](../patterns/leaderboards.md) - pipelining bulk score updates

**Security**:
- [Security: Auth and ACL](../security/auth-and-acl.md) - TLS I/O threading performance and connection setup

**Clients**:
- Clients Overview (see valkey-glide skill) - GLIDE auto-pipelining, connection pooling guidance

**Valkey Features**:
- [Performance Improvements Summary](../valkey-features/performance-summary.md) - I/O threading, dual-channel replication, per-version gains

**Anti-Patterns**:
- [Anti-Patterns Quick Reference](../anti-patterns/quick-reference.md) - KEYS, DEL on big keys, missing pipelining, and more

**Ops**:
- valkey-ops [performance/io-threads](../../../valkey-ops/reference/performance/io-threads.md) - I/O thread configuration and benchmarks
- valkey-ops [performance/latency](../../../valkey-ops/reference/performance/latency.md) - latency diagnosis workflow
- valkey-ops [configuration/lazyfree](../../../valkey-ops/reference/configuration/lazyfree.md) - lazy free configuration details
