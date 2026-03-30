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

### maxmemory with Replication

When replication is configured, set maxmemory 10-20% lower than available RAM.
Replication and AOF buffers are NOT counted against maxmemory for eviction.
The formula for eviction triggering is:
`used_memory - mem_not_counted_for_evict > maxmemory`. Monitor
`mem_not_counted_for_evict` in `INFO memory` to see replication buffer overhead.
If a replica disconnects and needs full resync, the primary allocates a large
output buffer for the RDB transfer.

### Fork Memory Overhead

BGSAVE and BGREWRITEAOF use fork(), which copies the page table:

```
page_table_size = (dataset_size / page_size) * pointer_size
```

| Dataset Size | Page Table Copy | Typical Fork Time |
|-------------|----------------|-------------------|
| 1 GB | 2 MB | 10-20 ms |
| 8 GB | 16 MB | 80-160 ms |
| 24 GB | 48 MB | 240-480 ms |
| 64 GB | 128 MB | 640-1280 ms |

These estimates assume 4KB pages, 8-byte pointers, and 10-20ms per GB on modern
hardware. VMs without hardware-assisted virtualization can be 5-10x worse.
Provision based on peak memory usage, not average.

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

## Valkey 8.0 Cluster Mode Memory Savings

Two automatic optimizations in 8.0 that require no configuration changes:

1. **Dictionary per slot** - Replaces the single global dictionary with 16,384
   per-slot dictionaries, saving 16 bytes per key (no more slot-prev/slot-next
   pointers). Rehashing is localized to individual slot dictionaries.

2. **Key embedding** - Keys are embedded directly into dictionary entries instead
   of a separate SDS pointer, saving 8 bytes per key and eliminating one random
   pointer dereference per lookup.

Measured savings (6.3M keys, 16-byte values):

| Version | Memory Used | Savings |
|---------|------------|---------|
| Valkey 7.2 | 693.64 MB | baseline |
| + Dict per slot | 598.77 MB | -13.68% |
| + Key embedding (Valkey 8.0) | 550.56 MB | **-20.63% total** |

These savings apply only in cluster mode. Standalone mode benefits from key
embedding but not the per-slot dictionary change.

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

### Hash Bucketing for Extreme Density

For millions of simple key-value pairs, group keys into hash buckets so each
hash stays under the listpack threshold:

```bash
# Instead of: SET media:1234 <user_id>
# Use: HSET mediabucket:1 234 <user_id>
# Bucket key = id / 1000, field = id % 1000
```

Instagram Engineering case study: storing 300M key-value pairs, naive
`SET media:<id> <user_id>` consumed ~70MB per 1M keys (21GB total). Switching
to hash bucketing reduced memory to ~16MB per 1M keys (5GB total) - a 4x
reduction. This works because small hashes use listpack encoding that is
5-10x more memory efficient than individual top-level keys.

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
CONFIG SET activedefrag yes
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
- [Latency Diagnosis](latency.md) - memory-related latency (fork, eviction, expiration)
- [Troubleshooting OOM](../troubleshooting/oom.md) - OOM diagnosis and resolution
- [Diagnostics Reference](../troubleshooting/diagnostics.md) - MEMORY DOCTOR, MEMORY STATS commands
- [Encoding Thresholds](../configuration/encoding.md) - detailed encoding threshold reference
- [Eviction Policies](../configuration/eviction.md) - policy selection and LFU tuning
- [Lazy Free](../configuration/lazyfree.md) - async free configuration
- [Capacity Planning](../operations/capacity-planning.md) - memory sizing guidelines
- [Monitoring Metrics](../monitoring/metrics.md) - `used_memory`, `mem_fragmentation_ratio` metrics
- [Kubernetes StatefulSets](../kubernetes/statefulset.md) - memory resource sizing and fork headroom in containers
- [Kubernetes Tuning](../kubernetes/tuning-k8s.md) - THP and overcommit settings in K8s
- [See valkey-dev: zmalloc](../../../valkey-dev/reference/memory/zmalloc.md) - per-thread memory counters, jemalloc integration
- [See valkey-dev: defragmentation](../../../valkey-dev/reference/memory/defragmentation.md) - active defrag internals
- [See valkey-dev: lazy-free](../../../valkey-dev/reference/memory/lazy-free.md) - asynchronous object freeing
