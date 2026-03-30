# Server Commands

Use when inspecting server state, diagnosing performance issues, understanding memory usage, iterating keyspaces safely, or coordinating replication durability from application code. Most commands here are observational; COPY and WAIT/WAITAOF are the exceptions.

---

## Server Information

### INFO

```
INFO [section [section ...]]
```

Returns server information and statistics as a text blob organized by section. Multiple sections can be requested in one call (since 7.0).

**Complexity**: O(1)

**Key sections for app developers**:

| Section | What it reveals |
|---------|-----------------|
| `memory` | used_memory, peak, fragmentation ratio, eviction stats |
| `stats` | total commands processed, keyspace hits/misses, expired/evicted keys |
| `clients` | connected count, blocked count, max input/output buffer |
| `replication` | role (master/replica), connected replicas, repl offset lag |
| `keyspace` | per-database key count, expiring key count |
| `server` | version, uptime, config file path |

```
-- Check hit rate
INFO stats
-- Look for: keyspace_hits, keyspace_misses
-- Hit rate = hits / (hits + misses)

-- Check memory pressure
INFO memory
-- Look for: used_memory_human, maxmemory_human, mem_fragmentation_ratio

-- Check replication lag
INFO replication
-- Look for: master_repl_offset vs replica offsets

-- Multiple sections at once
INFO memory clients keyspace
```

**Use when**: diagnosing cache hit rates, monitoring memory usage, checking replication health, or verifying server version before using newer commands.

### DBSIZE

```
DBSIZE
```

Returns the number of keys in the currently selected database.

**Complexity**: O(1)

```
SELECT 0
DBSIZE
-- (integer) 42531
```

---

## Memory Inspection

### MEMORY USAGE

```
MEMORY USAGE key [SAMPLES count]
```

Estimates the number of bytes a key and its value consume in RAM, including overhead (key name, expiry metadata, internal structure). Returns nil if the key does not exist.

**Complexity**: O(N) where N is the number of samples

**SAMPLES**: For collection types (lists, sets, hashes, sorted sets, streams), Valkey samples a subset of elements to estimate total size. Default is 5 samples. Use `SAMPLES 0` for exact counting (slower for large collections).

```
SET user:1000:name "Alice"
MEMORY USAGE user:1000:name
-- (integer) 56

HSET user:1000 name "Alice" email "alice@example.com" plan "premium"
MEMORY USAGE user:1000
-- (integer) 168

-- Exact count for large hash
MEMORY USAGE user:1000 SAMPLES 0
-- (integer) 168

-- Key does not exist
MEMORY USAGE nonexistent
-- (nil)
```

**Use when**: finding unexpectedly large keys, comparing storage cost of different data modeling approaches, or debugging memory growth.

---

## Object Introspection

### OBJECT ENCODING

```
OBJECT ENCODING key
```

Returns the internal encoding Valkey uses to store the value. Understanding encodings helps optimize memory usage - compact encodings (like `listpack`) use less memory than full structures (like `hashtable`).

**Complexity**: O(1)

| Type | Compact Encoding | Full Encoding | Threshold |
|------|-----------------|---------------|-----------|
| String | `int`, `embstr` | `raw` | 52 bytes |
| Hash | `listpack` | `hashtable` | 512 fields or 64-byte values |
| List | `listpack` | `quicklist` | 128 elements or 64-byte values |
| Set | `listpack`, `intset` | `hashtable` | 128 members or 64-byte values |
| Sorted Set | `listpack` | `skiplist` | 128 members or 64-byte values |

```
SET counter 42
OBJECT ENCODING counter
-- "int"

SET name "Alice"
OBJECT ENCODING name
-- "embstr"

HSET user:1 name "Alice"
OBJECT ENCODING user:1
-- "listpack"

-- After adding many fields, encoding flips
-- (add 129 fields)
OBJECT ENCODING user:1
-- "hashtable"
```

**Use when**: verifying that keys stay within compact encoding thresholds, or investigating why memory usage changed after data growth.

### OBJECT IDLETIME

```
OBJECT IDLETIME key
```

Returns the idle time in seconds since the key was last accessed (read or write). Only available when `maxmemory-policy` is not `allkeys-lfu` or `volatile-lfu`.

**Complexity**: O(1)

```
GET user:1000:name
OBJECT IDLETIME user:1000:name
-- (integer) 0

-- Wait, then check again
OBJECT IDLETIME user:1000:name
-- (integer) 15
```

**Use when**: identifying cold data candidates for migration or cleanup.

### OBJECT FREQ

```
OBJECT FREQ key
```

Returns the logarithmic access frequency counter when `maxmemory-policy` uses LFU (allkeys-lfu or volatile-lfu). The counter is logarithmic - a value of 10 means many more accesses than 5.

**Complexity**: O(1)

```
OBJECT FREQ hot:key
-- (integer) 12

OBJECT FREQ cold:key
-- (integer) 1
```

**Use when**: identifying hot keys under LFU eviction policy.

### OBJECT REFCOUNT

```
OBJECT REFCOUNT key
```

Returns the reference count of the value object. In practice this is almost always 1 since shared objects were removed in version 4.0+. Rarely useful for app developers.

**Complexity**: O(1)

---

## Client Management

### CLIENT ID

```
CLIENT ID
```

Returns the unique integer ID of the current connection. Useful for `CLIENT TRACKING REDIRECT` and log correlation.

**Complexity**: O(1)

```
CLIENT ID
-- (integer) 42
```

### CLIENT SETNAME / CLIENT GETNAME

```
CLIENT SETNAME connection-name
CLIENT GETNAME
```

Sets and retrieves a name for the current connection. Named connections appear in `CLIENT LIST` output and server logs, making debugging easier.

**Complexity**: O(1)

```
CLIENT SETNAME worker:orders:1
-- OK

CLIENT GETNAME
-- "worker:orders:1"
```

**Use when**: running multiple application instances and needing to identify which connection is which during debugging or in `CLIENT LIST` output.

### CLIENT INFO

```
CLIENT INFO
```

Returns information about the current connection in the same format as CLIENT LIST but only for this connection. Since 6.2.

**Complexity**: O(1)

```
CLIENT INFO
-- id=42 addr=127.0.0.1:52300 name=worker:orders:1 db=0 ...
```

### CLIENT LIST

```
CLIENT LIST [TYPE normal|master|replica|pubsub]
            [ID client-id [...]]
            [additional filters...]
```

Lists all open client connections with detailed metadata. Each connection is one line with space-separated key=value pairs.

**Complexity**: O(N) where N is the number of connected clients

**Key fields in output**:

| Field | Meaning |
|-------|---------|
| `id` | Unique client ID |
| `addr` | Client address:port |
| `name` | Connection name (from CLIENT SETNAME) |
| `db` | Current database number |
| `cmd` | Last command executed |
| `age` | Connection age in seconds |
| `idle` | Idle time in seconds |
| `flags` | Client flags (N=normal, S=replica, M=master, P=pubsub, x=executing) |
| `omem` | Output buffer memory usage |
| `tot-mem` | Total memory consumed by this client |

**Filtering (Valkey 9.0+)**:

```
-- Filter by connection name
CLIENT LIST NAME worker:*

-- Filter by library
CLIENT LIST LIB-NAME ioredis

-- Filter by idle time (seconds)
CLIENT LIST IDLE 300

-- Filter by flags
CLIENT LIST FLAGS S

-- Negation filters
CLIENT LIST NOT-TYPE replica NOT-DB 0
```

```
-- Find idle connections
CLIENT LIST IDLE 600
-- Shows connections idle for 10+ minutes

-- Find by type
CLIENT LIST TYPE pubsub
```

**Use when**: debugging connection leaks, finding blocked or idle clients, or identifying which application instances are connected.

### CLIENT NO-EVICT

```
CLIENT NO-EVICT ON|OFF
```

When ON, prevents this connection from being evicted when the server hits `maxmemory`. Useful for admin/monitoring connections that must stay alive. Since 7.0.

**Complexity**: O(1)

### CLIENT NO-TOUCH

```
CLIENT NO-TOUCH ON|OFF
```

When ON, commands from this connection do not update the LRU/LFU counters of accessed keys. Useful for monitoring or analytics reads that should not affect eviction decisions. Since 7.2.

**Complexity**: O(1)

```
-- Monitoring connection that should not warm up keys
CLIENT NO-TOUCH ON
GET cold:key    -- does not update idle time or frequency counter
```

---

## Configuration

### CONFIG GET

```
CONFIG GET parameter [parameter ...]
```

Returns the current value of configuration parameters. Supports glob patterns. Read-only - does not change any settings.

**Complexity**: O(N) where N is the number of matching parameters

```
-- Check memory limit
CONFIG GET maxmemory
-- 1) "maxmemory"
-- 2) "1073741824"

-- Check eviction policy
CONFIG GET maxmemory-policy
-- 1) "maxmemory-policy"
-- 2) "allkeys-lru"

-- Glob pattern
CONFIG GET *timeout*
-- Returns all timeout-related settings

-- Multiple patterns
CONFIG GET maxmemory maxmemory-policy hz
```

**Commonly checked parameters for app developers**:

| Parameter | What it tells you |
|-----------|-------------------|
| `maxmemory` | Memory limit (0 = unlimited) |
| `maxmemory-policy` | Eviction policy (noeviction, allkeys-lru, volatile-lfu, etc.) |
| `timeout` | Idle client timeout in seconds (0 = disabled) |
| `databases` | Number of available databases |
| `hz` | Server timer frequency (affects expire precision) |
| `save` | RDB snapshot schedule |
| `appendonly` | Whether AOF is enabled |
| `cluster-enabled` | Whether cluster mode is active |

**Use when**: verifying server configuration matches your application's assumptions, or dynamically adapting behavior based on server settings.

---

## Command Logging

### COMMANDLOG GET

```
COMMANDLOG GET count type
```

Returns entries from the command log. Valkey 8.1+ replaces SLOWLOG with a unified command log that tracks three categories. The `type` argument is required.

**Complexity**: O(N) where N is the count

**Types**:

| Type | What it captures |
|------|------------------|
| `slow` | Commands exceeding `commandlog-slow-execution-time` threshold |
| `large-request` | Commands exceeding `commandlog-large-request-size` threshold |
| `large-reply` | Commands exceeding `commandlog-large-reply-size` threshold |

**Entry format**: Each entry is an array of [id, timestamp, duration_or_size, [command args], client_addr, client_name].

```
-- Get last 10 slow commands
COMMANDLOG GET 10 slow

-- Get commands with large replies
COMMANDLOG GET 5 large-reply
```

**Use when**: identifying slow commands causing latency spikes, or finding commands that send/receive unusually large payloads.

### SLOWLOG GET (Legacy)

```
SLOWLOG GET [count]
```

Returns the last `count` entries from the slow log (default: all). Legacy command - use COMMANDLOG GET on Valkey 8.1+.

**Complexity**: O(N)

```
SLOWLOG GET 10
-- Each entry: [id, timestamp, duration_microseconds, [command args], client_addr, client_name]
```

**Use when**: on Valkey versions before 8.1, or for quick slow command diagnostics.

---

## Keyspace Iteration

### SCAN

```
SCAN cursor [MATCH pattern] [COUNT count] [TYPE type]
```

Incrementally iterates over the key names in the database. Returns a cursor and a batch of keys. Call repeatedly with the returned cursor until it returns 0.

**Complexity**: O(1) per call, O(N) for complete iteration

**SCAN is the safe alternative to KEYS**. The `KEYS` command blocks the server while scanning the entire keyspace. SCAN returns small batches without blocking.

**Parameters**:

| Parameter | Description |
|-----------|-------------|
| `cursor` | Start with 0. Use the returned cursor for subsequent calls. |
| `MATCH pattern` | Filter keys by glob pattern (applied after cursor sampling). |
| `COUNT count` | Hint for batch size (default ~10). Not a hard limit. |
| `TYPE type` | Filter by data type: string, list, set, zset, hash, stream. Since 6.0. |

**Complete iteration pattern**:

```
-- Pseudocode: iterate all keys matching "session:*"
cursor = "0"
do
    result = SCAN cursor MATCH "session:*" COUNT 100
    cursor = result[0]
    keys = result[1]
    -- process keys batch
while cursor != "0"
```

**Concrete example** - find all hash keys:

```
SCAN 0 TYPE hash COUNT 100
-- 1) "17"           -- next cursor
-- 2) 1) "user:1000"
--    2) "user:1001"
--    3) "config:app"

SCAN 17 TYPE hash COUNT 100
-- 1) "0"            -- cursor 0 = iteration complete
-- 2) 1) "user:1002"
```

**Important behaviors**:

1. **Cursor is opaque** - treat it as a string, do not interpret its numeric value.
2. **Duplicates are possible** - if the hash table resizes during iteration, some keys may appear twice. Deduplicate on the client side if needed.
3. **Deletions during iteration** - keys added or deleted during iteration may or may not appear. SCAN does not provide a snapshot.
4. **COUNT is a hint** - the actual batch size can vary. For small databases, a single call may return all keys regardless of COUNT.
5. **MATCH filters post-sampling** - if your pattern matches few keys, many iterations may return empty batches. Increase COUNT to compensate.
6. **Complete when cursor is "0"** - the only way to know iteration is done. The number of returned keys is not a reliable indicator.

**Pattern: safe deletion of matching keys**:

```
cursor = "0"
do
    result = SCAN cursor MATCH "temp:*" COUNT 100
    cursor = result[0]
    if len(result[1]) > 0
        UNLINK result[1]...   -- non-blocking delete
while cursor != "0"
```

**Pattern: count keys by type without KEYS**:

```
cursor = "0"
hash_count = 0
do
    result = SCAN cursor TYPE hash COUNT 500
    cursor = result[0]
    hash_count += len(result[1])
while cursor != "0"
```

**Related SCAN variants**: HSCAN (hash fields), SSCAN (set members), ZSCAN (sorted set members) follow the same cursor pattern.

**Use when**: iterating the keyspace in production, cleaning up expired or orphaned keys, or auditing key distribution. Never use KEYS in production.

### COPY

```
COPY source destination [DB db] [REPLACE]
```

Copies the value and TTL of `source` to `destination`. The source key is not modified.

**Complexity**: O(N) for collections, O(1) for strings

**Options**:

| Option | Effect |
|--------|--------|
| `DB db` | Copy to a different database (standalone mode only) |
| `REPLACE` | Overwrite destination if it exists (without REPLACE, returns 0 if destination exists) |

```
SET user:1000:name "Alice"
COPY user:1000:name user:1000:name:backup
-- (integer) 1

-- Copy to different database
COPY user:1000:name user:1000:name DB 1
-- (integer) 1

-- With REPLACE
SET dest "old"
COPY source dest REPLACE
-- (integer) 1 (dest overwritten)

-- Without REPLACE, destination exists
COPY source dest
-- (integer) 0 (not copied)
```

**Use when**: creating backups before mutations, duplicating data across databases, or implementing snapshot-and-modify patterns.

---

## Replication Durability

### WAIT

```
WAIT numreplicas timeout
```

Blocks until all preceding write commands from this connection have been acknowledged by at least `numreplicas` replicas, or until `timeout` milliseconds elapse. Returns the number of replicas that acknowledged.

**Complexity**: O(1)

```
SET critical:data "important"
WAIT 1 5000
-- (integer) 1    -- 1 replica acknowledged

SET critical:data "very-important"
WAIT 2 1000
-- (integer) 1    -- only 1 of 2 replicas acknowledged before timeout
```

**A timeout of 0 blocks indefinitely** - use with caution.

WAIT provides a synchronous replication guarantee on a per-connection basis. It does not turn Valkey into a strongly consistent store - a replica could still lose data if it crashes before persisting.

**Use when**: writing data that must survive primary failure (payment records, state transitions), and you need confirmation that at least N replicas have the data before proceeding.

### WAITAOF

```
WAITAOF numlocal numreplicas timeout
```

Blocks until preceding writes are flushed to the AOF on the local primary and/or on replicas. Returns a two-element array: [local_aof_count, replica_aof_count]. Since 7.2.

**Complexity**: O(1)

```
SET payment:9001 '{"status":"completed"}'
WAITAOF 1 1 5000
-- 1) (integer) 1    -- written to local AOF
-- 2) (integer) 1    -- written to 1 replica's AOF

-- Local AOF only, no replica requirement
WAITAOF 1 0 3000
-- 1) (integer) 1
-- 2) (integer) 0
```

**Use when**: you need durability guarantees beyond in-memory replication - confirming data is fsync'd to disk on the primary and/or replicas before acknowledging to the client.

---

## Debugging

### DEBUG OBJECT

```
DEBUG OBJECT key
```

Returns internal details about a key's representation. This is a debug command - not meant for production use, but occasionally useful for understanding encoding and memory behavior.

```
DEBUG OBJECT user:1000
-- Value at:0x7f... refcount:1 encoding:listpack serializedlength:42 lru:... lru_seconds_idle:5 type:hash
```

**Use when**: you need more detail than OBJECT ENCODING provides, such as serialized length or exact memory address. Prefer OBJECT ENCODING and MEMORY USAGE for routine work.

---

## Quick Reference

| Command | Use when... |
|---------|-------------|
| `INFO memory` | Checking memory pressure, fragmentation |
| `INFO stats` | Monitoring hit rate, throughput |
| `INFO replication` | Checking replica lag |
| `MEMORY USAGE key` | Sizing individual keys |
| `OBJECT ENCODING key` | Verifying compact encoding |
| `OBJECT IDLETIME key` | Finding cold data |
| `CLIENT LIST` | Debugging connections |
| `CLIENT SETNAME name` | Identifying your connection in logs |
| `CLIENT NO-TOUCH ON` | Monitoring without warming keys |
| `CONFIG GET param` | Checking server settings |
| `COMMANDLOG GET N type` | Finding slow or large commands |
| `SCAN 0 MATCH pat COUNT n` | Safe keyspace iteration |
| `COPY src dst` | Non-destructive key duplication |
| `WAIT N timeout` | Replication acknowledgment |
| `WAITAOF N M timeout` | Disk persistence acknowledgment |

---

## See Also

- [Memory Best Practices](../best-practices/memory.md) - encoding thresholds, memory optimization strategies
- [Performance Best Practices](../best-practices/performance.md) - pipelining, connection management, COMMANDLOG analysis
- [Key Best Practices](../best-practices/keys.md) - key naming conventions, SCAN patterns
- [Cluster Best Practices](../best-practices/cluster.md) - cluster-aware client configuration
- [High Availability Best Practices](../best-practices/high-availability.md) - WAIT/WAITAOF for replication durability
- [Persistence Best Practices](../best-practices/persistence.md) - AOF and RDB configuration checked via CONFIG GET
- [Compatibility and Migration](../overview/compatibility.md) - extended-redis-compatibility mode for CONFIG SET
- [Cluster Enhancements](../valkey-features/cluster-enhancements.md) - numbered databases (SELECT) in cluster mode (9.0+)
- [Performance Summary](../valkey-features/performance-summary.md) - version-specific optimizations
- [Anti-Patterns](../anti-patterns/quick-reference.md) - KEYS in production, ignoring COMMANDLOG output
