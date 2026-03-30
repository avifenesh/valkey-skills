# Server Operations Commands

Use when iterating the keyspace safely with SCAN, copying keys, coordinating replication durability with WAIT/WAITAOF, or using debug commands.

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

- [Server Information](server.md) - INFO, MEMORY USAGE, OBJECT, DBSIZE
- [Server Client Management](server-client.md) - client connections, configuration, command logging
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
