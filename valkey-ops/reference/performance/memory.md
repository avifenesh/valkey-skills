# Memory Optimization

Use when reducing Valkey memory footprint, tuning encoding thresholds for
space efficiency, managing memory fragmentation, or configuring eviction.

---

## maxmemory Configuration

| Directive | Default | Notes |
|-----------|---------|-------|
| `maxmemory` | 0 (unlimited) | Source: `src/config.c` line 3442. Set explicitly in production. |
| `maxmemory-policy` | `noeviction` | Source: `src/config.c` line 3339. Returns errors on writes when full. |
| `maxmemory-samples` | 5 | Source: `src/config.c` line 3379. Keys sampled per eviction cycle. |
| `maxmemory-eviction-tenacity` | 10 | Source: `src/config.c` line 3380. Higher = more aggressive eviction. |
| `maxmemory-clients` | 0 (unlimited) | Source: `src/config.c` line 3458. Accepts percentage (e.g. `5%`). |

### Eviction Policies

Source-verified from `src/config.c` (maxmemory_policy_enum, lines 60-69):

| Policy | Scope | Algorithm |
|--------|-------|-----------|
| `noeviction` | - | Return errors on writes when full |
| `allkeys-lru` | All keys | Approximate LRU |
| `allkeys-lfu` | All keys | Approximate LFU |
| `allkeys-random` | All keys | Random eviction |
| `volatile-lru` | Keys with TTL | Approximate LRU |
| `volatile-lfu` | Keys with TTL | Approximate LFU |
| `volatile-random` | Keys with TTL | Random eviction |
| `volatile-ttl` | Keys with TTL | Shortest TTL first |

Recommendation for most cache workloads: `allkeys-lfu`. It adapts to access
frequency and handles both hot and cold data well.

### Setting maxmemory

```bash
# Set to 75% of available RAM (leave room for fork, OS, buffers)
valkey-cli CONFIG SET maxmemory 12gb
valkey-cli CONFIG SET maxmemory-policy allkeys-lfu

# Cap client buffer memory at 5% of maxmemory
valkey-cli CONFIG SET maxmemory-clients 5%
```

## Encoding Thresholds

Valkey uses compact internal encodings (listpack) for small collections, then
promotes to full data structures when thresholds are exceeded. Keeping
collections below these thresholds saves significant memory.

Source-verified defaults from `src/config.c`:

| Directive | Default | What it controls |
|-----------|---------|------------------|
| `hash-max-listpack-entries` | 512 | Max hash fields before converting to hashtable |
| `hash-max-listpack-value` | 64 bytes | Max field/value size before converting to hashtable |
| `set-max-listpack-entries` | 128 | Max set members before converting to hashtable |
| `set-max-listpack-value` | 64 bytes | Max member size before converting to hashtable |
| `zset-max-listpack-entries` | 128 | Max sorted set members before converting to skiplist |
| `zset-max-listpack-value` | 64 bytes | Max member size before converting to skiplist |
| `list-max-listpack-size` | -2 | -2 means 8KB per listpack node |

### Memory Impact

Listpack encoding uses 2-10x less memory than the equivalent hashtable or
skiplist. Example:

- Hash with 100 fields (50-byte values): ~4KB in listpack vs ~14KB in hashtable
- Keep hashes under 512 entries and 64 bytes per field/value to stay in listpack

### Checking Key Encoding

```bash
# Check what encoding a key uses
valkey-cli OBJECT ENCODING mykey

# Returns: listpack, hashtable, skiplist, quicklist, intset, etc.

# Check memory usage of a specific key
valkey-cli MEMORY USAGE mykey
```

## Memory-Efficient Data Modeling

### 1. Hash-based storage

Consolidate related fields into hashes instead of separate top-level keys.
Each top-level key has overhead (~70-80 bytes for metadata). A hash with
10 fields under the listpack threshold uses far less than 10 separate keys.

```bash
# Instead of:
SET user:1000:name "Alice"
SET user:1000:email "alice@example.com"
SET user:1000:age "30"

# Use:
HSET user:1000 name "Alice" email "alice@example.com" age "30"
```

### 2. Bit operations for boolean flags

Use SETBIT/GETBIT for boolean flags across large populations. 100 million
users represented as bits = 12MB total.

```bash
SETBIT active_users 1000 1
GETBIT active_users 1000
BITCOUNT active_users
```

### 3. TTLs on everything

Set expiration on data you do not need indefinitely. Valkey will reclaim
memory through active and lazy expiration.

```bash
SET session:abc123 "data" EX 3600    # 1 hour TTL
```

### 4. Avoid KEYS command

`KEYS *` scans the entire keyspace and blocks the main thread. Use `SCAN`
with a cursor for production enumeration.

```bash
# Instead of: KEYS user:*
SCAN 0 MATCH user:* COUNT 100
```

## Fragmentation Management

### Monitoring

```bash
valkey-cli INFO memory | grep mem_fragmentation_ratio
```

| Ratio | Meaning | Action |
|-------|---------|--------|
| < 1.0 | Using swap (critical) | Increase RAM or reduce dataset |
| 1.0-1.5 | Normal | No action needed |
| 1.5-2.0 | Moderate fragmentation | Consider `MEMORY PURGE` |
| > 2.0 | High fragmentation | Active defrag or restart |

### Active Defragmentation

```bash
# Enable active defragmentation
CONFIG SET activedefrag yes

# Tune defrag thresholds
CONFIG SET active-defrag-enabled yes
CONFIG SET active-defrag-threshold-lower 10    # Start when frag > 10%
CONFIG SET active-defrag-threshold-upper 100   # Max effort when frag > 100%
CONFIG SET active-defrag-cycle-min 1           # Min CPU% for defrag
CONFIG SET active-defrag-cycle-max 25          # Max CPU% for defrag
```

### Manual Memory Purge

```bash
# Force jemalloc to release unused pages back to OS
MEMORY PURGE

# Check detailed memory breakdown
MEMORY STATS

# Get diagnostic advice
MEMORY DOCTOR
```

## Memory Diagnostics

```bash
# Full memory overview
valkey-cli INFO memory

# Key fields to watch:
# used_memory              - total allocated by Valkey
# used_memory_rss          - resident set size (OS perspective)
# used_memory_peak         - historical peak
# mem_fragmentation_ratio  - RSS / used_memory
# mem_clients_normal       - memory used by client buffers
# mem_clients_slaves       - memory used by replica buffers
# used_memory_dataset      - memory used by actual data
```

---

## See Also

- [Defragmentation](defragmentation.md) - active defrag configuration and monitoring
- [Encoding Thresholds](../configuration/encoding.md) - detailed encoding threshold reference
- [Eviction Policies](../configuration/eviction.md) - policy selection and LFU tuning
- [Lazy Free](../configuration/lazyfree.md) - async free configuration
- [Capacity Planning](../operations/capacity-planning.md) - memory sizing guidelines
- [Troubleshooting OOM](../troubleshooting/oom.md) - OOM diagnosis and resolution
- [See valkey-dev: zmalloc](../valkey-dev/reference/memory/zmalloc.md) - per-thread memory counters, jemalloc integration
- [See valkey-dev: defragmentation](../valkey-dev/reference/memory/defragmentation.md) - active defrag internals
- [See valkey-dev: lazy-free](../valkey-dev/reference/memory/lazy-free.md) - asynchronous object freeing
