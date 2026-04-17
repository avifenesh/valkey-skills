# Essential Configuration - Defaults Reference

Use when setting up or auditing `valkey.conf`. Defaults verified against `src/config.c` for Valkey 9.0.

All parameters are runtime-modifiable (`CONFIG SET`) unless flagged immutable. Persist runtime changes with `CONFIG REWRITE`.

## Network

| Parameter | Default | Notes |
|-----------|---------|-------|
| `bind` | `* -::*` | Listens on all interfaces. Production: bind to specific IPs. Runtime-modifiable despite some old docs. |
| `port` | `6379` | Set `0` to disable plaintext (TLS-only). |
| `protected-mode` | `yes` | Rejects external connections when no password is set and bind is default. |
| `tcp-backlog` | `511` | Immutable. Capped by kernel `somaxconn`. |
| `tcp-keepalive` | `300` | Seconds between keepalive probes. |
| `timeout` | `0` | Idle client timeout; `0` = never. |
| `maxclients` | `10000` | |
| `mptcp` | `no` | Multipath TCP (Valkey 9.0+, Linux 5.6+). Immutable. Requires `mptcp yes` / `repl-mptcp yes`. |

## Memory

| Parameter | Default | Notes |
|-----------|---------|-------|
| `maxmemory` | `0` | Unlimited. Always set explicitly. |
| `maxmemory-policy` | `noeviction` | **Note:** source default is `noeviction`, not `allkeys-lru`. |
| `maxmemory-clients` | `0` | Accepts percentage (`5%`) - evaluated at SET time. |
| `maxmemory-samples` | `5` | LRU/LFU sample count. |
| `maxmemory-eviction-tenacity` | `10` | 0-100. |

`maxmemory` should leave 30-40% RAM for fork COW + client buffers + OS. Cache-only workloads can push to 80%; write-heavy AOF+RDB setups should stay at 50-60%.

## Persistence - RDB

| Parameter | Default | Notes |
|-----------|---------|-------|
| `save` | `3600 1 300 100 60 10000` | Initialized in `initServerConfig`, not in the config table. Means: 1 change in 1h OR 100 in 5m OR 10000 in 1m. |
| `dbfilename` | `dump.rdb` | |
| `dir` | `./` | |
| `rdbchecksum` | `yes` | CRC64. |
| `rdbcompression` | `yes` | LZF. |
| `stop-writes-on-bgsave-error` | `yes` | Failed BGSAVE blocks writes until cleared. Common "disk full, writes frozen" incident source. |
| `rdb-save-incremental-fsync` | `yes` | |
| `rdb-del-sync-files` | `no` | |
| `rdb-version-check` | `strict` | Valkey-only. `strict` rejects foreign RDB range (12-79); `relaxed` allows loading RDBs from forks. Modifiable at runtime. |

## Persistence - AOF

| Parameter | Default | Notes |
|-----------|---------|-------|
| `appendonly` | `no` | |
| `appendfilename` | `appendonly.aof` | Immutable. |
| `appenddirname` | `appendonlydir` | Immutable. Multi-part AOF (BASE + INCR + manifest). |
| `appendfsync` | `everysec` | |
| `auto-aof-rewrite-percentage` | `100` | |
| `auto-aof-rewrite-min-size` | `64mb` | |
| `aof-use-rdb-preamble` | `yes` | RDB preamble accepts either `REDIS` or `VALKEY` magic on load. |
| `aof-load-truncated` | `yes` | |
| `aof-timestamp-enabled` | `no` | |
| `no-appendfsync-on-rewrite` | `no` | `yes` silently disables `appendfsync always` during rewrites. |

## I/O Threads

| Parameter | Default | Notes |
|-----------|---------|-------|
| `io-threads` | `1` | 1 = single-threaded. Range 1-256. DEBUG_CONFIG flag. |
| `io-threads-do-reads` | (deprecated) | In `deprecated_configs[]` - silently accepted. Reads are always offloaded when `io-threads > 1`. |
| `events-per-io-thread` | `2` | `HIDDEN_CONFIG`. Not shown in `CONFIG GET *`. Still tunable via `CONFIG SET`. |
| `min-io-threads-avoid-copy-reply` | `7` | `HIDDEN_CONFIG`. Threshold for zero-copy response path. |
| `dynamic-hz` | (deprecated) | Auto-scaling is always on. |

## Logging

| Parameter | Default | Notes |
|-----------|---------|-------|
| `loglevel` | `notice` | `debug / verbose / notice / warning / nothing`. |
| `logfile` | `""` | Immutable. Empty = stdout. |
| `log-format` | `legacy` | Valkey-only. `legacy / logfmt / json`. |
| `log-timestamp-format` | `legacy` | Valkey-only. `legacy / iso8601 / milliseconds`. |
| `syslog-enabled` | `no` | Immutable. |

## COMMANDLOG (replaces SLOWLOG)

| Parameter | Default | Alias |
|-----------|---------|-------|
| `commandlog-execution-slower-than` | `10000` µs | `slowlog-log-slower-than` |
| `commandlog-slow-execution-max-len` | `128` | `slowlog-max-len` |
| `commandlog-request-larger-than` | `1048576` bytes | - |
| `commandlog-large-request-max-len` | `128` | - |
| `commandlog-reply-larger-than` | `1048576` bytes | - |
| `commandlog-large-reply-max-len` | `128` | - |
| `latency-monitor-threshold` | `0` ms | `0` = disabled. |
| `latency-tracking` | `yes` | Per-command latency histogram. |

All three COMMANDLOG types share a unified `COMMANDLOG GET/LEN/RESET` command family. `SLOWLOG *` still works as an alias for the slow-log type.

## Replication (Valkey primary names)

| Parameter | Default | Legacy alias |
|-----------|---------|-------------|
| `replicaof` | - | `slaveof` |
| `replica-priority` | `100` | `slave-priority` |
| `primaryuser` | - | `masteruser` |
| `primaryauth` | - | `masterauth` |
| `replica-serve-stale-data` | `yes` | |
| `replica-read-only` | `yes` | |
| `replica-lazy-flush` | `yes` | |
| `replica-ignore-maxmemory` | `yes` | Replicas don't enforce maxmemory; primary does. |
| `repl-diskless-sync` | `yes` | |
| `repl-diskless-sync-delay` | `5` | Seconds to wait for more replicas. |
| `repl-diskless-load` | `disabled` | `disabled / on-empty-db / swapdb / flush-before-load`. |
| `repl-backlog-size` | `10mb` | |
| `repl-backlog-ttl` | `3600` | |
| `repl-timeout` | `60` | |
| `repl-ping-replica-period` | `10` | |
| `repl-disable-tcp-nodelay` | `no` | |
| `dual-channel-replication-enabled` | `no` | Valkey-only. Full resync uses two TCP connections. |
| `min-replicas-to-write` | `0` | |
| `min-replicas-max-lag` | `10` | |

## Cluster

| Parameter | Default | Notes |
|-----------|---------|-------|
| `cluster-enabled` | `no` | Immutable. |
| `cluster-config-file` | `nodes.conf` | Immutable. |
| `cluster-node-timeout` | `15000` ms | |
| `cluster-manual-failover-timeout` | `5000` ms | Valkey-only (Redis hardcodes this). |
| `cluster-require-full-coverage` | `yes` | |
| `cluster-allow-reads-when-down` | `no` | |
| `cluster-allow-pubsubshard-when-down` | `yes` | Valkey-only default flip - shard pub/sub keeps working when cluster is in FAIL state. |
| `cluster-replica-validity-factor` | `10` | |
| `cluster-migration-barrier` | `1` | |
| `cluster-allow-replica-migration` | `yes` | |
| `cluster-slot-stats-enabled` | `no` | Valkey-only. Enables per-slot CPU + network accounting for `CLUSTER SLOT-STATS`. |
| `cluster-config-save-behavior` | `sync` | Valkey-only. Controls `nodes.conf` save timing. |
| `availability-zone` | `""` | Valkey-only. Gossiped; surfaced in `CLUSTER SHARDS`/`SLOTS`. |

## General / Lazy-Free

| Parameter | Default | Notes |
|-----------|---------|-------|
| `databases` | `16` | Immutable. |
| `hz` | `10` | Timer frequency. |
| `disable-thp` | `yes` | |
| `activerehashing` | `yes` | |
| `hide-user-data-from-log` | `yes` | Valkey-only default. Redacts keys/values from log messages. |
| `busy-reply-threshold` | `5000` ms | Alias: `lua-time-limit`. Triggers BUSY error. |
| `proto-max-bulk-len` | `512mb` | |
| `lazyfree-lazy-eviction` | `yes` | **All five lazyfree defaults are `yes` in Valkey** (Redis defaults are `no`). |
| `lazyfree-lazy-expire` | `yes` | |
| `lazyfree-lazy-server-del` | `yes` | |
| `lazyfree-lazy-user-del` | `yes` | |
| `lazyfree-lazy-user-flush` | `yes` | |

The lazy-free flip means `DEL`, `FLUSH*`, eviction, expire, and server-side deletes all go to background deallocation unless explicitly turned off. Latency characteristics differ from a Redis-defaults environment - the same workload will show lower p99 but the BIO queue can back up under sustained delete pressure.
