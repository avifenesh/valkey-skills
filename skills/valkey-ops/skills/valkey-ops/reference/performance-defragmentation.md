# Active Defragmentation

Use when `mem_fragmentation_ratio` is high and you want to reclaim RSS without restarting.

## Prerequisite

Jemalloc-only feature (`HAVE_DEFRAG` gated on `USE_JEMALLOC`). With libc or tcmalloc, `activedefrag yes` is silently a no-op. Linux builds default to jemalloc; verify:

```sh
valkey-cli INFO server | grep mem_allocator     # should be 'jemalloc'
```

## Config

| Parameter | Default | Notes |
|-----------|---------|-------|
| `activedefrag` | `no` | Main on/off switch. |
| `active-defrag-threshold-lower` | `10` (%) | Below this fragmentation %, defrag doesn't start. |
| `active-defrag-threshold-upper` | `100` (%) | At this %, defrag runs at max CPU. |
| `active-defrag-cycle-min` | `1` (%) | CPU % at lower threshold. |
| `active-defrag-cycle-max` | `25` (%) | CPU % at upper threshold. |
| `active-defrag-cycle-us` | `500` µs | **Valkey-specific.** Base duty-cycle duration; larger = more work per cycle, longer per-cycle stalls. |
| `active-defrag-max-scan-fields` | `1000` | Keys with more fields than this go through a separate staged pass. |
| `active-defrag-ignore-bytes` | `100 MB` | Don't start if fragmentation overhead is below this absolute byte count. |

CPU effort scales linearly between `cycle-min` and `cycle-max` as fragmentation goes from `threshold-lower` to `threshold-upper`. Below lower or below ignore-bytes, defrag is dormant. All parameters are runtime-modifiable.

## Runtime tuning profiles

```sh
# Aggressive - lots of RAM churn, CPU to spare
CONFIG SET active-defrag-cycle-min 5
CONFIG SET active-defrag-cycle-max 75
CONFIG SET active-defrag-threshold-lower 5

# Gentle - latency-sensitive
CONFIG SET active-defrag-cycle-min 1
CONFIG SET active-defrag-cycle-max 15
```

## Fragmentation ratio thresholds

`mem_fragmentation_ratio = used_memory_rss / used_memory`:

| Ratio | What it means |
|-------|---------------|
| < 1.0 | Swap is in use (check `used_memory` against peak, examine `smaps`). |
| 1.0-1.1 | Healthy. |
| 1.1-1.5 | Normal, watch the trend. |
| 1.5-2.0 | Enable active defrag. |
| > 2.0 | Aggressive defrag or plan a failover-restart cycle. |
| > 3.0 | Defrag may not keep up - restart via failover. |

## Metrics to watch

From `INFO memory` + `INFO stats`:

- `active_defrag_running` - current CPU % (0 when idle).
- `active_defrag_hits` / `active_defrag_misses` - allocations moved vs scanned-but-not-moved.
- `active_defrag_key_hits` / `active_defrag_key_misses` - per-key rollup.

A high ratio of misses to hits means defrag is scanning without finding relocatable allocations - drop threshold-lower or check if the fragmentation is actually swap (`mem_fragmentation_ratio < 1.0`).

## Workload patterns that fragment

- Large-key deletion (multi-GB sorted sets, hashes).
- Delete-heavy mixed workloads (churn fills + frees across size classes).
- Listpack → hashtable promotions (compact encoding freed, full encoding allocated in different size class).

## When a restart beats defrag

- Ratio > 3.0 and defrag can't keep up (observable: ratio not dropping over hours despite defrag running).
- Replica that can be rebuilt quickly from the primary.
- Instance is on libc/tcmalloc (no defrag possible at all).
- Zero CPU headroom and latency already critical - defrag adds CPU pressure on top.

Restart path for a replicated primary: promote a replica (`SENTINEL FAILOVER ... COORDINATED` or `CLUSTER FAILOVER`), restart the old primary with fresh memory layout, let it resync, optionally fail back.

## Logs

Defrag cycles log at `verbose` (not default `notice`). Bump `loglevel verbose` temporarily if you need visibility into cycle durations and hit counts during a tuning pass.
