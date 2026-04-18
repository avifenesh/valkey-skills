# Performance: Throughput and Command Selection

Use when optimizing Valkey throughput with pipelining, connection pooling, and I/O threading, choosing between command variants (UNLINK vs DEL, SCAN vs KEYS), or reviewing performance anti-patterns before production deployment.

## Contents

- Command Selection: UNLINK vs DEL, SCAN vs KEYS
- Pipeline Batching
- Connection Pooling
- I/O Threading (User Perspective)
- Quick Reference: Performance Anti-Patterns

---

## Command Selection

### UNLINK vs DEL

`DEL` frees memory synchronously on the main thread - large keys block all clients. `UNLINK` reclaims memory on a background thread.

**Valkey 8.0+ change**: `lazyfree-lazy-user-del` defaults to `yes`, making `DEL` behave like `UNLINK` by default. This is a behavioral change from Redis, where the default was `no`. Other lazyfree defaults flipped in the same release: `lazyfree-lazy-eviction`, `lazyfree-lazy-expire`, `lazyfree-lazy-server-del`, and `lazyfree-lazy-user-flush` all default to `yes`.

Still prefer explicit `UNLINK` in code - it communicates intent and remains non-blocking if someone sets `lazyfree-lazy-user-del no`.

### SCAN vs KEYS

`KEYS pattern` blocks the server. Use `SCAN cursor MATCH pattern COUNT hint` instead. Iterate until cursor returns `0`. Deduplicate results - SCAN may return the same key twice across iterations. `COUNT` is a hint, not a hard limit.

Type-specific variants: `HSCAN`, `SSCAN`, `ZSCAN` for iterating inside a single key.

---

## Pipeline Batching

Without pipelining, each command incurs a full network round-trip. Pipelining sends multiple commands in one batch and reads all responses together.

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

Some clients batch commands issued in the same event loop tick automatically.

**ioredis**:
```javascript
const redis = new Redis({ enableAutoPipelining: true });
// Concurrent requests from different async contexts are automatically batched
// Good for HTTP servers where many concurrent requests each issue a few commands
```

**Valkey GLIDE**: Uses auto-pipelining by default through its multiplexed connection design. No configuration needed.

Especially effective in HTTP servers where concurrent requests each issue 1-3 commands - naturally batched without developer effort.

### Pipeline vs MULTI/EXEC

Pipelines are a client-side optimization batching network I/O. `MULTI/EXEC` is a server-side atomic transaction. Combine them: send `MULTI`, queued commands, and `EXEC` inside a single pipeline for both atomicity and network efficiency.

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

Creating a TCP connection per request is expensive: TCP handshake, TLS negotiation, AUTH, SELECT. Use connection pools.

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

Valkey 8.0+ parallelizes network read/write via I/O multithreading while keeping command execution single-threaded. This tripled throughput from ~360K to 1.2M RPS on benchmark hardware.

**What this means for application developers**:

- No code changes needed - I/O threading is transparent to clients
- Your commands are still executed sequentially (atomicity guarantees unchanged)
- More I/O threads means higher throughput at the same latency
- The server dynamically activates threads based on load - idle threads do not consume CPU

**When I/O threading helps your application**:

- High request rates from many concurrent clients
- Large request/response payloads (more network I/O per command)
- TLS connections (Valkey 8.1+ offloads TLS handshakes to I/O threads, so a burst of new TLS connections no longer monopolizes the main thread)

**When I/O threading does not help**:

- Low request rates or few clients (not enough I/O to parallelize)
- Workloads bottlenecked by slow commands (the main thread is the limit)
- Memory-bound workloads (I/O threads do not help with eviction or persistence)

Coordinate with ops to enable I/O threads for high throughput needs. Typical production configs use 4-9 total threads depending on available CPU cores.

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
