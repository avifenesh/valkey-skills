# Anti-Patterns Quick Reference

Use when reviewing application code for common Valkey mistakes, or as a checklist before deploying to production.

## Contents

- Anti-Pattern Table (line 15)
- Severity Guide (line 42)
- Detection Commands (line 77)
- Quick Decision Guide (line 106)

---

## Anti-Pattern Table

| Anti-Pattern | Problem | Solution |
|-------------|---------|----------|
| `KEYS *` in production | Blocks the server while scanning the entire keyspace. With millions of keys, freezes all clients for seconds. | Use `SCAN` with cursor iteration. Variants: `SSCAN` (sets), `HSCAN` (hashes), `ZSCAN` (sorted sets). |
| `DEL` on big keys | Synchronous deletion blocks the main thread. Large hashes, sets, or lists cause latency spikes visible to all clients. | Use `UNLINK` (non-blocking background deletion). For very large hashes, use `HSCAN` + `HDEL` to delete incrementally. |
| `HGETALL` on huge hashes | Returns all fields at once. Hashes with thousands of fields cause latency spikes and high bandwidth usage. | Use `HMGET` for specific fields, or `HSCAN` to iterate in batches. |
| `SMEMBERS` on huge sets | Same issue as HGETALL - returns the entire set in one response, blocking the server. | Use `SSCAN` with cursor iteration. |
| No `maxmemory` set | Valkey grows unbounded until the OS OOM-kills the process. All data is lost. | Set `maxmemory` to ~75% of available RAM. Leave headroom for fork overhead and fragmentation. |
| No authentication | Anyone who can reach the port can read, write, and delete all data. | Set `requirepass` or configure ACL users. See [Auth and ACL](../security/auth-and-acl.md). |
| One connection per request | TCP connection setup is expensive (especially with TLS). Exhausts server connection limits under load. | Use connection pools (traditional clients) or GLIDE's multiplexed connections. See Clients Overview (see valkey-glide skill). |
| `FLUSHALL` accessible | An application bug or compromised credential can wipe all data instantly. | Rename or disable the command via `rename-command` or ACL restrictions. |
| Short cryptic key names | Saves negligible memory (keys are small relative to values) but makes debugging and operations painful. | Use readable colon-delimited names: `user:1000:profile`, `cache:api:products:page:1`. |
| Single hot key for counters | In cluster mode, all operations on one key go to one shard. Creates a bottleneck under high write rates. | Shard the key: `counter:{0}`, `counter:{1}`, ..., `counter:{N}`. Sum across shards when reading. See [Counter Patterns](../patterns/counters.md). |
| Storing values > 1 MB | Large values cause network and memory pressure. Slow reads, high bandwidth, increased fragmentation. | Compress values before storing. For truly large objects, use object storage (S3, GCS) and store only the reference in Valkey. |
| Multiple databases in production (pre-9.0) | Databases share everything (memory, CPU, connections). No isolation. `FLUSHDB` on the wrong database is catastrophic. | Use separate instances for workload isolation. In Valkey 9.0+ cluster mode, numbered databases are available but still share resources. |
| Missing TTL on cache entries | Keys without TTL live forever. Memory fills up with stale data until eviction kicks in (if configured) or OOM. | Always set TTL at write time: `SET key value EX 3600`. Use `allkeys-lru` eviction as a safety net. See [Caching Patterns](../patterns/caching.md). |
| Sequential commands without pipelining | Each command incurs a full network round-trip. N commands = N round-trips. | Use pipelining to batch commands. Up to 10x throughput improvement. GLIDE auto-pipelines by default. See Clients Overview (see valkey-glide skill). |
| Using `WATCH` + `MULTI` for complex logic | Cannot use intermediate results inside a transaction. Frequent retries under contention waste resources. | Use Lua scripts or Functions for read-then-write atomic operations. |
| Pub/Sub for durable messaging | Pub/sub is fire-and-forget. Messages are lost if no subscriber is listening when the message is published. | Use Streams with consumer groups for at-least-once delivery and durable messaging. |
| Unbounded list/stream growth | Lists and streams without size limits grow indefinitely, consuming all available memory. | Use `LTRIM` to cap lists. Use `XTRIM` with `MAXLEN` or `MINID` to cap streams. |
| Blocking commands on shared connections | `BLPOP`, `BRPOP`, `XREAD BLOCK` monopolize the connection. Other commands on the same connection are delayed. | Use dedicated connections for blocking operations. Separate pool for blocking consumers. |
| Lua scripts with unbounded loops | Scripts block the server during execution. A loop over a large dataset freezes all clients. | Keep scripts fast and bounded. Avoid iterating over large collections inside scripts. Use `SCAN` patterns outside Lua instead. |
| `SORT` on large collections | SORT is O(N+M*log(M)) and blocks the server. Sorting millions of elements causes multi-second freezes. | Pre-sort data using sorted sets (`ZADD`/`ZRANGE`), or sort application-side. |

---

## Severity Guide

### Critical (data loss or outage risk)

- No `maxmemory` set - leads to OOM kill
- No authentication - full data exposure
- `FLUSHALL` accessible - accidental data wipe
- Missing TTL on cache entries - silent memory exhaustion

### High (performance degradation)

- `KEYS *` in production - server freeze
- `DEL` on big keys - latency spikes
- `HGETALL` / `SMEMBERS` on huge collections - blocking reads
- Sequential commands without pipelining - wasted throughput
- Lua scripts with unbounded loops - server freeze
- `SORT` on large collections - multi-second blocks

### Medium (operational or design issues)

- One connection per request - resource waste
- Single hot key for counters - shard bottleneck
- Storing values > 1 MB - network and memory pressure
- Unbounded list/stream growth - gradual memory consumption
- Blocking commands on shared connections - connection monopolization

### Low (maintainability)

- Short cryptic key names - hard to debug
- Multiple databases without isolation - confusing operations
- Using WATCH + MULTI for complex logic - unnecessary retries
- Pub/Sub for durable messaging - silent message loss

---

## Detection Commands

Find problems in a running Valkey instance:

```bash
# Find big keys (keys with many elements or large memory)
valkey-cli --bigkeys

# Find keys consuming the most memory
valkey-cli --memkeys

# Find hot keys (most-accessed)
valkey-cli --hotkeys

# Check if maxmemory is set
valkey-cli CONFIG GET maxmemory

# Check current memory usage
valkey-cli INFO memory

# Check if authentication is configured
valkey-cli ACL LIST

# Check for slow commands
valkey-cli SLOWLOG GET 10
```

---

## Quick Decision Guide

### "Should I use DEL or UNLINK?"

Always use `UNLINK` unless you need synchronous deletion. In Valkey 8.0+, `DEL` defaults to async behavior (`lazyfree-lazy-user-del yes`), but `UNLINK` is explicit and clear.

### "Should I use KEYS or SCAN?"

Never use `KEYS` in production. Use `SCAN` with a cursor. SCAN may return duplicates (deduplicate client-side) and empty pages (keep iterating until cursor returns 0).

### "Should I use Pub/Sub or Streams?"

- **Pub/Sub**: Real-time notifications where message loss is acceptable (typing indicators, presence updates) - see [Pub/Sub Commands](../basics/data-types.md) and [Pub/Sub Patterns](../patterns/pubsub-patterns.md)
- **Streams**: Any case where messages must not be lost (task queues, event sourcing, audit logs) - see [Stream Commands](../basics/data-types.md) and [Queue Patterns](../patterns/queues.md)

### "Should I use MULTI/EXEC or Lua?"

- **MULTI/EXEC**: Batching independent writes atomically (no read-then-write logic needed) - see [Transaction Commands](../basics/server-and-scripting.md)
- **Lua / Functions**: Atomic read-then-write, conditional logic, compare-and-swap - see [Scripting and Functions](../basics/server-and-scripting.md)
- **SET IFEQ / DELIFEQ**: Simple compare-and-swap or conditional delete (Valkey 8.1+/9.0+, no Lua needed) - see [Conditional Operations](../valkey-features/conditional-ops.md)

### "How big should my keys/values be?"

- **Key names**: Readable, not abbreviated. `user:1000:profile` costs negligible extra bytes.
- **Values**: Keep under 100 KB ideally, under 1 MB maximum. Compress JSON/serialized data.
- **Collections**: Keep hashes under 10K fields, lists under 100K elements, sets under 100K members. Split larger collections.

---

