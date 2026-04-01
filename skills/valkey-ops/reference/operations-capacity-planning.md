# Capacity Planning

Use when sizing Valkey instances, planning memory allocation, estimating connection requirements, or deciding when to scale a cluster. All config defaults verified against `src/config.c` in valkey-io/valkey.

## Contents

- Memory Per Key Type (line 19)
- `maxmemory` vs System RAM (line 63)
- Client Output Buffer Planning (line 143)
- Connection Count Planning (line 190)
- Cluster Sizing (line 245)
- Capacity Planning Checklist (line 296)

---

## Memory Per Key Type

These are approximate per-key overhead estimates. Actual usage depends on key
name length, value size, and encoding thresholds.

### Base Overhead

Every key in Valkey has a fixed overhead regardless of type:

| Component | Bytes | Notes |
|-----------|-------|-------|
| dictEntry (hash table entry) | 24-32 | Pointer to key, value, next |
| robj (value object header) | 16 | Type, encoding, refcount, LRU/LFU |
| SDS key string | 9 + len | SDS header (3-9 bytes) + string + null terminator |
| Expire entry (if TTL set) | 24-32 | Additional dict entry for expires table |

**Minimum per-key overhead**: ~50-80 bytes before any value data.

### Value Size Estimates

| Type | Small Value | Large Value | Notes |
|------|------------|-------------|-------|
| String | 50 + len bytes | 50 + len bytes | Integers < 10000 share global objects (0 extra) |
| List | ~200 + (entries * ~70) | Varies with encoding | Listpack under 128 entries / 64 bytes each |
| Set | ~200 + (entries * ~70) | ~240 + (entries * ~80) | Listpack for small sets, hashtable for large |
| Hash | ~200 + (entries * ~70) | ~240 + (entries * ~80) | Listpack under 512 fields / 64 bytes each |
| Sorted Set | ~200 + (entries * ~70) | ~300 + (entries * ~120) | Listpack for small, skiplist+dict for large |
| Stream | ~200 + varies | ~200 + varies | Radix tree of listpacks |

### Practical Examples

| Use Case | Key Pattern | Estimated Memory |
|----------|------------|-----------------|
| Session store (500-byte JSON) | 1M keys, string values | ~600MB |
| User profiles (10 hash fields, 50-byte values) | 1M keys | ~1.2GB |
| Leaderboard (10K members) | 1 sorted set | ~1.5MB |
| Rate limiter (counter per user) | 1M keys, integer values | ~80MB |
| Cache (1KB values, 50% with TTL) | 1M keys | ~1.1GB |

Use `MEMORY USAGE <key>` to measure actual per-key memory and
`INFO memory` for aggregate stats.

---

## `maxmemory` vs System RAM

### The Core Rule

**Set `maxmemory` to 60-70% of available RAM.**

The remaining 30-40% accounts for:

| Consumer | Typical Usage | Notes |
|----------|--------------|-------|
| OS and kernel | 1-2 GB | File cache, page tables, networking |
| Fork COW (copy-on-write) | Up to 100% of used memory | During BGSAVE or BGREWRITEAOF |
| Client output buffers | `maxclients` * buffer limits | See below |
| Client query buffers | Up to 1GB per client (default) | `client-query-buffer-limit` default: 1GB |
| Replication buffers | `repl-backlog-size` + per-replica | Default backlog: 10MB |
| Lua/Function memory | Varies | Script caching and execution |
| Fragmentation overhead | 10-30% | Depends on allocator and workload |

Source reference: `maxmemory` at line 3442, default `0` (unlimited).

### Fork COW Reality

When Valkey forks for BGSAVE or AOF rewrite:
- Linux uses copy-on-write - pages are shared until modified
- Write-heavy workloads during fork can duplicate most pages
- Worst case: fork doubles memory usage temporarily
- `disable-thp yes` (default) helps reduce COW amplification

**Page table overhead formula**: `page_table_size = dataset_size / 4KB * 8 bytes`. A 24 GB instance requires a 48 MB page table, allocated during fork.

**COW memory ranges by write pattern:**

| Write Pattern | Additional Memory During Fork | Example (8 GB dataset) |
|---------------|------------------------------|------------------------|
| Read-heavy | Near-zero | ~0 GB extra |
| Moderate writes | 10-30% | 0.8-2.4 GB extra |
| Write-heavy | Up to 100% | Up to 8 GB extra |

With THP enabled, COW granularity jumps from 4KB to 2MB pages. A single
byte change in a 2MB page causes the entire page to be copied, turning
moderate COW overhead into near-total memory duplication.

**Conservative sizing**: If `maxmemory` = 8GB on a 16GB host, a fork during
heavy writes could temporarily need 16GB. This is why 60% is safer than 70%
for write-heavy workloads.

### Sizing Examples

| System RAM | Workload | Recommended `maxmemory` |
|-----------|----------|----------------------|
| 8 GB | Read-heavy cache | 5-5.5 GB (65-70%) |
| 8 GB | Write-heavy + persistence | 4-4.8 GB (50-60%) |
| 32 GB | Mixed, RDB snapshots | 20-22 GB (63-69%) |
| 64 GB | Read-heavy, no persistence | 44-45 GB (69-70%) |
| 64 GB | Write-heavy, AOF + RDB | 38-40 GB (59-63%) |

### Monitoring Memory Headroom

```
INFO memory
```

Key fields:
- `used_memory` - total allocated by Valkey
- `used_memory_rss` - resident set size (what the OS sees)
- `mem_fragmentation_ratio` - RSS / used_memory (healthy: 1.0-1.5)
- `used_memory_peak` - historical peak
- `maxmemory` - configured limit

Alert when `used_memory_rss` > 80% of system RAM.

---

## Client Output Buffer Planning

Each client class has independent buffer limits. Plan memory accordingly.

| Class | Hard Limit | Soft Limit | Seconds | Source |
|-------|-----------|------------|---------|--------|
| normal | `0` (unlimited) | `0` | `0` | Line 182: `{0, 0, 0}` |
| replica | `256mb` | `64mb` | `60` | Line 183: `{256MB, 64MB, 60}` |
| pubsub | `32mb` | `8mb` | `60` | Line 184: `{32MB, 8MB, 60}` |

Worst-case buffer memory calculation:

```
normal_clients * (no hard limit - monitor with CLIENT LIST)
+ replica_count * 256MB
+ pubsub_subscribers * 32MB
```

For a server with 500 clients, 3 replicas, and 100 pub/sub subscribers:

```
Replica buffers:  3 * 256MB  =  768MB
Pub/sub buffers: 100 * 32MB  = 3200MB (worst case)
Normal clients: monitor individually
```

`client-query-buffer-limit` defaults to 1GB per client. A misbehaving
client can consume significant memory with a single large pipeline. Use
`maxmemory-clients 5%` to cap aggregate client buffer memory.

Factor these into your `maxmemory` calculation.

### Total Memory Accounting

```
Total required = maxmemory
               + fork COW headroom (30-100% of `maxmemory`)
               + replica output buffers (N * 256MB)
               + pubsub output buffers (subscribers * 32MB)
               + client query buffers (varies)
               + replication backlog (default 10MB)
               + fragmentation overhead (10-30%)
               + OS/kernel (1-2 GB)
```

---

## Connection Count Planning

### maxclients

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxclients` | `10000` | Maximum simultaneous connections. |

Source reference: line 3409, default `10000`.

Valkey reserves 32 file descriptors for internal use. The actual limit is
`min(maxclients, OS_fd_limit - 32)`.

### Sizing Guidelines

| Deployment | Expected Connections | Recommended `maxclients` |
|-----------|---------------------|----------------------|
| Single app, connection pool | 10-50 | 1000 (comfortable margin) |
| Multiple apps, pools | 50-500 | 2000-5000 |
| Microservices (many small pools) | 500-5000 | 10000 (default) |
| Public-facing (proxy tier) | 5000+ | 20000-65000 |

### Connection Pool Sizing

A general formula for pool size per application instance:

```
pool_size = (request_rate / requests_per_second_per_connection) + headroom
```

Rules of thumb:
- Most Valkey commands complete in < 1ms
- One connection can handle ~1000-5000 commands/sec (pipelining helps)
- Start with `pool_size = CPU cores * 2` per app instance
- Total across all app instances must be well under `maxclients`

### OS File Descriptor Tuning

If `maxclients` > 10000, ensure the OS limit supports it:

```bash
# Check current limit
ulimit -n

# Set in /etc/security/limits.conf
valkey soft nofile 65536
valkey hard nofile 65536

# Or in systemd unit
[Service]
LimitNOFILE=65536
```

---

## Cluster Sizing

### Slots Per Node

Valkey Cluster has 16,384 hash slots distributed across primary nodes.

| Primary Count | Slots Per Node | Notes |
|---------------|---------------|-------|
| 3 | ~5,461 | Minimum viable cluster |
| 6 | ~2,730 | Good balance |
| 12 | ~1,365 | Large dataset |
| 24 | ~682 | Very large dataset |

### When to Add Nodes

| Signal | Threshold | Action |
|--------|-----------|--------|
| Memory per node | > 60% of `maxmemory` | Add nodes or increase instance size |
| CPU usage | > 70% sustained | Add nodes to distribute load |
| Network throughput | > 80% of NIC capacity | Add nodes |
| Slot migration time | > 30 minutes for rebalance | Smaller nodes = faster migration |
| Command latency (p99) | > 10ms sustained | Investigate before adding nodes |

### Node Size Recommendations

| Instance Memory | Max Dataset Per Node | Rationale |
|----------------|---------------------|-----------|
| 8 GB | ~5 GB | Fast fork, fast replication |
| 16 GB | ~10 GB | Good balance for most workloads |
| 32 GB | ~20 GB | Larger fork times, plan maintenance windows |
| 64 GB+ | ~40 GB | Long fork times - consider RDB-less replication |

Smaller nodes are preferred because:
- Faster BGSAVE and AOF rewrite (less data to fork)
- Faster failover (less data to replicate)
- Faster slot migration when rebalancing
- Lower blast radius on node failure

### Replica Planning

| Topology | Replicas Per Primary | Use Case |
|----------|---------------------|----------|
| 1 replica | 1 | Development, non-critical |
| 2 replicas | 2 | Production - survive 1 failure + have read capacity |
| 3 replicas | 3 | High availability with read scaling |

Total nodes = primaries * (1 + replicas_per_primary).
Example: 6 primaries with 2 replicas each = 18 nodes.

---

## Capacity Planning Checklist

1. **Estimate dataset size**: Key count * average memory per key (use MEMORY USAGE on samples)
2. **Set `maxmemory`**: 60-70% of instance RAM (lower for write-heavy + persistence)
3. **Account for buffers**: Replica buffers + pub/sub buffers + client query buffers
4. **Account for fork COW**: Reserve 30-50% headroom for BGSAVE/AOF rewrite
5. **Size connections**: Sum all client pools, ensure well under maxclients
6. **Tune OS limits**: File descriptors, somaxconn, overcommit_memory
7. **Plan cluster slots**: Prefer more smaller nodes over fewer large ones
8. **Set eviction policy**: Choose `maxmemory-policy` based on workload (see eviction.md)
9. **Monitor continuously**: Alert on `used_memory_rss` > 80% of system RAM
10. **Test with realistic data**: Use `DEBUG POPULATE` or real datasets to validate estimates
