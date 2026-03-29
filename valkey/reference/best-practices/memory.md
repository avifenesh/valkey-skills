# Memory Best Practices

Use when reducing Valkey memory footprint, choosing data structures for space efficiency, or planning TTL and eviction strategies from an application developer perspective.

---

## Memory-Efficient Data Structure Choices

Valkey uses compact internal encodings (listpack, intset) for small collections. These use 2-10x less memory than full encodings (hashtable, skiplist). When a collection grows beyond a threshold, Valkey promotes it to the full encoding permanently.

### Encoding Thresholds (Defaults)

| Data Type | Compact Encoding | Threshold | Full Encoding |
|-----------|-----------------|-----------|---------------|
| Hash | listpack | <= 512 entries AND values <= 64 bytes | hashtable |
| Sorted Set | listpack | <= 128 entries AND values <= 64 bytes | skiplist + hashtable |
| Set (strings) | listpack | <= 128 entries AND values <= 64 bytes | hashtable |
| Set (integers) | intset | <= 512 entries | hashtable |
| List | quicklist (linked listpacks) | Always quicklist | quicklist |

**Key insight**: The conversion is one-way. Once a collection exceeds a threshold and converts to the full encoding, it stays there even if you remove elements. The only way to get compact encoding back is to delete and recreate the key.

### Check a Key's Encoding

```
OBJECT ENCODING mykey
# Returns: listpack, hashtable, skiplist, intset, quicklist, embstr, int, raw, stream

MEMORY USAGE mykey
# Returns: bytes used by the key (including overhead)
```

### Memory Comparison

A hash with 100 small fields (50-byte values):
- Listpack encoding: ~2-3 KB
- Hashtable encoding: ~10-15 KB

At 10 million hashes, that difference is ~25 GB vs ~120 GB.

---

## Hash-Based Storage

Each top-level key has ~70-80 bytes of metadata overhead. Consolidating related fields into a single hash dramatically reduces per-key overhead.

```
# Wasteful: 3 separate keys (3x metadata overhead)
SET user:1000:name "Alice"
SET user:1000:email "alice@example.com"
SET user:1000:age "30"

# Efficient: 1 hash key (1x metadata overhead)
HSET user:1000 name "Alice" email "alice@example.com" age "30"
```

### Hash-Based Key-Value Optimization

For applications with millions of simple key-value pairs, use hashes to model a memory-efficient key-value store. Instead of individual string keys, split the key into a hash key and a field:

```
# Instead of: SET object:1234 somevalue
# Split: key = object:12, field = 34
HSET object:12 34 somevalue
```

Each hash ends up with ~100 fields, which stays within listpack encoding. This approach uses **5-10x less memory** than individual string keys because:
1. Each top-level key has ~70-80 bytes of metadata overhead
2. Listpack-encoded hashes store field-value pairs as a compact byte array
3. Fewer keys means less overhead in the main dictionary

### Hash Bucketing for Extreme Density

For millions of simple key-value pairs, group them into hash buckets to stay under the compact encoding threshold:

```
# Instead of millions of top-level keys:
SET media:1234 <user_id>

# Bucket by ID range (bucket = id / 100, field = id % 100):
HSET mediabucket:12 34 <user_id>
```

This keeps each hash under ~100 fields, well within the listpack threshold (512). Real-world result: Instagram Engineering reduced memory from 21 GB to 5 GB for 300M key-value pairs using this pattern - a 4x reduction.

### Encoding Threshold Guidance

Stay under the compact encoding thresholds to avoid memory bloat:

| Configuration | Default | Effect |
|---------------|---------|--------|
| `hash-max-listpack-entries` | 512 | Max fields before hash converts to hashtable |
| `hash-max-listpack-value` | 64 | Max field/value size (bytes) before conversion |
| `zset-max-listpack-entries` | 128 | Max members before sorted set converts |
| `zset-max-listpack-value` | 64 | Max member/score size (bytes) before sorted set converts |
| `set-max-listpack-entries` | 128 | Max members before set converts |
| `set-max-listpack-value` | 64 | Max member size (bytes) before set converts |
| `set-max-intset-entries` | 512 | Max integer members before intset converts |

**Gotcha**: Conversion is one-way and permanent for that key. Once a collection exceeds a threshold and converts to the full encoding, it stays there even if you remove elements to go back under the threshold. The only way to get compact encoding back is to delete and recreate the key.

---

## String Encoding Rules

Strings have implicit encoding rules (not configurable):

| Condition | Encoding | Memory |
|-----------|----------|--------|
| Integer value fitting a `long` | `int` | 8 bytes |
| String <= 52 bytes | `embstr` | Single allocation (object + data together) |
| String > 52 bytes | `raw` | Two allocations (pointer + data separately) |

**Practical tip**: Keep string values under 52 bytes when possible to use the `embstr` encoding, which avoids an extra allocation and pointer dereference.

---

## Bit Operations for Boolean Flags

Use `SETBIT`/`GETBIT` for large populations of boolean flags. 100 million users tracked as bits = 12 MB total.

```
# Track daily active users
SETBIT active:2026-03-29 1000 1    # User 1000 was active
GETBIT active:2026-03-29 1000      # Check if active
BITCOUNT active:2026-03-29          # Count active users

# Intersection: users active on both days
BITOP AND active:both active:2026-03-28 active:2026-03-29
```

---

## TTL Strategies

### Always Set TTLs on Cache Entries

Keys without TTLs live forever. This is the most common cause of memory growth.

```
# Set TTL at write time (preferred - atomic)
SET cache:user:1000 "{...}" EX 3600

# Add TTL to existing key
EXPIRE cache:user:1000 3600

# Millisecond precision
SET cache:realtime:data "{...}" PX 500
```

### TTL Patterns

| Pattern | When to Use | Example |
|---------|-------------|---------|
| Fixed TTL at write | Standard caching | `SET key val EX 3600` |
| Sliding window TTL | Sessions, keep-alive | `EXPIRE key 1800` on each access |
| Hierarchical TTL | Data with different freshness needs | Short TTL for volatile data, long for stable |
| No TTL | Persistent data (not cache) | Master data that must never be evicted |

### Hash Field Expiration (Valkey 9.0+)

Set TTLs on individual hash fields instead of the entire key. This avoids splitting data across multiple keys for different expiration needs.

```
# Set fields with per-field TTL
HSETEX user:1000 EX 300 FIELDS 2 csrf_token "tok_abc" otp_code "123456"

# Set TTL on existing field
HEXPIRE user:1000 300 FIELDS 1 csrf_token

# Check remaining TTL
HTTL user:1000 FIELDS 1 csrf_token
```

**Memory overhead**: 16-29 bytes per expiring field. No measurable performance regression on standard hash operations.

---

## Eviction Policies (User Perspective)

Eviction happens when `used_memory` exceeds `maxmemory`. The policy determines which keys are removed.

| Policy | What It Evicts | Best For |
|--------|---------------|----------|
| `allkeys-lru` | Least recently used key | General caching (good default) |
| `allkeys-lfu` | Least frequently used key | Power-law access patterns |
| `volatile-lru` | LRU among keys with TTL only | Mixed cache + persistent data |
| `volatile-ttl` | Shortest remaining TTL first | TTL-based priority control |
| `noeviction` | Nothing (rejects writes) | Data that must never be lost |

### Choosing a Policy

**If your workload is pure cache** (all data can be regenerated): Use `allkeys-lfu`. It adapts to access frequency and handles power-law distributions well.

**If you mix cache and persistent data**: Use `volatile-lru`. Set TTLs on cache keys, leave persistent keys without TTL. Only keys with TTLs are eviction candidates.

**If data loss is unacceptable**: Use `noeviction`. Your application must handle OOM errors on writes. Monitor memory closely.

### What Developers Need to Know

- `maxmemory` must be set in production. Without it, Valkey grows until the OS kills it. Typical recommendation: ~75% of available RAM.
- When eviction kicks in, your cache miss rate increases. This is normal and expected.
- `volatile-*` policies with no TTL-bearing keys behave like `noeviction` - they cannot find candidates and reject writes.
- Sudden spikes in `evicted_keys` (visible in `INFO stats`) mean your working set exceeds memory.

---

## Avoiding Large Values

| Value Size | Impact | Recommendation |
|-----------|--------|----------------|
| < 100 KB | Normal | No action needed |
| 100 KB - 1 MB | Noticeable latency on reads | Consider compression |
| > 1 MB | Significant latency, network pressure | Store in object storage, keep reference in Valkey |

**Compression**: If you must store large values, compress them client-side before writing. Most Valkey clients do not compress automatically.

```python
import zlib
compressed = zlib.compress(json.dumps(data).encode())
await client.set('cache:large:data', compressed, ex=3600)

# Read and decompress
raw = await client.get('cache:large:data')
data = json.loads(zlib.decompress(raw))
```

---

## Quick Reference: Memory Anti-Patterns

| Anti-Pattern | Impact | Fix |
|-------------|--------|-----|
| No `maxmemory` set | OOM kill by OS | Set to ~75% of available RAM |
| Cache keys without TTL | Unbounded memory growth | Always set TTL on cache data |
| Separate keys per object field | 70-80 bytes overhead per key | Pack into hashes |
| Large hashes (10K+ fields) | Slow operations, big key problems | Split into buckets |
| Storing values > 1 MB | Network + memory pressure | Compress or use external storage |
| Relying on encoding downgrade | Never happens automatically | Delete + recreate if needed |

---

## See Also

**Best Practices**:
- [Performance Best Practices](performance.md) - UNLINK vs DEL, pipelining, connection pooling
- [Key Best Practices](keys.md) - key naming for memory efficiency, big key avoidance
- [Persistence Best Practices](persistence.md) - copy-on-write memory overhead during snapshots
- [Cluster Best Practices](cluster.md) - memory distribution across shards
- [High Availability Best Practices](high-availability.md) - eviction and memory pressure during failover

**Commands**:
- [Hash Commands](../commands/hashes.md) - HSET, HMGET, hash bucketing for compact encoding
- [Specialized Data Types](../commands/specialized.md) - HyperLogLog (12 KB cardinality), bitmaps (compact boolean flags)
- [Server Commands](../commands/server.md) - MEMORY USAGE, MEMORY DOCTOR, INFO memory

**Valkey Features**:
- [Hash Field Expiration](../valkey-features/hash-field-ttl.md) - per-field TTL to avoid splitting hashes for expiration

**Patterns**:
- [Caching Patterns](../patterns/caching.md) - eviction policies for cache workloads, TTL patterns
- [Counter Patterns](../patterns/counters.md) - HyperLogLog and bitmaps for compact counting
- [Session Patterns](../patterns/sessions.md) - hash encoding thresholds for session data
- [Leaderboard Patterns](../patterns/leaderboards.md) - sorted set memory for large leaderboards
- [Search and Autocomplete Patterns](../patterns/search-autocomplete.md) - inverted index memory with sets and sorted sets

**Security**:
- [Security: Auth and ACL](../security/auth-and-acl.md) - ACL-restricted namespaces limit memory blast radius

**Clients**:
- [Clients Overview](../clients/overview.md) - client-side caching to reduce server memory pressure

**Anti-Patterns**:
- [Anti-Patterns Quick Reference](../anti-patterns/quick-reference.md) - no `maxmemory`, missing TTL, values over 1 MB, and more

**Ops**:
- valkey-ops [configuration/encoding](../../../valkey-ops/reference/configuration/encoding.md) - encoding threshold configuration reference
- valkey-ops [performance/memory](../../../valkey-ops/reference/performance/memory.md) - `maxmemory` config, fragmentation, hash bucketing details
- valkey-ops [configuration/eviction](../../../valkey-ops/reference/configuration/eviction.md) - eviction policy selection and LFU tuning
