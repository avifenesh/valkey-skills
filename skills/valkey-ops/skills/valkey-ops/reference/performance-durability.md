# Durability vs Performance

Use when picking persistence settings and related tuning knobs.

## Durability ladder

Same spectrum as Redis. Pick the row that matches your data-loss budget:

| Setting | Max data loss | Cost |
|---------|---------------|------|
| `appendonly yes` + `appendfsync always` | ≤ 1 command | Every write fsyncs - heavy latency hit |
| `appendonly yes` + `appendfsync everysec` (Valkey default) | ≤ 1 s | Background fsync; balanced |
| `appendonly yes` + `everysec` + `no-appendfsync-on-rewrite yes` | ≤ 1 s normally; more during rewrite | Skips fsync during BGSAVE/BGREWRITEAOF |
| `appendonly yes` + `appendfsync no` | OS-scheduled (~30 s on Linux) | Lowest AOF latency |
| `save` rules only | Since last snapshot | Low overhead, coarse recovery |
| `save ""` + `appendonly no` | All on restart | Pure in-memory cache |

Mixed mode for prod (Valkey ships `aof-use-rdb-preamble yes` by default): `appendonly yes` + `appendfsync everysec` + `save 3600 1 300 100 60 10000`. The AOF file starts with an RDB preamble (magic `VALKEY080` on 9.0+; loader accepts `REDIS...` too) so reload is near-RDB-speed followed by AOF-tail replay.

## `no-appendfsync-on-rewrite` silently downgrades `always`

If you set `appendfsync always` and `no-appendfsync-on-rewrite yes`, during BGREWRITEAOF fsync is disabled - violating the "max 1 command loss" promise for the duration of the rewrite. Either accept the trade or provision disk I/O for both concurrent fsync paths.

## `stop-writes-on-bgsave-error` incident mode

Default `yes`. After a failed BGSAVE (disk full, permission error), all writes reject with `-MISCONF` until a successful save clears the flag. Common "disk cleared but writes still frozen" cause - operators forget they need `CONFIG SET stop-writes-on-bgsave-error no` temporarily or trigger a `BGSAVE` manually after the underlying issue resolves.

## TCP backlog

`tcp-backlog` default 511, immutable. Effective value is `min(tcp-backlog, kernel.somaxconn)`. If the kernel is 128 (Linux default), Valkey logs a warning at startup. Bump `net.core.somaxconn=65535` at the node level or via the container's K8s `securityContext.sysctls`.

## Client connection tuning

| Parameter | Default | Notes |
|-----------|---------|-------|
| `maxclients` | `10000` | |
| `timeout` | `0` | `0` disables idle-client disconnect. Set 300 (5 min) for exposed deployments. |
| `tcp-keepalive` | `300` | Detects dead peers. |
| `maxmemory-clients` | `0` | `5%` is the usual prod value. |

Output buffer limits (`client-output-buffer-limit <class> <hard> <soft> <soft-seconds>`):

- `normal` - default unlimited. Set a hard limit if untrusted clients can connect.
- `replica` - must be `>= repl-backlog-size` or partial resync breaks. Typical: `256mb 64mb 60`.
- `pubsub` - slow subscribers kill the primary if not bounded. Typical: `32mb 8mb 60`.

## Valkey 9.0 performance features (ops-visible)

| Feature | Config knob | What ops see |
|---------|-------------|--------------|
| Pipeline memory prefetch | `prefetch-batch-max-size` (default 16, max 128) | Lower p99 on pipelined workloads. Disable with `0` or `1`. |
| Zero-copy reply path | `min-io-threads-avoid-copy-reply` (default 7, HIDDEN) | Skips reply buffering when I/O threads >= 7. Fewer allocations; lower RSS under high fanout. |
| SIMD BITCOUNT / HLL | no knob | Automatic if CPU has AVX2 / NEON. |
| Multipath TCP | `mptcp yes` / `repl-mptcp yes`; immutable | Requires Linux 5.6+; both ends must support. Reduces tail latency on multi-path networks. |
| Atomic slot migration | `CLUSTER MIGRATESLOTS` | No ASK redirect storms during resharding; multi-key ops keep working. See `cluster-resharding.md`. |

The exact throughput/latency improvement is workload-dependent. Don't quote percentages without your own measurement.

## Kernel knobs

```sh
sysctl -w net.core.somaxconn=65535
sysctl -w vm.overcommit_memory=1
echo never > /sys/kernel/mm/transparent_hugepage/enabled
ulimit -n 65535
```

Same as Redis. `vm.overcommit_memory=1` is the one that matters for fork-based RDB/AOF rewrite to survive on a tight-memory box.
