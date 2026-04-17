# Advanced Configuration

Use when tuning logging, shutdown behavior, expiration aggressiveness, CPU affinity, or protocol limits. Defaults verified against `src/config.c`.

## Structured logging (Valkey-only formats)

Valkey added `logfmt` and `json` output on top of the legacy Redis log format. Both are runtime-modifiable via `CONFIG SET`.

| Parameter | Default | Values |
|-----------|---------|--------|
| `log-format` | `legacy` | `legacy`, `logfmt`, `json` |
| `log-timestamp-format` | `legacy` | `legacy`, `iso8601`, `milliseconds` |

When shipping logs to Loki/ELK/Datadog, switch to `json` + `iso8601`. `syslog-enabled` / `syslog-ident` / `syslog-facility` are the same as Redis - immutable.

## OOM score adjustment

`oom-score-adj` and `oom-score-adj-values` behave as in Redis. Default values `{0, 200, 800}` (main / child-before-save / child-during-save) - setting `oom-score-adj relative` on a multi-tenant host makes the BGSAVE/BGREWRITEAOF children die before the serving process does.

## Graceful shutdown

`shutdown-on-sigint` / `shutdown-on-sigterm` / `shutdown-timeout`. Flag combinations: `default` (save if RDB configured), `save`, `nosave`, `now`, `force`, `safe`, `failover`. Multi-flag: `shutdown-on-sigterm save safe`.

For data-critical prod: `shutdown-on-sigterm save safe` - Valkey refuses to exit if the save fails. `failover` triggers Sentinel/cluster promotion before shutdown - useful in rolling restarts.

## Active expiration

| Parameter | Default | Notes |
|-----------|---------|-------|
| `active-expire-effort` | `1` | 1-10. Each step adds ~25% more keys per cycle. Raise to 3-5 only if `expired_stale_perc` (INFO stats) is consistently >10. Effort 10 burns real CPU. |
| `hz` | `10` | The old `dynamic-hz` knob is deprecated (in `deprecated_configs[]`) - auto-scaling is permanent. |

## CPU pinning

All four lists (`server-cpulist`, `bio-cpulist`, `aof-rewrite-cpulist`, `bgsave-cpulist`) take Linux cpulist syntax (`0-3`, `0,2,4`, `0-7:2`). All immutable.

Only pin on a dedicated or NUMA host. Pinning on a shared VM where CPU topology can shift (live migration, vCPU hotplug) makes latency worse, not better.

## Protocol limits

`client-query-buffer-limit` (default 1 GiB) and `proto-max-bulk-len` (default 512 MiB) are runtime-modifiable. Lower both on memory-tight instances - the defaults are generous because Redis-era deployments stored very large blobs. For a cache or session store, 64 MB / 16 MB is usually safe.

## Config interactions worth remembering

- `maxmemory` vs `maxmemory-policy` - policy is a no-op unless maxmemory is set. `volatile-*` policies silently do nothing if no keys have TTL.
- `maxmemory` vs `maxmemory-clients` - client buffer budget is a percentage of maxmemory when expressed with `%`. Replica output buffers are **not** counted, and the replication backlog is counted separately.
- `client-output-buffer-limit replica` vs `repl-backlog-size` - replica limit must be `>= repl-backlog-size` or partial resync fails and triggers a full resync storm.
- `stop-writes-on-bgsave-error yes` vs `save` - after a failed BGSAVE, all writes reject until the next successful save or until you disable this. Operators sometimes forget this is the switch they need during a disk-full incident.
- `appendfsync always` vs `no-appendfsync-on-rewrite yes` - the second silently downgrades the first during rewrites. Either accept it or set `no-appendfsync-on-rewrite no` and provision disk I/O for both concurrent fsync paths.

## Unix socket

`unixsocket` + `unixsocketperm 770` + `unixsocketgroup <shared>` for co-located clients. The default `unixsocketperm 0` means the file inherits the umask, so local-client connections may silently fail for other users.
