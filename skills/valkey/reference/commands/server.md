# Server Information Commands

Use when inspecting server state, diagnosing memory usage, understanding key encoding, or checking server info sections.

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

## See Also

- [Server Client Management](server-client.md) - client connections, configuration, command logging
- [Server Operations](server-ops.md) - SCAN, COPY, WAIT/WAITAOF, debugging
- [Memory Best Practices](../best-practices/memory.md) - encoding thresholds, memory optimization strategies
- [Performance Best Practices](../best-practices/performance.md) - pipelining, connection management, COMMANDLOG analysis
- [Key Best Practices](../best-practices/keys.md) - key naming conventions, SCAN patterns
