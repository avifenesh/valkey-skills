# Performance

Use when sizing, tuning, diagnosing fragmentation, or benchmarking. Redis-baseline mechanics (LRU/LFU policies, fork-COW, LATENCY DOCTOR) carry over - this file is the Valkey-specific layer.

## I/O threads

Command execution stays **single-threaded** on the main thread. I/O threads only handle socket read/write, RESP parsing, and response serialization. No data-structure locking. Each worker has an SPSC queue; clients are assigned to threads deterministically by `client-id % (active-threads - 1) + 1`.

Under TLS, `SSL_accept` also runs on I/O threads automatically via `trySendAcceptToIOThreads` - see `security.md`.

### Config

| Parameter | Default | Notes |
|-----------|---------|-------|
| `io-threads` | `1` | Total including main. `io-threads 4` = main + 3 workers. Range 1-256. |
| `events-per-io-thread` | `2` | HIDDEN_CONFIG. Events per active worker in `adjustIOThreadsByEventLoad`. `0` = always offload. |
| `min-io-threads-avoid-copy-reply` | `7` | HIDDEN. At ≥ this many threads, zero-copy reply path kicks in. |
| `io-threads-do-reads` | deprecated | Reads always offloaded when workers exist. |

Workers park on a per-thread mutex when idle and unpark under load. Monitor `io_threads_active` in `INFO stats` to see what's running - below `io-threads - 1` means demoted workers.

### When to enable

- Throughput-bound, many concurrent clients, spare cores.
- Main thread near-saturated on read/write (profile shows `readQueryFromClient` / `sendReplyToClient` on top).

When NOT:
- 2-core boxes (context switching > parallelism gain).
- Latency-sensitive low-RPS (handoff adds microseconds).
- Memory- or eviction-bound (I/O threads don't help those paths).

### Sizing

Never set `io-threads` ≥ physical cores. Over-subscription hurts throughput.

| Cores | Reasonable `io-threads` | Rationale |
|-------|------------------------|-----------|
| 4 | 2 | Leave main + OS + IRQs headroom. |
| 8 | 5-6 | 1-2 cores for IRQ affinity, 1 for main, rest I/O. |
| 16 | 8-9 | Common sweet spot on bigger boxes. |
| 32+ | 6-8 | Gains flatten - you're single-main-thread limited on command execution. |

### IRQ affinity (big boxes)

1. Pin NIC IRQs to dedicated cores (`/proc/irq/<n>/smp_affinity`).
2. Set `server-cpulist` to remaining cores.
3. Set `bio-cpulist` on a separate NUMA node if applicable.

Don't pin on shared VMs - CPU topology isn't yours to control.

### Troubleshooting

- **No throughput gain after enabling**: workload isn't I/O-bound. Profile main thread - if read/write syscalls aren't top, I/O threads won't help.
- **Latency up after enabling**: too few cores for the thread count. Reduce `io-threads`.
- **`io_threads_active` stays at 1**: dynamic activation needs enough concurrent events; not a bug.

## Memory - divergent encoding

Valkey 8.1 bumped `hash-max-listpack-entries` from 128 to **512**. Redis-trained mental models of "at 128 fields the hash promotes" are wrong on Valkey.

| Directive | Valkey default | Redis 7.2 default |
|-----------|---------------|-------------------|
| `hash-max-listpack-entries` | **512** | 128 |
| `hash-max-listpack-value` | 64 | 64 |
| `set-max-listpack-entries` | 128 | 128 |
| `zset-max-listpack-entries` | 128 | 128 |
| listpack value caps | 64 B | 64 B |
| `list-max-listpack-size` | `-2` (8 KB/node) | `-2` |

Knock-on: hashes promoted on Redis may stay listpack on Valkey. Lookups are O(N) on listpack but N is small; memory drops 2-5x vs hashtable. Keep the bump unless tail-latency on hash reads spikes.

## Memory - built-in per-key savings

Automatic, no tuning. Effect: `used_memory` per key is lower than Redis 7.2 for the same dataset. Relevant when capacity-planning a Redis → Valkey migration at constant RAM.

- **Kvstore per-slot** (cluster mode, 8.0+): 16,384 per-slot hashtables replace the single global. Drops per-key overhead, localizes rehashing to the touched slot.
- **Embedded key** (8.0+): key SDS lives inside the hashtable entry, saving a pointer dereference per lookup.
- **Embedded string value with key + expire** (9.0+): `createStringObjectWithKeyAndExpire` fuses `robj` + optional key SDS + optional expire + value SDS into a single embedded allocation when the combined size fits in 64 bytes. Value-only strings still use the classic `OBJ_ENCODING_EMBSTR_SIZE_LIMIT = 44` cutoff. Net effect: fewer allocations per key on Valkey 9.0 than Redis 7.2 for the same dataset.

## Memory - `maxmemory-clients`

```
maxmemory-clients 5%     # percentage of maxmemory
maxmemory-clients 256mb  # absolute
```

Percentage form is evaluated at `maxmemory` SET time. Changing `maxmemory` without re-setting `maxmemory-clients` keeps the literal value from last evaluation. After a `maxmemory` bump, re-set the percentage or it silently becomes a smaller fraction.

Client buffers and replica output buffers are NOT counted toward eviction (`mem_not_counted_for_evict` in INFO memory). Replica-heavy deployments: primary's real RSS exceeds `maxmemory` by the sum of replica COB sizes plus the replication backlog.

## Memory - fragmentation and fork

| Ratio | Interpretation |
|-------|---------------|
| < 1.0 | Swapping - investigate RSS vs `used_memory_peak`. |
| 1.0-1.5 | Normal. |
| 1.5-2.0 | Moderate - `MEMORY PURGE` or run active defrag. |
| > 2.0 | High - enable `activedefrag` or schedule a restart. |
| > 3.0 | Defrag likely can't keep up - failover-restart. |

Fork RSS on write-heavy workloads can approach **2× parent RSS** under sustained writes. Plan `maxmemory = 60-70% of node RAM` (50-60% for AOF+RDB heavy; 80% for cache-only where fork pressure is lower).

## Active defragmentation

Jemalloc-only feature (`HAVE_DEFRAG` gated on `USE_JEMALLOC`). With libc/tcmalloc, `activedefrag yes` is silently a no-op. Verify: `valkey-cli INFO server | grep mem_allocator` → `jemalloc`.

### Config

| Parameter | Default | Notes |
|-----------|---------|-------|
| `activedefrag` | `no` | Main on/off switch. |
| `active-defrag-threshold-lower` | `10` (%) | Below this fragmentation %, defrag doesn't start. |
| `active-defrag-threshold-upper` | `100` (%) | At this %, defrag runs at max CPU. |
| `active-defrag-cycle-min` | `1` (%) | CPU % at lower threshold. |
| `active-defrag-cycle-max` | `25` (%) | CPU % at upper threshold. |
| `active-defrag-cycle-us` | `500` µs | **Valkey-specific.** Base duty-cycle duration; larger = more work per cycle, longer per-cycle stalls. |
| `active-defrag-max-scan-fields` | `1000` | Keys with more fields than this go through a separate staged pass. |
| `active-defrag-ignore-bytes` | `100 MB` | Don't start if frag overhead is below this absolute byte count. |

CPU effort scales linearly between `cycle-min` and `cycle-max` as fragmentation goes from `threshold-lower` to `threshold-upper`.

### Tuning profiles

```sh
# Aggressive - CPU to spare
CONFIG SET active-defrag-cycle-min 5
CONFIG SET active-defrag-cycle-max 75
CONFIG SET active-defrag-threshold-lower 5

# Gentle - latency-sensitive
CONFIG SET active-defrag-cycle-min 1
CONFIG SET active-defrag-cycle-max 15
```

### Metrics

- `active_defrag_running` - current CPU % (0 when idle).
- `active_defrag_hits` / `_misses` - allocations moved vs scanned-but-not-moved.
- `active_defrag_key_hits` / `_misses` - per-key rollup.

High miss/hit ratio = defrag scanning without finding relocatable allocations. Lower `threshold-lower` or check if fragmentation is actually swap (ratio < 1.0).

### Workloads that fragment

- Large-key deletion (multi-GB sorted sets, hashes).
- Delete-heavy mixed workloads (churn across size classes).
- Listpack → hashtable promotions (freed compact, allocated full in different size class).

### When restart beats defrag

- Ratio >3.0 and defrag can't keep up (not dropping over hours).
- Replica rebuildable quickly from primary.
- On libc/tcmalloc (no defrag).
- Zero CPU headroom, latency already critical.

Restart path: promote a replica (`SENTINEL FAILOVER ... COORDINATED` or `CLUSTER FAILOVER`), restart old primary with fresh memory layout, resync, optionally fail back.

Defrag cycles log at `verbose` (not default `notice`). Bump `loglevel verbose` temporarily during tuning.

## Durability vs performance ladder

| Setting | Max data loss | Cost |
|---------|---------------|------|
| `appendonly yes` + `appendfsync always` | ≤1 command | Every write fsyncs - heavy latency hit |
| `appendonly yes` + `appendfsync everysec` (Valkey default) | ≤1 s | Background fsync; balanced |
| `appendonly yes` + `everysec` + `no-appendfsync-on-rewrite yes` | ≤1 s normally; more during rewrite | Skips fsync during BGSAVE/BGREWRITEAOF |
| `appendonly yes` + `appendfsync no` | OS-scheduled (~30 s on Linux) | Lowest AOF latency |
| `save` rules only | Since last snapshot | Low overhead, coarse recovery |
| `save ""` + `appendonly no` | All on restart | Pure in-memory cache |

Mixed mode for prod (Valkey default): `appendonly yes` + `appendfsync everysec` + `save 3600 1 300 100 60 10000` + `aof-use-rdb-preamble yes`. AOF file starts with RDB preamble (magic `VALKEY080` on 9.0+; loader accepts `REDIS...` too) so reload is near-RDB-speed followed by AOF-tail replay.

**`no-appendfsync-on-rewrite yes` silently downgrades `always`** - during BGREWRITEAOF, fsync is disabled, violating the "max 1 command loss" promise for the rewrite duration.

**`stop-writes-on-bgsave-error yes` incident mode** - after failed BGSAVE, writes reject with `-MISCONF` until a successful save clears the flag. Common "disk cleared but writes still frozen" cause - `CONFIG SET stop-writes-on-bgsave-error no` temporarily or trigger `BGSAVE` manually after the underlying issue resolves.

## Valkey 9.0 performance features

| Feature | Config knob | What ops see |
|---------|-------------|--------------|
| Pipeline memory prefetch | `prefetch-batch-max-size` (default 16, max 128) | Lower p99 on pipelined workloads. Disable with `0` or `1`. |
| Zero-copy reply path | `min-io-threads-avoid-copy-reply` (default 7, HIDDEN) | Skips reply buffering when I/O threads ≥7. Fewer allocations; lower RSS under high fanout. |
| SIMD BITCOUNT / HLL | no knob | Automatic if CPU has AVX2 / NEON. |
| Multipath TCP | `mptcp yes` / `repl-mptcp yes`; immutable | Requires Linux 5.6+; both ends must support. Reduces tail latency on multi-path networks. |
| Atomic slot migration | `CLUSTER MIGRATESLOTS` | No ASK storms during resharding; multi-key ops keep working. See `cluster.md`. |

Exact throughput/latency improvement is workload-dependent - don't quote percentages without your own measurement.

## Client connection tuning

| Parameter | Default | Notes |
|-----------|---------|-------|
| `maxclients` | `10000` | |
| `timeout` | `0` | `0` disables idle disconnect. Set 300 (5 min) for exposed deployments. |
| `tcp-keepalive` | `300` | Detects dead peers. |
| `maxmemory-clients` | `0` | `5%` is usual prod value. |

Output buffer limits (`client-output-buffer-limit <class> <hard> <soft> <soft-seconds>`):
- `normal` - default unlimited. Set a hard limit if untrusted clients connect.
- `replica` - must be `≥ repl-backlog-size` or partial resync breaks. Typical: `256mb 64mb 60`.
- `pubsub` - slow subscribers kill the primary if not bounded. Typical: `32mb 8mb 60`.

## Kernel

```sh
sysctl -w net.core.somaxconn=65535
sysctl -w vm.overcommit_memory=1
echo never > /sys/kernel/mm/transparent_hugepage/enabled
ulimit -n 65535
```

`tcp-backlog` default 511, immutable. Effective is `min(tcp-backlog, kernel.somaxconn)`. If kernel is 128 (Linux default), Valkey logs a warning at startup.

`vm.overcommit_memory=1` is required for fork-based RDB/AOF rewrite to survive on a tight-memory box.

## Latency diagnosis

```sh
valkey-cli --intrinsic-latency 100   # run on server, 100s baseline
valkey-cli LATENCY DOCTOR
valkey-cli LATENCY LATEST
valkey-cli LATENCY HISTOGRAM GET SET HGET
CONFIG SET latency-monitor-threshold 100
CONFIG SET watchdog-period 500       # emergency stall diagnosis; disable after
```

COMMANDLOG (slow + large-request + large-reply) is the primary investigation tool - see `monitoring.md`. Common causes: THP enabled, slow commands, fork latency, AOF fsync, disk contention, expiration storms, swapping.

## Client-side caching

| Parameter | Default |
|-----------|---------|
| `tracking-table-max-keys` | `1000000` |

Invalidation channel name is `__redis__:invalidate` (legacy prefix retained).

```
CLIENT TRACKING ON                         # default mode
CLIENT TRACKING ON BCAST PREFIX user:      # broadcasting mode
CLIENT TRACKING ON OPTIN                   # explicit opt-in per read
CLIENT TRACKING ON NOLOOP                  # skip self-modification invalidations
```

In cluster mode, tracking works per-node - each node tracks only its own keys. Broadcasting with empty prefix sends invalidations for every write on that node.

When `tracking_total_keys` approaches `tracking-table-max-keys`, the server evicts entries and sends phantom invalidations. Increase the limit or switch hot-path clients to broadcasting mode.

## Benchmarking

`valkey-benchmark` (built-in) for ad-hoc; `valkey-perf-benchmark` (separate Python harness at `valkey-io/valkey-perf-benchmark`) for regression testing, statistical analysis, flamegraphs, TLS/cluster matrix. `redis-benchmark` also works (same wire protocol; symlinked with `USE_REDIS_SYMLINKS=yes`).

### Essential flags

| Flag | Default | Notes |
|------|---------|-------|
| `-c` | 50 | Parallel connections |
| `-n` | 100000 | Total requests |
| `-d` | 3 | Value size in bytes |
| `-P` | 1 | Pipeline depth (`-P 16` simulates pipelined clients) |
| `-t` | all | Comma-separated command list (`-t set,get`) |
| `-q` | off | Quiet - print req/s summary only |
| `--cluster` | off | Cluster mode (hash-tag fan-out) |
| `--tls` / `--cert` / `--key` / `--cacert` | - | TLS |
| `--threads` | 1 | Client I/O threads (different from server `io-threads`) |
| `--csv` | off | Machine-readable output |

### Isolation heuristics

- Disable other workloads on the host. Shared VMs give noisy, non-reproducible results.
- CPU governor to performance: `cpupower frequency-set -g performance`.
- Pin server and client cores via `taskset` - prevents scheduler blips.
- Disable persistence during throughput benchmarks (`--save "" --appendonly no`) unless durability overhead is what you're measuring.
- Warm up: discard the first run.
- ≥3-5 iterations, report mean and std-dev. Coefficient of variation under 5% is a reasonable reproducibility threshold.
- Check CPU saturation on the server: if main thread is 100%, you're measuring CPU limits not I/O.
- Hold `-c`, `-P`, `-d`, `-n` constant when comparing configs/versions. Pipelining especially: `-P > 1` is needed to exercise 9.0's prefetch and zero-copy reply.

### `valkey-perf-benchmark`

Builds Valkey from source per commit, runs `valkey-benchmark` under a config-matrix JSON (commands × data sizes × pipeline × io-threads × TLS × cluster modes), collects multi-run stats, emits markdown + graphs. GitHub Actions workflow in that repo does continuous regression benchmarking. Use when you need to prove/disprove "did this PR regress performance" before merging.
