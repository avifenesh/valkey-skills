# Performance Improvements Summary

Use when evaluating Valkey's performance characteristics or understanding what version-specific optimizations benefit your application without configuration changes.

---

Performance figures below are from Valkey project benchmarks and release notes. Actual improvements depend on workload characteristics, hardware, and configuration. See the linked Valkey release notes for methodology details.

## Contents

- Version-by-Version Performance Changes (line 17)
- What Application Developers Get for Free (line 51)
- What Requires Configuration (line 82)
- Application-Side Optimizations (line 111)

## Version-by-Version Performance Changes

### Valkey 8.0

| Feature | Impact | Detail |
|---------|--------|--------|
| I/O multithreading overhaul | 3x throughput (360K -> 1.2M RPS) | I/O threads handle read/parse/write; main thread handles command execution |
| Command batching | Reduced CPU cache misses | Commands grouped for better cache locality |
| Dual-channel replication | Faster replica sync | RDB transfer and replication stream run in parallel |

### Valkey 8.1

| Feature | Impact | Detail |
|---------|--------|--------|
| New hashtable implementation | 20-30 bytes less memory per key | Open-addressing with 64-byte buckets, SIMD probing |
| Iterator prefetching | 3.5x faster iteration | SCAN, KEYS, HGETALL, and similar commands benefit |
| TLS offload to I/O threads | 300% faster TLS connection acceptance | TLS handshake no longer blocks main thread |
| ZRANK optimization | 45% faster | Optimized skiplist traversal |
| BITCOUNT (AVX2) | 514% faster | SIMD-accelerated bit counting |
| PFMERGE/PFCOUNT (AVX) | 12x faster | SIMD-accelerated HyperLogLog operations |

### Valkey 9.0

| Feature | Impact | Detail |
|---------|--------|--------|
| Pipeline memory prefetch | Up to 40% higher throughput | Batch key prefetching for pipelined commands |
| Zero-copy responses | Up to 20% higher throughput for large values | Eliminates buffer copies for read-heavy workloads |
| SIMD BITCOUNT/HLL | Up to 200% higher throughput | Further SIMD improvements over 8.1 |
| Multipath TCP (MPTCP) | Up to 25% latency reduction | Multiple network paths for a single connection |
| Atomic slot migration | Faster resharding | Bulk transfer instead of key-by-key |
| 1 billion RPS at scale | Cluster benchmark | Across 2,000 cluster nodes |

---

## What Application Developers Get for Free

These improvements require no application code changes. They take effect when you upgrade Valkey:

### Transparent throughput gains

- Higher ops/sec at the same connection count
- Lower p99 latency under load
- Better multi-core utilization (I/O threading)

### Transparent memory savings

- Smaller per-key memory footprint (8.1 hashtable)
- More efficient encoding of small collections (listpack improvements)
- Better memory fragmentation handling

### Faster specific commands

Applications using these operations see immediate speedups:

| Command | Improvement | Version |
|---------|------------|---------|
| `BITCOUNT` | 5-7x faster | 8.1+ |
| `PFCOUNT` / `PFMERGE` | 12x faster | 8.1+ |
| `ZRANK` / `ZREVRANK` | 45% faster | 8.1+ |
| `SCAN` / `HSCAN` / `SSCAN` / `ZSCAN` | 3.5x faster | 8.1+ |
| Pipelined commands | 40% higher throughput | 9.0+ |
| Large value reads | 20% higher throughput | 9.0+ |

---

## What Requires Configuration

Some improvements need operator-side configuration to take full effect. Coordinate with your ops team or see the valkey-ops skill for details.

### I/O threading

Default is 1 (main thread only, no separate I/O threads). For high-throughput workloads:

```
io-threads 4        # Main + 3 I/O threads (good starting point)
io-threads 9        # Main + 8 I/O threads (dedicated high-throughput hardware)
```

Requires available CPU cores. The main thread still handles command execution (single-threaded), so this scales I/O, not computation.

### TLS offload (8.1+)

TLS handshake is offloaded to I/O threads automatically when `io-threads > 1`. No additional configuration needed beyond setting `io-threads`.

### Multipath TCP (9.0+)

Requires kernel support and network configuration. When available, Valkey uses MPTCP automatically. This benefits deployments with multiple network interfaces.

### Pipeline prefetch (9.0+)

Enabled automatically for pipelined commands. Applications that already use pipelining get the benefit with no changes. Applications that do NOT pipeline should consider adding it - the gains are significant.

---

## Application-Side Optimizations

These are not Valkey version-specific but work well with all versions and compound with server-side improvements:

### Pipelining

Send multiple commands in one batch. Up to 10x throughput improvement at the application level, further amplified by server-side pipeline prefetch in 9.0.

```
# Without pipelining: N round-trips
SET key1 val1  -> OK
SET key2 val2  -> OK

# With pipelining: 1 round-trip
[SET key1 val1, SET key2 val2] -> [OK, OK]
```

Recommended batch size: ~10,000 commands per batch.

### Connection pooling

Reuse connections instead of creating per-request. Or use Valkey GLIDE, which uses a single multiplexed connection per node with auto-pipelining - no pool management needed.

### Client-side caching

Use `CLIENT TRACKING` to cache frequently-read keys locally. The server sends invalidation messages when tracked keys change, eliminating network round-trips entirely.

---

