# Configuration

Use when auditing or tuning `valkey.conf` - defaults verified against `src/config.c`. All parameters are runtime-modifiable (`CONFIG SET`) unless flagged immutable; persist with `CONFIG REWRITE`.

## Network

| Parameter | Default | Notes |
|-----------|---------|-------|
| `bind` | `* -::*` | Listens on all interfaces. Production: bind to specific IPs. Runtime-modifiable. |
| `port` | `6379` | `0` to disable plaintext (TLS-only). |
| `protected-mode` | `yes` | Rejects external connections when no password is set and bind is default. |
| `tcp-backlog` | `511` | Immutable. Capped by kernel `somaxconn`. |
| `tcp-keepalive` | `300` | |
| `timeout` | `0` | Idle client timeout; `0` = never. |
| `maxclients` | `10000` | |
| `mptcp` | `no` | Multipath TCP (Valkey 9.0+, Linux 5.6+). Immutable. Requires `mptcp yes` / `repl-mptcp yes`. |

Unix socket: `unixsocket` + `unixsocketperm 770` + `unixsocketgroup <shared>`. The default `unixsocketperm 0` means the file inherits the umask, so local-client connections may silently fail for other users.

## Memory and eviction

| Parameter | Default | Notes |
|-----------|---------|-------|
| `maxmemory` | `0` | Unlimited. **Always set explicitly** - otherwise OOM killer fires. |
| `maxmemory-policy` | `noeviction` | Source default is `noeviction`, not `allkeys-lru`. |
| `maxmemory-clients` | `0` | Valkey-only. Caps aggregate client buffer memory. Accepts `5%` - evaluated at SET time. Replica output buffers and repl backlog are NOT counted. |
| `maxmemory-samples` | `5` | LRU/LFU sample count. Above 10 is diminishing returns. |
| `maxmemory-eviction-tenacity` | `10` | 0-100. |

`maxmemory` should leave 30-40% RAM for fork COW + client buffers + OS. Cache-only workloads can push to 80%; write-heavy AOF+RDB setups should stay at 50-60%.

All 8 policy names are identical to Redis (`noeviction`, `allkeys-lru/lfu/random`, `volatile-lru/lfu/random/ttl`). `volatile-*` with no TTL-bearing keys behaves like `noeviction`.

## Encoding thresholds

Standard compact-encoding model (listpack, intset, quicklist, skiplist). Once a collection upgrades to hashtable/skiplist it stays there until DEL + re-add.

| Parameter | Valkey default | Redis default |
|-----------|---------------|---------------|
| `hash-max-listpack-entries` | `512` | `128` |
| `hash-max-listpack-value` | `64` | `64` |
| `zset-max-listpack-entries` | `128` | `128` |
| `zset-max-listpack-value` | `64` | `64` |
| `set-max-intset-entries` | `512` | `512` |
| `set-max-listpack-entries` | `128` | `128` |

The `hash-max-listpack-entries 512` default is 4x Redis - more hashes stay compact. Check encoding: `OBJECT ENCODING mykey`, `MEMORY USAGE mykey`.

## Persistence - RDB

| Parameter | Default | Notes |
|-----------|---------|-------|
| `save` | `3600 1 300 100 60 10000` | 1 change/h OR 100/5m OR 10000/1m. Initialized in `initServerConfig`, not the config table. |
| `dbfilename` | `dump.rdb` | |
| `dir` | `./` | |
| `rdbchecksum` | `yes` | CRC64. |
| `rdbcompression` | `yes` | LZF. |
| `stop-writes-on-bgsave-error` | `yes` | Failed BGSAVE blocks writes until cleared. Common "disk full → writes frozen" incident source. |
| `rdb-save-incremental-fsync` | `yes` | |
| `rdb-del-sync-files` | `no` | |
| `rdb-version-check` | `strict` | Valkey-only. `strict` rejects foreign RDB range (12-79); `relaxed` allows loading RDBs from forks. |

## Persistence - AOF

| Parameter | Default | Notes |
|-----------|---------|-------|
| `appendonly` | `no` | |
| `appendfilename` | `appendonly.aof` | Immutable. |
| `appenddirname` | `appendonlydir` | Immutable. Multi-part AOF (BASE + INCR + manifest). |
| `appendfsync` | `everysec` | |
| `auto-aof-rewrite-percentage` | `100` | |
| `auto-aof-rewrite-min-size` | `64mb` | |
| `aof-use-rdb-preamble` | `yes` | Preamble accepts either `REDIS` or `VALKEY` magic on load. |
| `aof-load-truncated` | `yes` | |
| `aof-timestamp-enabled` | `no` | |
| `no-appendfsync-on-rewrite` | `no` | `yes` silently disables `appendfsync always` during rewrites. |

## I/O threads

| Parameter | Default | Notes |
|-----------|---------|-------|
| `io-threads` | `1` | 1 = single-threaded. Range 1-256. DEBUG_CONFIG flag. |
| `io-threads-do-reads` | deprecated | In `deprecated_configs[]`. Reads are always offloaded when `io-threads > 1`. |
| `events-per-io-thread` | `2` | `HIDDEN_CONFIG`. Not shown in `CONFIG GET *`. Still tunable via `CONFIG SET`. Events needed per active worker in `adjustIOThreadsByEventLoad`. |
| `min-io-threads-avoid-copy-reply` | `7` | `HIDDEN_CONFIG`. Threshold for zero-copy response path. |
| `prefetch-batch-max-size` | `16` | Pipeline memory prefetch batch size. Range 0-128. `0`/`1` disables. |
| `dynamic-hz` | deprecated | Auto-scaling is always on. |

## Logging

| Parameter | Default | Notes |
|-----------|---------|-------|
| `loglevel` | `notice` | `debug / verbose / notice / warning / nothing`. |
| `logfile` | `""` | Immutable. Empty = stdout. |
| `log-format` | `legacy` | Valkey-only. `legacy / logfmt / json`. Runtime-modifiable. |
| `log-timestamp-format` | `legacy` | Valkey-only. `legacy / iso8601 / milliseconds`. |
| `syslog-enabled` | `no` | Immutable. |
| `hide-user-data-from-log` | `yes` | Valkey-only default. Redacts keys/values from log messages. |

When shipping logs to Loki/ELK/Datadog, switch to `json` + `iso8601`.

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

All three COMMANDLOG types share a unified `COMMANDLOG GET/LEN/RESET` command family. `SLOWLOG *` still works as an alias for the slow-log type. Use `commandlog-*` names in configs; `slowlog-*` aliases still work at runtime.

## Replication (Valkey primary names)

| Parameter | Default | Legacy alias |
|-----------|---------|--------------|
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
| `cluster-allow-pubsubshard-when-down` | `yes` | Shard pub/sub keeps working when cluster is in FAIL state. Same default as Redis 7.0+. |
| `cluster-replica-validity-factor` | `10` | |
| `cluster-migration-barrier` | `1` | |
| `cluster-allow-replica-migration` | `yes` | |
| `cluster-slot-stats-enabled` | `no` | Valkey-only. Enables per-slot CPU + network accounting for `CLUSTER SLOT-STATS`. |
| `availability-zone` | `""` | Valkey-only. Gossiped; surfaced in `CLUSTER SHARDS`/`SLOTS`. |

## Lazy-free (all five defaults flipped in Valkey)

| Parameter | Valkey default | Redis default |
|-----------|---------------|---------------|
| `lazyfree-lazy-eviction` | `yes` | `no` |
| `lazyfree-lazy-expire` | `yes` | `no` |
| `lazyfree-lazy-server-del` | `yes` | `no` |
| `lazyfree-lazy-user-del` | `yes` | `no` |
| `lazyfree-lazy-user-flush` | `yes` | `no` |

All runtime-modifiable. `DEL`, `FLUSH*`, maxmemory eviction, TTL expiry, and server-internal replacements go to BIO background deallocation.

### What each covers

- **`lazy-eviction`** - keys removed by `maxmemory-policy`.
- **`lazy-expire`** - active (periodic) and lazy (on-access) TTL expiry.
- **`lazy-server-del`** - server-internal implicit deletions (`RENAME` target, `SET` replacing old value, `DEBUG RELOAD` swaps).
- **`lazy-user-del`** - user `DEL`. With `yes`, `DEL` behaves like `UNLINK`.
- **`lazy-user-flush`** - `FLUSHDB`/`FLUSHALL` without explicit `ASYNC` behave as if `ASYNC`.

`ASYNC`/`SYNC` modifiers on `FLUSH*` override the config per-invocation. Still prefer explicit `UNLINK` in app code so a future `CONFIG SET lazyfree-lazy-user-del no` can't silently reintroduce blocking deletes.

### Replication interaction

Lazy-free is local to each node. When the primary rewrites `DEL` as unlink+BIO-free, **the replication stream still contains `DEL`** - replicas apply their own lazyfree settings. Keep replica settings consistent with primary.

### Observability

```
valkey-cli INFO stats | grep lazyfree
# lazyfree_pending_objects:<N>
```

Climbing `N` under sustained delete pressure is transient; if sustained, check BIO thread CPU.

## Pub/Sub

| Parameter | Default | Notes |
|-----------|---------|-------|
| `client-output-buffer-limit pubsub` | `32mb 8mb 60` | |
| `notify-keyspace-events` | `""` | Disabled. |
| `acl-pubsub-default` | `resetchannels` | New users have no channel access. |

Sharded Pub/Sub (`SSUBSCRIBE`/`SPUBLISH`) routes by hash slot in cluster mode. `cluster-allow-pubsubshard-when-down yes` (default) keeps it working when the cluster is FAIL. For critical subscribers under `maxmemory-clients` pressure, use `CLIENT NO-EVICT on`.

## Active expiration

| Parameter | Default | Notes |
|-----------|---------|-------|
| `active-expire-effort` | `1` | 1-10. Each step ~25% more keys/cycle. Raise to 3-5 only if `expired_stale_perc` (INFO) consistently >10. Effort 10 burns real CPU. |
| `hz` | `10` | Timer frequency. |

## CPU pinning

`server-cpulist`, `bio-cpulist`, `aof-rewrite-cpulist`, `bgsave-cpulist` take Linux cpulist syntax (`0-3`, `0,2,4`, `0-7:2`). All immutable. Only pin on dedicated/NUMA hosts - pinning on a shared VM where topology can shift (live migration, vCPU hotplug) makes latency worse.

## Protocol limits

`client-query-buffer-limit` (default 1 GiB) and `proto-max-bulk-len` (default 512 MiB) are runtime-modifiable. On memory-tight instances lower both - defaults are generous for Redis-era large-blob patterns. Cache/session workloads typically want 64 MB / 16 MB.

## Shutdown and OOM

`shutdown-on-sigint` / `shutdown-on-sigterm` / `shutdown-timeout`. Flag combinations: `default`, `save`, `nosave`, `now`, `force`, `safe`, `failover`. Multi-flag: `shutdown-on-sigterm save safe` - Valkey refuses to exit if the save fails. `failover` triggers Sentinel/cluster promotion before shutdown (useful for rolling restarts).

`oom-score-adj` and `oom-score-adj-values` default `{0, 200, 800}` (main / child-before-save / child-during-save). `oom-score-adj relative` on a multi-tenant host makes BGSAVE/BGREWRITEAOF children die before the serving process.

## General

| Parameter | Default | Notes |
|-----------|---------|-------|
| `databases` | `16` | Immutable. |
| `disable-thp` | `yes` | |
| `activerehashing` | `yes` | |
| `busy-reply-threshold` | `5000` ms | Alias: `lua-time-limit`. Triggers BUSY error. |

## Interactions worth remembering

- `maxmemory` vs `maxmemory-policy` - policy is a no-op unless maxmemory is set.
- `client-output-buffer-limit replica` vs `repl-backlog-size` - replica limit must be `>= repl-backlog-size` or partial resync fails and triggers a full resync storm.
- `stop-writes-on-bgsave-error yes` vs `save` - after a failed BGSAVE, all writes reject until next successful save or until you disable this. Common confusion during disk-full incidents.
- `appendfsync always` vs `no-appendfsync-on-rewrite yes` - the second silently downgrades the first during rewrites. Either accept it or set `no-appendfsync-on-rewrite no` and provision disk I/O for both concurrent fsync paths.
- `maxmemory-clients` with `%` is a percentage of `maxmemory` - evaluated at SET time, not reactively.
