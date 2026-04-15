# Persistence Best Practices

Use when choosing a persistence strategy for your application, understanding durability guarantees, or evaluating how persistence affects application latency.

## What Application Developers Need to Know

Persistence is an operational concern, but affects applications in two ways:

1. **Durability guarantees** - how much data you can lose on a crash
2. **Latency impact** - how persistence operations affect request latency

Configuration is the ops team's job, but developers need to understand the trade-offs.

---

## Persistence Strategies at a Glance

| Strategy | Max Data Loss | Latency Impact | Best For |
|----------|--------------|----------------|----------|
| None | Everything since last restart | None | Pure ephemeral cache |
| RDB only | Minutes (between snapshots) | Periodic fork pauses | Non-critical cache with recovery |
| AOF `everysec` | ~2 seconds worst case | Low (background fsync) | Most applications |
| AOF `always` | Single command | High (fsync per write) | Financial data, critical writes |
| RDB + AOF (hybrid) | ~2 seconds worst case | Low | Production recommended |

---

## RDB (Point-in-Time Snapshots)

RDB creates a compact binary snapshot of the entire dataset at intervals (e.g., every 5 minutes if 100+ keys changed).

### What Developers Should Know

**Durability**: Data written between snapshots is lost on crash. RDB saving every 5 minutes means up to 5 minutes of writes can be lost.

**Latency**: RDB uses `fork()` to create a child process for the snapshot. The fork itself is fast (1-2 ms per GB of dataset), but:

- During the fork, all clients experience a brief pause
- The child process uses copy-on-write (COW) memory. Write-heavy workloads during the snapshot can temporarily double memory usage
- On large datasets (64 GB+), fork pauses can reach hundreds of milliseconds

**Restart speed**: Fast. RDB is a compact binary format optimized for loading.

### When RDB Is Enough

- Cache that can be regenerated from a database
- Non-critical data where minutes of loss are acceptable
- Batch jobs or analytics where data is periodically refreshed

---

## AOF (Append-Only File)

AOF logs every write command to disk. On restart, Valkey replays the log to reconstruct the dataset.

### Fsync Policies

The fsync policy controls how often data is flushed from OS buffers to disk:

| Policy | What Happens | Max Data Loss | Your Application Feels |
|--------|-------------|---------------|----------------------|
| `everysec` | Background thread fsyncs once per second | ~2 seconds | Minimal impact (default) |
| `always` | Fsync after every write command | Near zero | Every write waits for disk |
| `no` | OS decides when to flush | Up to 30 seconds | No impact |

**`everysec` fine print**: If a background fsync takes longer than 1 second (e.g., disk contention during AOF rewrite), the main thread delays writes for up to 1 additional second. Worst case is 2 seconds of data loss, not 1 second.

**`always` mode**: Near-zero data loss but significantly reduces write throughput. On rotational disk, expect ~1000 writes/second. SSDs improve this substantially. Only use when the application cannot tolerate any data loss.

### When to Use AOF

- Primary data store (not just a cache)
- Session storage where loss means user disruption
- Queue workloads where message loss is unacceptable
- Any workload where you need sub-minute durability

---

## Hybrid Persistence (Recommended)

The recommended production configuration combines RDB and AOF:

```
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes    # Default: yes
save 3600 1 300 100 60 10000
```

This gives you:
- **Fast restarts** - the AOF base file is in RDB format (loads quickly)
- **High durability** - incremental AOF captures recent writes
- **Compact backups** - RDB snapshots for off-site backup

On startup, Valkey loads the AOF (which is more complete) when both AOF and RDB files exist.

---

## How Persistence Affects Your Application Latency

### Fork Pauses

Both RDB snapshots and AOF rewrites use `fork()`. Fork time depends on dataset size:

| Dataset Size | Approximate Fork Time |
|-------------|----------------------|
| 1 GB | 1-2 ms |
| 10 GB | 10-20 ms |
| 24 GB | 24-48 ms |
| 64 GB | 64-128 ms |

During a fork, all client commands are paused. For latency-sensitive applications with large datasets, this matters.

### Copy-on-Write Memory

After fork, the child shares memory pages with the parent using copy-on-write (COW). Every page modified by the parent during the snapshot must be duplicated.

- **Read-heavy workload during snapshot**: Near-zero COW overhead
- **Moderate writes**: 10-30% additional memory
- **Heavy writes**: Up to 2x memory usage

For write-heavy workloads, ensure the deployment has memory headroom for COW. Otherwise, the OS may kill the Valkey process or the server may reject writes.

### Fsync Latency

With `appendfsync everysec`, you rarely notice. With `appendfsync always`, every write command includes disk I/O. Profile your write paths if using `always`.

---

## Application-Level Durability Decisions

### Pattern: Critical Writes with Confirmation

For operations where data loss is unacceptable, use `WAIT` to confirm replication:

```
SET order:5678:status "confirmed"
WAIT 1 5000    # Wait for 1 replica to acknowledge, timeout 5 seconds
# Returns: number of replicas that acknowledged
```

`WAIT` guarantees the write reached replica memory, not disk. Combine with AOF on replicas for full durability.

### Pattern: Two-Tier Durability

Use different TTLs and persistence strategies for different data types in the same instance:

- **Hot cache data**: Short TTL, acceptable to lose. No special handling.
- **Session data**: Medium TTL, loss causes user disruption. Ensure AOF `everysec` at minimum.
- **Persistent state**: No TTL, loss is unacceptable. Consider AOF `always` or external database as source of truth.

### Pattern: Valkey as Cache with Database Backing

Treat Valkey as a read-through/write-through cache backed by a durable database. On cache miss, read from the database. On write, write to both.

Persistence configuration then only affects restart time - not data safety.

---

## What to Ask Your Ops Team

If someone else manages Valkey, ask:

1. **What persistence is configured?** (RDB, AOF, hybrid, none)
2. **What is the fsync policy?** (`everysec` vs `always`)
3. **How much data can I lose on a crash?** (Derive from #1 and #2)
4. **How large is the dataset?** (Determines fork latency impact)
5. **Is `maxmemory` set?** (If not, OOM risk)
6. **Are replicas configured?** (For additional durability via `WAIT`)

---

