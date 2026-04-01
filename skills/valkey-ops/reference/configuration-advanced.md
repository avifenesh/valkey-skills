# Advanced Configuration

Use when tuning structured logging, OOM behavior, graceful shutdown, active expiration, CPU pinning, Unix sockets, or protocol limits. All defaults verified against `src/config.c` in valkey-io/valkey.

## Contents

- Structured Logging (line 23)
- OOM Score Adjustment (line 58)
- Graceful Shutdown (line 82)
- Active Expiration (line 114)
- CPU Pinning (line 139)
- Unix Socket (line 173)
- Protocol Limits (line 207)
- Quick Reference Summary (line 231)
- Common Anti-Patterns (line 248)
- Config Interaction Warnings (line 266)

---

## Structured Logging

Valkey supports structured log output for integration with log aggregation
systems (ELK, Loki, Datadog). The format and timestamp settings are runtime
modifiable.

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `log-format` | `legacy` | yes | Output format: `legacy`, `logfmt`, `json`. |
| `log-timestamp-format` | `legacy` | yes | Timestamp style: `legacy`, `iso8601`, `milliseconds`. |
| `syslog-enabled` | `no` | no | Forward logs to syslog. Requires restart. |
| `syslog-ident` | `valkey` | no | Syslog identity string. |
| `syslog-facility` | `local0` | no | Syslog facility: `user`, `local0`-`local7`. |

**When to change**: Switch `log-format` to `json` or `logfmt` when feeding logs
into structured log pipelines. Use `iso8601` timestamps for cross-timezone
correlation. Enable syslog when centralizing via rsyslog or journald.

Source references:
- `log-format`: line 3351, enum values `legacy`, `logfmt`, `json` (line 169)
- `log-timestamp-format`: line 3352, enum values `legacy`, `iso8601`, `milliseconds` (line 171)
- `syslog-enabled`: line 3276, default `0` (no)
- `syslog-ident`: line 3310, default `SERVER_NAME` which is `"valkey"` (version.h line 5)
- `syslog-facility`: line 3336, default `LOG_LOCAL0`

### Example: JSON logging with ISO timestamps

```
CONFIG SET log-format json
CONFIG SET log-timestamp-format iso8601
CONFIG REWRITE
```

---

## OOM Score Adjustment

Controls Linux OOM killer behavior. When enabled, Valkey adjusts
`/proc/self/oom_score_adj` for the main process and child processes (RDB/AOF).

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `oom-score-adj` | `no` | yes | Enable OOM score adjustment: `no`, `yes`/`relative`, `absolute`. |
| `oom-score-adj-values` | `0 200 800` | yes | Three space-separated values: main process, child before save, child during save. Range: -2000 to 2000. |

**When to change**: Enable on servers running alongside other critical services.
Setting `oom-score-adj yes` with values `0 200 800` makes child processes
(BGSAVE/BGREWRITEAOF) more likely to be killed by OOM than the main server
process, protecting data serving.

- `relative` mode: values are added to the initial `oom_score_adj` at startup
- `absolute` mode: values are set directly (requires privileges)

Source references:
- `oom-score-adj`: line 3341, default `OOM_SCORE_ADJ_NO` (line 134)
- `oom-score-adj-values`: line 3494, defaults `{0, 200, 800}` (line 188)

---

## Graceful Shutdown

Controls what happens when Valkey receives SIGINT or SIGTERM.

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `shutdown-on-sigint` | `default` | yes | Behavior on SIGINT. Flags: `default`, `save`, `nosave`, `now`, `force`, `safe`, `failover`. |
| `shutdown-on-sigterm` | `default` | yes | Behavior on SIGTERM. Same flags as above. |
| `shutdown-timeout` | `10` | yes | Seconds to wait for replicas to catch up during shutdown. Range: 0 to INT_MAX. |

Flag meanings:
- `default` - save if RDB is configured, otherwise don't save
- `save` - force an RDB save before shutdown
- `nosave` - skip RDB save
- `now` - skip waiting for lagging replicas
- `force` - ignore errors during shutdown (exit regardless)
- `safe` - require successful save before exiting
- `failover` - trigger failover to replica before shutdown

Multiple flags can be combined: `shutdown-on-sigterm save safe`.

**When to change**: Set `shutdown-on-sigterm save safe` in production to ensure
data is persisted before exit. Increase `shutdown-timeout` for clusters with
slow replicas. Use `failover` for zero-downtime maintenance.

Source references:
- `shutdown-on-sigint`: line 3349, default `0` (SHUTDOWN_NOFLAGS = `default`)
- `shutdown-on-sigterm`: line 3350, default `0` (SHUTDOWN_NOFLAGS = `default`)
- `shutdown-timeout`: line 3401, default `10` seconds

---

## Active Expiration

Valkey proactively removes expired keys in background cycles. These settings
control how aggressively it reclaims expired keys.

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `active-expire-effort` | `1` | yes | Effort level 1-10. Higher = more CPU on expiration, faster reclaim. |
| `hz` | `10` | yes | Server timer frequency (calls/sec). Controls background task frequency including expiration. |

**When to change**:
- Increase `active-expire-effort` (to 3-5) when a large percentage of keys have
  TTLs and you see stale keys accumulating (check `expired_stale_perc` in INFO).
- Effort 10 uses significantly more CPU - only use under extreme TTL pressure.
- `hz` affects all background tasks (expiration, client timeout checks, stats
  update). Values above 100 are rarely beneficial. The `dynamic-hz` behavior
  (automatic scaling based on connected clients) is now always on and its config
  is deprecated.

Source references:
- `active-expire-effort`: line 3396, default `1`, range 1-10
- `hz`: line 3397, default `CONFIG_DEFAULT_HZ` = `10` (server.h line 139)

---

## CPU Pinning

Pin Valkey threads to specific CPU cores. All are immutable (require restart).
Uses Linux CPU list syntax (e.g., `0-3`, `0,2,4`, `0-7:2`).

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `server-cpulist` | `""` (none) | no | CPU affinity for main server thread and I/O threads. |
| `bio-cpulist` | `""` (none) | no | CPU affinity for background I/O threads (lazy free, AOF fsync, close). |
| `aof-rewrite-cpulist` | `""` (none) | no | CPU affinity for AOF rewrite child process. |
| `bgsave-cpulist` | `""` (none) | no | CPU affinity for BGSAVE child process. |

**When to change**: On NUMA systems or dedicated Valkey servers where you want to
isolate Valkey from other workloads. Pin the main thread to one NUMA node and
background tasks to another. Avoid pinning on shared or virtualized hosts where
CPU topology may change.

Example for a 16-core NUMA system:

```
server-cpulist 0-3
bio-cpulist 4-5
aof-rewrite-cpulist 6-7
bgsave-cpulist 6-7
```

Source references:
- `server-cpulist`: line 3314, default `NULL` (empty)
- `bio-cpulist`: line 3315, default `NULL`
- `aof-rewrite-cpulist`: line 3316, default `NULL`
- `bgsave-cpulist`: line 3317, default `NULL`

---

## Unix Socket

Listen on a Unix domain socket instead of (or in addition to) TCP. Lower
latency for co-located clients.

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `unixsocket` | `""` (disabled) | no | Path to Unix socket file. Empty = disabled. |
| `unixsocketgroup` | `""` (none) | no | Group ownership for the socket file. |
| `unixsocketperm` | `0` | no | Socket file permissions (octal). Common: `700`, `770`. |

**When to change**: When Valkey clients run on the same host. Unix sockets
eliminate TCP overhead and provide ~10-20% lower latency for local connections.
Set `unixsocketperm` to `770` and `unixsocketgroup` to a shared group for
multi-user access.

Example:

```
unixsocket /var/run/valkey/valkey.sock
unixsocketperm 770
unixsocketgroup valkey
```

`unixsocketperm 0` (the default) means the socket inherits the process
umask. Set explicitly for production use.

Source references:
- `unixsocket`: line 3299, default `NULL` (disabled)
- `unixsocketgroup`: line 3300, default `NULL`
- `unixsocketperm`: line 3410, default `0`, octal config

---

## Protocol Limits

Control maximum sizes for client queries and bulk strings.

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `client-query-buffer-limit` | `1gb` | yes | Maximum size of a single client query buffer. |
| `proto-max-bulk-len` | `512mb` | yes | Maximum size of a single RESP bulk string element. |

**When to change**:
- Reduce `client-query-buffer-limit` if you want to protect against clients
  sending unexpectedly large commands (e.g., very large MSET batches). The
  default 1GB is generous.
- Increase `proto-max-bulk-len` only if you store individual values larger than
  512MB (rare and discouraged).
- Reduce both on memory-constrained instances to limit worst-case per-client
  memory usage.

Source references:
- `client-query-buffer-limit`: line 3457, default `1024*1024*1024` (1GB), min 1MB
- `proto-max-bulk-len`: line 3436, default `512ll*1024*1024` (512MB), min 1MB

---

## Quick Reference Summary

| Parameter | Default | Key Decision |
|-----------|---------|-------------|
| `log-format` | `legacy` | Switch to `json` for structured log pipelines |
| `log-timestamp-format` | `legacy` | Use `iso8601` for cross-timezone environments |
| `syslog-enabled` | `no` | Enable for centralized syslog infrastructure |
| `oom-score-adj` | `no` | Enable on multi-service hosts to protect main process |
| `shutdown-on-sigterm` | `default` | Set `save safe` for data-critical production |
| `shutdown-timeout` | `10` | Increase for clusters with slow replicas |
| `active-expire-effort` | `1` | Increase to 3-5 for heavy TTL workloads |
| `hz` | `10` | Rarely needs changing - dynamic scaling is automatic |
| `server-cpulist` | `""` | Pin on dedicated NUMA hosts only |
| `unixsocket` | `""` | Enable for co-located client performance |
| `client-query-buffer-limit` | `1gb` | Reduce on memory-constrained instances |
| `proto-max-bulk-len` | `512mb` | Increase only for unusually large values |

## Common Anti-Patterns

| Anti-Pattern | Symptom | Fix |
|-------------|---------|-----|
| No `maxmemory` set | OOM killer terminates Valkey | Always set explicit `maxmemory` |
| `maxmemory` = total RAM | OOM during BGSAVE fork | Reserve 20-40% for OS, fork COW, buffers |
| `volatile-*` policy with no TTLs | Writes fail with OOM errors | Use `allkeys-*` or ensure cache keys have TTLs |
| `hash-max-listpack-entries 10000` | Slow HGET/HSET (O(N) linear scan) | Keep at 128-512 |
| `hz 500` | Wastes CPU on background tasks | Use 10-100 max |
| `active-expire-effort 10` + millions of TTL keys | CPU spikes from expiry cycle | Start at 1, increase incrementally |
| Pub/Sub buffer limit = 0 (unlimited) | Slow subscriber consumes all RAM | Always set hard limits for pubsub |
| `io-threads` on 2-core machine | Higher latency, not lower | Only enable with 3+ cores |
| `lfu-decay-time 0` | Old popular keys never become eviction candidates | Use 1 (default) |
| No `maxmemory-clients` | Client buffers evict data | Set to 5% for production |
| `KEYS *` in production | Server blocks for seconds | Use `SCAN` with `COUNT` hint |

---

## Config Interaction Warnings

Settings that must be coordinated - changing one without the other causes problems:

| Config A | Config B | Interaction |
|----------|----------|-------------|
| `maxmemory` | `maxmemory-policy` | Policy is only active when maxmemory is set |
| `maxmemory` | `maxmemory-clients` | Client eviction threshold is a percentage of maxmemory |
| `maxmemory` | replication buffers | Replica output buffers are NOT counted toward eviction calculation |
| `maxmemory-policy` | TTL on keys | `volatile-*` policies only consider keys with TTL set |
| `hz` | `active-expire-effort` | Higher hz = more frequent expiry cycles at the given effort level |
| `hz` | `activedefrag` | Defrag runs as part of the hz background cycle |
| `client-output-buffer-limit replica` | `repl-backlog-size` | Replica buffer limit must be >= backlog size |
| `lfu-log-factor` | `lfu-decay-time` | Together control LFU counter sensitivity and adaptation speed |
| `appendfsync` | `no-appendfsync-on-rewrite` | Skip fsync during rewrite reduces disk pressure but increases data loss window |
| `save` | `stop-writes-on-bgsave-error` | Failed BGSAVE blocks all writes unless this is disabled |
| `io-threads` | `commandlog-reply-larger-than` | Large reply logging adds overhead when io-threads is enabled |
| `active-defrag-cycle-us` | latency | Higher value = more defrag progress but longer per-cycle stalls |

---
