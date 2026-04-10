# Memory Fragmentation and Active Defragmentation

Use when Valkey is consuming more memory than expected, `INFO memory` shows a high fragmentation ratio, or you need to understand whether active defrag should be enabled for your workload.

## Contents

- What Memory Fragmentation Is (line 13)
- Reading Fragmentation Metrics (line 38)
- Active Defragmentation (line 76)
- When NOT to Enable Defrag (line 126)
- Diagnosing Memory Issues from Application Code (line 140)
- Valkey Version Changes (line 179)

---

## What Memory Fragmentation Is

Valkey uses jemalloc as its memory allocator. jemalloc organizes memory into arenas, each containing size-class bins (8 bytes, 16 bytes, 32 bytes, etc.). When your application creates and deletes keys of varying sizes over time, freed memory leaves gaps within jemalloc's pages. A page with even one live allocation cannot be returned to the OS.

This creates a divergence between two numbers:

- **used_memory** - bytes Valkey has actively allocated for your data
- **used_memory_rss** - bytes the OS reports the process is using (RSS)

The gap between them is fragmentation overhead. Your data might use 4 GB, but the process holds 6 GB of RSS because of gaps that jemalloc cannot consolidate.

### Two Levels of Fragmentation

**Allocation-level fragmentation** happens within jemalloc's bins. A 50-byte string occupies a 64-byte bin slot - those 14 wasted bytes are internal fragmentation. This is usually small and unavoidable.

**Page-level fragmentation** is the real problem. When you delete keys, jemalloc frees the slots but cannot return the page to the OS if any slot on that page is still in use. This is external fragmentation, and it causes RSS to grow far beyond used_memory.

The most common cause is **delete-heavy or key-churn workloads** - filling a cache to 5 GB, evicting or expiring 2 GB, then writing new keys of different sizes. The RSS stays near 5 GB even though used_memory shows 3 GB.

---

## Reading Fragmentation Metrics

Run `INFO memory` and inspect these fields:

```
127.0.0.1:6379> INFO memory

used_memory:3221225472          # 3 GB actively used by data
used_memory_rss:5368709120      # 5 GB held by the OS process
mem_fragmentation_ratio:1.67    # RSS / used_memory
mem_fragmentation_bytes:2147483648  # Absolute overhead in bytes

allocator_frag_ratio:1.42       # jemalloc allocated / active
allocator_frag_bytes:1342177280
allocator_rss_ratio:1.15        # RSS / jemalloc resident
allocator_rss_bytes:536870912
```

### Interpreting mem_fragmentation_ratio

| Ratio | Meaning | Action |
|-------|---------|--------|
| < 1.0 | Valkey is using swap. Performance is severely degraded. | Increase RAM or reduce maxmemory immediately. |
| 1.0 - 1.1 | Healthy. Minimal overhead. | No action needed. |
| 1.1 - 1.5 | Normal fragmentation. | Monitor. Most workloads sit here. |
| 1.5 - 2.0 | Significant fragmentation. | Consider enabling active defrag. |
| > 2.0 | Severe fragmentation. Substantial RAM waste. | Enable active defrag or coordinate a restart with ops. |

### Digging Deeper with allocator_frag_ratio and allocator_rss_ratio

`mem_fragmentation_ratio` is a blended number. The two sub-metrics tell you where the waste is:

- **allocator_frag_ratio** (jemalloc internal) - high values mean the allocator has many partially-used pages. Active defrag can fix this.
- **allocator_rss_ratio** (process to allocator) - high values mean the OS is holding pages that jemalloc has freed but the kernel has not reclaimed. This is not fixable by defrag - it resolves on its own or on restart.

---

## Active Defragmentation

Active defrag is a background process that scans your keyspace and relocates allocations from sparse jemalloc pages into denser ones, allowing empty pages to be returned to the OS. It runs on the main thread in small time slices, yielding frequently to avoid blocking commands.

### Configuration

```
# Enable defrag (default: no)
CONFIG SET activedefrag yes

# Start defrag when fragmentation exceeds this percentage (default: 10%)
CONFIG SET active-defrag-threshold-lower 10

# Run at maximum CPU effort above this percentage (default: 100%)
CONFIG SET active-defrag-threshold-upper 100

# Minimum CPU percentage used for defrag (default: 1%)
CONFIG SET active-defrag-cycle-min 1

# Maximum CPU percentage used for defrag (default: 25%)
CONFIG SET active-defrag-cycle-max 25

# Only start if fragmentation overhead exceeds this byte count (default: 100 MB)
CONFIG SET active-defrag-ignore-bytes 104857600
```

### How the CPU Budget Works

Defrag CPU effort scales linearly between the lower and upper thresholds:

- At 10% fragmentation (lower threshold): uses 1% CPU (cycle-min)
- At 55% fragmentation (midpoint): uses ~13% CPU
- At 100% fragmentation (upper threshold): uses 25% CPU (cycle-max)
- Below the lower threshold or below ignore-bytes: defrag does not run

### What Application Developers Should Know

- **No data loss or downtime.** Defrag relocates data in-place. Your application does not notice.
- **Slight latency impact.** Defrag consumes CPU cycles on the main thread. At cycle-max 25%, you may see p99 latency increase by a few percent during heavy defrag.
- **It pauses during persistence.** When a background save (RDB or AOF rewrite) is running, defrag stops to avoid increasing copy-on-write overhead.
- **It requires jemalloc.** If your deployment uses a different allocator (unlikely in standard Valkey packages), defrag is unavailable.

### Monitoring Defrag Progress

```
127.0.0.1:6379> INFO memory
active_defrag_running:12        # Current CPU % being used (0 if idle)

127.0.0.1:6379> INFO stats
active_defrag_hits:28493021     # Allocations successfully relocated
active_defrag_misses:142982112  # Allocations scanned but already optimal
active_defrag_key_hits:5920302  # Keys with at least one relocation
active_defrag_key_misses:31002  # Keys scanned with no action needed
```

---

## When NOT to Enable Defrag

Active defrag is not always beneficial. Skip it when:

- **Small instances (< 1 GB used_memory)** - fragmentation overhead is negligible in absolute terms. A 1.5 ratio on 500 MB wastes only 250 MB.
- **Low-churn workloads** - if your key population is stable (few creates/deletes), fragmentation stays low naturally.
- **CPU-constrained deployments** - defrag competes with command execution on the main thread. If your instance is already CPU-bound, defrag makes latency worse.
- **Short-lived instances** - if the instance is restarted regularly (e.g., daily cache refresh), fragmentation resets on restart.
- **Fragmentation is in allocator_rss_ratio, not allocator_frag_ratio** - defrag fixes allocator-level fragmentation. If the waste is between the allocator and the OS, defrag cannot help.

---

## Diagnosing Memory Issues from Application Code

### MEMORY USAGE - Check a Specific Key

```
127.0.0.1:6379> MEMORY USAGE user:session:abc123
(integer) 296

127.0.0.1:6379> MEMORY USAGE user:session:abc123 SAMPLES 0
(integer) 128
```

Returns the number of bytes a key and its value consume, including overhead. The `SAMPLES` option controls how many elements are sampled for aggregate types (hashes, sets, sorted sets). `SAMPLES 0` returns only the top-level overhead without sampling elements - fast but less accurate.

Use this to find unexpectedly large keys:

```
# Scan for keys in a namespace and check their memory usage
valkey-cli --bigkeys
# Reports the largest key per data type
```

### MEMORY DOCTOR - Automated Diagnosis

```
127.0.0.1:6379> MEMORY DOCTOR
"Sam, I have a few things to report about the memory condition of your Valkey instance.
 High fragmentation (ratio: 1.78). Consider enabling activedefrag or restarting."
```

MEMORY DOCTOR checks several conditions:
- High fragmentation ratio
- Peak memory significantly above current usage
- Whether active defrag is running and effective

### MEMORY MALLOC-STATS - Allocator Internals

```
127.0.0.1:6379> MEMORY MALLOC-STATS
```

Dumps jemalloc's internal statistics. This is verbose output primarily for ops teams, but the "bins" section shows which size classes are fragmented. Look for bins where `nslabs` is high relative to `curregs` - those size classes have many partially-empty pages.

### Practical Investigation Flow

1. Check `INFO memory` for `mem_fragmentation_ratio`
2. If > 1.5, check `allocator_frag_ratio` vs `allocator_rss_ratio` to determine if defrag can help
3. Use `MEMORY USAGE` on your largest keys to find unexpectedly expensive data structures
4. Run `valkey-cli --bigkeys` to scan for oversized keys across all types
5. Check `OBJECT ENCODING <key>` on large collections - a hash using `hashtable` encoding when it could use `listpack` wastes memory (see memory best practices for encoding thresholds)
6. If defrag is warranted, coordinate with ops to enable it

---

## Valkey Version Changes

### Valkey 8.0

- Default allocator remains jemalloc with defrag support.
- No changes to defrag configuration defaults.
- The new hashtable implementation (landing in 8.1) reduces per-key overhead by 20-30 bytes, which indirectly reduces fragmentation by packing more data into fewer pages.

### Valkey 8.1

- New open-addressing hashtable with 64-byte bucket alignment. This improves memory density and reduces the number of small allocations that drive fragmentation.
- The combination of fewer allocations per key and SIMD-based probing means the keyspace generates less fragmentation under churn compared to the legacy dict-based hashtable.

### Valkey 9.0

- No changes to active defrag configuration or behavior.
- Zero-copy responses reduce temporary buffer allocations during reads, which marginally reduces allocation churn.

### General Guidance

For Valkey 8.1+, the improved hashtable implementation means many workloads that previously needed active defrag may no longer reach problematic fragmentation levels. Monitor `mem_fragmentation_ratio` after upgrading before deciding whether defrag is still needed.

---
