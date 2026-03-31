# Active Defragmentation

Use when memory fragmentation ratio is high, Valkey is consuming more RSS than
expected, or you want to reclaim memory without restarting.

## Contents

- What It Is (line 18)
- Configuration (line 30)
- Monitoring (line 74)
- Common Causes of Fragmentation (line 109)
- When to Use vs When to Restart (line 131)
- Operational Notes (line 153)
- See Also (line 165)

---

## What It Is

Over time, allocations and deallocations create gaps in memory (external
fragmentation). Valkey's active defragmentation scans the keyspace and asks
jemalloc to relocate allocations into contiguous regions, reducing RSS without
any data loss or downtime.

Active defrag requires jemalloc (the default allocator). It is not available
when Valkey is compiled with libc malloc or tcmalloc. The source guards this
behind `HAVE_DEFRAG` (defined in `src/allocator_defrag.h` and set via
`CMakeLists.txt` when jemalloc is detected).

## Configuration

All defaults source-verified from `src/config.c`:

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `activedefrag` | `no` | yes/no | Main toggle. Default is `no` in production builds (`CONFIG_ACTIVE_DEFRAG_DEFAULT` = 0 in `src/server.h` line 166). |
| `active-defrag-threshold-lower` | `10` | 0-1000 | Fragmentation percentage below which defrag does not start. |
| `active-defrag-threshold-upper` | `100` | 0-1000 | Fragmentation percentage at which defrag runs at maximum CPU effort. |
| `active-defrag-cycle-min` | `1` | 1-99 | Minimum CPU percentage used for defrag (at lower threshold). |
| `active-defrag-cycle-max` | `25` | 1-99 | Maximum CPU percentage used for defrag (at upper threshold). |
| `active-defrag-cycle-us` | `500` | 0-100000 | Base duty cycle in microseconds when wait time is unknown. |
| `active-defrag-max-scan-fields` | `1000` | 1-LONG_MAX | Keys with more fields than this are processed in a separate stage. |
| `active-defrag-ignore-bytes` | `104857600` (100 MB) | 1-LLONG_MAX | Defrag does not start if fragmentation overhead is below this byte count. |

### How CPU Effort Scales

The defrag engine interpolates between `cycle-min` and `cycle-max` based on
the current fragmentation percentage relative to the lower/upper thresholds.
From `src/defrag.c` (`updateDefragCpuPercent`):

- At `threshold-lower` (10%) fragmentation: uses `cycle-min` (1%) CPU
- At `threshold-upper` (100%) fragmentation: uses `cycle-max` (25%) CPU
- Between thresholds: linearly interpolated
- Below `threshold-lower` or below `ignore-bytes`: defrag does not start

### Enabling at Runtime

```bash
# Enable defrag
valkey-cli CONFIG SET activedefrag yes

# Tune for aggressive defrag (high-memory, can spare CPU)
valkey-cli CONFIG SET active-defrag-cycle-min 5
valkey-cli CONFIG SET active-defrag-cycle-max 75
valkey-cli CONFIG SET active-defrag-threshold-lower 5

# Tune for gentle defrag (latency-sensitive)
valkey-cli CONFIG SET active-defrag-cycle-min 1
valkey-cli CONFIG SET active-defrag-cycle-max 15
```

All parameters are modifiable at runtime via `CONFIG SET`.

## Monitoring

### Key Metrics

From `INFO memory` and `INFO stats` (source-verified from `src/server.c`):

| Metric | Section | Meaning |
|--------|---------|---------|
| `mem_fragmentation_ratio` | memory | RSS / used_memory. Values above 1.5 indicate significant fragmentation. |
| `active_defrag_running` | memory | Current CPU percentage being used (0 if not running). |
| `active_defrag_hits` | stats | Total allocations successfully relocated. |
| `active_defrag_misses` | stats | Total allocations scanned but not moved (already optimal). |
| `active_defrag_key_hits` | stats | Keys that had at least one allocation relocated. |
| `active_defrag_key_misses` | stats | Keys scanned where no relocation was needed. |

### Checking Current State

```bash
# Quick fragmentation check
valkey-cli INFO memory | grep -E "mem_fragmentation|active_defrag"

# Watch defrag progress
valkey-cli INFO stats | grep active_defrag
```

### Interpreting mem_fragmentation_ratio

| Ratio | Interpretation | Action |
|-------|---------------|--------|
| < 1.0 | Swap is being used. Critical. | Increase RAM or reduce maxmemory. |
| 1.0 - 1.1 | Healthy | No action needed. |
| 1.1 - 1.5 | Normal fragmentation | Monitor. Enable defrag if trending up. |
| 1.5 - 2.0 | Significant fragmentation | Enable active defrag. |
| > 2.0 | Severe fragmentation | Enable aggressive defrag or consider restart. |

## Common Causes of Fragmentation

1. **Delete-heavy workloads** - Filling 5GB then deleting 2GB leaves RSS at
   ~5GB while `used_memory` shows ~3GB. The allocator keeps freed pages for
   future reuse but the OS sees them as allocated.
2. **Variable-size key churn** - Repeatedly creating and deleting keys of
   different sizes fragments jemalloc's size classes.
3. **Large key deletion** - Deleting a 1GB sorted set returns memory in small
   chunks, creating fragmentation across multiple size classes.
4. **Listpack-to-hashtable conversions** - When collections exceed
   `*-max-listpack-entries`, the compact encoding converts to a full hash
   table, fragmenting the memory that held the original listpack.

### Recovery for Extreme Fragmentation

If fragmentation ratio exceeds 2.0 and active defrag is insufficient:
1. Enable aggressive defrag settings (cycle-max 25-50).
2. If ratio exceeds 3.0, consider a rolling restart: failover to replica,
   restart the old primary (fresh memory layout), then failover back.
3. For persistent fragmentation, review workload patterns - high delete rates
   with variable sizes are the primary cause.

## When to Use vs When to Restart

**Use active defrag when:**

- You cannot afford downtime for a restart
- Fragmentation is moderate (1.5 - 2.5)
- You have spare CPU headroom
- The instance is a primary with replicas (restart causes full resync)

**Consider restart instead when:**

- Fragmentation is extreme (> 3.0) - defrag may take too long
- The instance is a replica that can be rebuilt quickly
- You are running a version without jemalloc
- CPU headroom is zero and latency is already critical

**Restart approach:**

1. If using replication, promote a replica, restart the old primary, resync
2. If standalone, ensure persistence is enabled, restart, let data reload
3. After restart, fragmentation ratio resets to near 1.0

## Operational Notes

- Defrag runs as a timer event in the main thread. It yields periodically to
  avoid blocking command processing, but it does consume CPU cycles.
- The `active-defrag-cycle-us` parameter controls the base duty cycle duration.
  The actual duty cycle adapts based on measured wait time between invocations.
- Large keys (with more fields than `active-defrag-max-scan-fields`) are
  processed in a dedicated stage to avoid long pauses.
- Defrag cycles are logged at `verbose` log level with duration and hit count.
- After a cycle completes, defrag immediately checks if another cycle is
  needed (fragmentation may have changed during the scan).

## See Also

- [Memory Optimization](memory.md) - encoding thresholds, maxmemory tuning
- [Latency Diagnosis](latency.md) - diagnosing defrag-related latency spikes
- [Troubleshooting OOM](../troubleshooting/oom.md) - fragmentation as OOM contributor
- [Monitoring Metrics](../monitoring/metrics.md) - `mem_fragmentation_ratio`, `active_defrag_running`
- [Monitoring Alerting](../monitoring/alerting.md) - fragmentation alert rules
- [See valkey-dev: defragmentation](../../../valkey-dev/reference/memory/defragmentation.md) - allocator interaction, jemalloc purging, scan stages
