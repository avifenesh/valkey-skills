# Essential Configuration

Use when setting up a new Valkey instance or auditing an existing config. All defaults verified against `src/config.c` in the Valkey source.

---

Valkey reads configuration from `valkey.conf`. Most parameters can be changed at runtime via `CONFIG SET` and queried via `CONFIG GET`. To persist runtime changes: `CONFIG REWRITE`.

## Network

| Parameter | Default | Description |
|-----------|---------|-------------|
| `bind` | `* -::*` | Interfaces to listen on. Default accepts all. Production: bind to specific IPs. |
| `port` | `6379` | TCP port for client connections. Set to 0 to disable non-TLS. |
| `protected-mode` | `yes` | Rejects external connections when no password is set and bind is default. |
| `tcp-backlog` | `511` | TCP listen backlog. Capped by kernel `somaxconn` - tune both. |
| `tcp-keepalive` | `300` | Seconds between TCP keepalive probes. Detects dead peers. |
| `timeout` | `0` | Idle client timeout in seconds. 0 means never disconnect idle clients. |
| `maxclients` | `10000` | Maximum simultaneous client connections. |
| `mptcp` | `no` | Multipath TCP support. |

Note: `bind` defaults to `* -::*` in the source (`CONFIG_DEFAULT_BINDADDR`), which listens on all interfaces. The research guide shows `127.0.0.1 -::1` as the recommended production setting. When `protected-mode` is `yes` and no password is set, external connections are rejected regardless of bind address.

## Memory

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxmemory` | `0` (unlimited) | Hard memory limit in bytes. Set explicitly in production. |
| `maxmemory-policy` | `noeviction` | What to do when maxmemory is reached. See [eviction policies](eviction.md). |
| `maxmemory-clients` | `0` (disabled) | Max aggregate memory for client buffers. Accepts bytes or percentage (e.g., `5%`). |
| `maxmemory-samples` | `5` | Number of keys sampled for LRU/LFU approximation. Higher = more accurate but slower. |
| `maxmemory-eviction-tenacity` | `10` | Effort level for eviction (0-100). Higher values try harder to meet maxmemory. |

**Source verification note**: The research guide lists `maxmemory-policy allkeys-lru` as a default. This is incorrect - the source default is `noeviction` (`MAXMEMORY_NO_EVICTION` at line 3339 in config.c). The guide was showing a recommended value, not the actual default.

## Persistence - RDB

| Parameter | Default | Description |
|-----------|---------|-------------|
| `save` | (see note) | Snapshot triggers. Format: `save <seconds> <changes>`. |
| `dbfilename` | `dump.rdb` | RDB snapshot filename. |
| `dir` | `./` | Working directory for RDB and AOF files. |
| `rdbchecksum` | `yes` | CRC64 checksum at end of RDB file. |
| `rdbcompression` | `yes` | LZF compression for string objects in RDB. |
| `stop-writes-on-bgsave-error` | `yes` | Reject writes if BGSAVE fails. Safety mechanism. |
| `rdb-save-incremental-fsync` | `yes` | Fsync every 32MB during RDB save. Avoids I/O spikes. |
| `rdb-del-sync-files` | `no` | Delete replication-generated RDB files immediately after use. |

Note on `save` defaults: The default save rules are set in the `initServerConfig` function, not in the config table. The typical default is `save 3600 1 300 100 60 10000`.

## Persistence - AOF

| Parameter | Default | Description |
|-----------|---------|-------------|
| `appendonly` | `no` | Enable Append-Only File persistence. |
| `appendfilename` | `appendonly.aof` | Base name of the AOF file. |
| `appenddirname` | `appendonlydir` | Directory for multi-part AOF files (Valkey 7+). |
| `appendfsync` | `everysec` | Fsync policy: `always`, `everysec`, or `no`. |
| `auto-aof-rewrite-percentage` | `100` | Trigger rewrite when AOF grows by this percentage. |
| `auto-aof-rewrite-min-size` | `64mb` | Minimum AOF size before auto-rewrite kicks in. |
| `aof-use-rdb-preamble` | `yes` | Hybrid format: RDB snapshot + AOF tail. Faster loading. |
| `aof-load-truncated` | `yes` | Load truncated AOF instead of refusing to start. |
| `aof-rewrite-incremental-fsync` | `yes` | Fsync every 32MB during AOF rewrite. |
| `no-appendfsync-on-rewrite` | `no` | Skip fsync during BGSAVE/BGREWRITEAOF. Trades safety for performance. |
| `aof-timestamp-enabled` | `no` | Add timestamps to AOF entries. |

## I/O Threads

| Parameter | Default | Description |
|-----------|---------|-------------|
| `io-threads` | `1` | Number of I/O threads. 1 = single-threaded (classic mode). Max: 256. |

**Source verification note**: The research guide mentions `io-threads-do-reads yes` as a configuration parameter. In the current Valkey source, `io-threads-do-reads` is a deprecated config (listed in `deprecated_configs[]` at line 459 of config.c). When `io-threads` > 1, reads are always offloaded to I/O threads. This parameter is silently ignored if present in config files.

Similarly, `dynamic-hz` is deprecated - the behavior it controlled is now always on.

## Logging

| Parameter | Default | Description |
|-----------|---------|-------------|
| `loglevel` | `notice` | Log verbosity: `debug`, `verbose`, `notice`, `warning`, `nothing`. |
| `logfile` | `""` (stdout) | Log file path. Empty string logs to stdout. |
| `log-format` | `legacy` | Log output format: `legacy`, `logfmt`, `json`. |
| `log-timestamp-format` | `legacy` | Timestamp format: `legacy`, `iso8601`, `milliseconds`. |
| `syslog-enabled` | `no` | Send logs to syslog. |
| `syslog-ident` | `valkey` | Syslog identity string. |
| `syslog-facility` | `local0` | Syslog facility. |

## Command Log (Slow Log)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `commandlog-execution-slower-than` | `10000` | Log commands slower than N microseconds. Alias: `slowlog-log-slower-than`. |
| `commandlog-slow-execution-max-len` | `128` | Max entries in slow command log. Alias: `slowlog-max-len`. |
| `commandlog-request-larger-than` | `1048576` | Log requests larger than N bytes (1MB default). |
| `commandlog-large-request-max-len` | `128` | Max entries in large request log. |
| `commandlog-reply-larger-than` | `1048576` | Log replies larger than N bytes (1MB default). |
| `commandlog-large-reply-max-len` | `128` | Max entries in large reply log. |
| `latency-monitor-threshold` | `0` | Latency monitoring threshold in ms. 0 = disabled. |
| `latency-tracking` | `yes` | Per-command latency histogram tracking. |

## Replication

| Parameter | Default | Description |
|-----------|---------|-------------|
| `repl-diskless-sync` | `yes` | Send RDB over socket instead of writing to disk first. |
| `repl-diskless-sync-delay` | `5` | Seconds to wait for more replicas before starting diskless transfer. |
| `repl-diskless-load` | `disabled` | Replica loads RDB from socket: `disabled`, `on-empty-db`, `swapdb`, `flush-before-load`. |
| `repl-backlog-size` | `10mb` | Size of replication backlog for partial resync. |
| `repl-backlog-ttl` | `3600` | Seconds before freeing backlog when no replicas connected. |
| `repl-timeout` | `60` | Replication timeout in seconds. |
| `repl-ping-replica-period` | `10` | Seconds between PING to replicas. |
| `repl-disable-tcp-nodelay` | `no` | When yes, uses larger TCP packets (more latency, less bandwidth). |
| `replica-serve-stale-data` | `yes` | Serve requests while syncing with primary. |
| `replica-read-only` | `yes` | Reject writes on replicas. |
| `replica-lazy-flush` | `yes` | Async FLUSHALL on replica before full resync. |
| `replica-ignore-maxmemory` | `yes` | Replicas don't enforce maxmemory (primary handles eviction). |
| `replica-priority` | `100` | Priority for Sentinel promotion. Lower = preferred. 0 = never promote. |
| `min-replicas-to-write` | `0` | Minimum replicas that must acknowledge before primary accepts writes. 0 = disabled. |
| `min-replicas-max-lag` | `10` | Maximum replication lag in seconds for a replica to count toward min-replicas-to-write. |

## Cluster

| Parameter | Default | Description |
|-----------|---------|-------------|
| `cluster-enabled` | `no` | Enable cluster mode. Immutable - requires restart. |
| `cluster-config-file` | `nodes.conf` | Auto-managed cluster state file. |
| `cluster-node-timeout` | `15000` | Milliseconds before a node is considered failing. |
| `cluster-require-full-coverage` | `yes` | Reject queries if any hash slot is uncovered. |
| `cluster-allow-reads-when-down` | `no` | Allow reads when cluster is down (not all slots covered). |
| `cluster-allow-pubsubshard-when-down` | `yes` | Allow shard pub/sub when cluster is down. |
| `cluster-replica-validity-factor` | `10` | Factor multiplied by node-timeout to determine max replica data age for failover. |
| `cluster-migration-barrier` | `1` | Min replicas a primary must retain before donating one to an orphan primary. |
| `cluster-allow-replica-migration` | `yes` | Allow automatic replica migration between primaries. |

## General

| Parameter | Default | Description |
|-----------|---------|-------------|
| `databases` | `16` | Number of databases (DB 0-15). Immutable. |
| `hz` | `10` | Server timer frequency in calls/sec. Higher = more responsive but more CPU. |
| `disable-thp` | `yes` | Disable Transparent Huge Pages for the Valkey process. |
| `activerehashing` | `yes` | Incrementally rehash hash tables in background. |
| `lazyfree-lazy-eviction` | `yes` | Async free on eviction. |
| `lazyfree-lazy-expire` | `yes` | Async free on key expiration. |
| `lazyfree-lazy-server-del` | `yes` | Async free on server-side DEL (e.g., RENAME). |
| `lazyfree-lazy-user-del` | `yes` | DEL command behaves like UNLINK (async free). |
| `lazyfree-lazy-user-flush` | `yes` | FLUSHDB/FLUSHALL default to async mode. |
| `hide-user-data-from-log` | `yes` | Redact user data (keys, values) from log messages. |
| `busy-reply-threshold` | `5000` | Milliseconds before long-running script triggers BUSY error. Alias: `lua-time-limit`. |
| `proto-max-bulk-len` | `512mb` | Maximum size of a single RESP bulk string. |


## See Also

- [Eviction Policies](eviction.md) - maxmemory-policy details
- [Encoding Thresholds](encoding.md) - compact encoding tuning
- [Workload Presets](workload-presets.md) - complete configs by use case
- [Advanced Configuration](advanced.md) - logging, shutdown, OOM, CPU pinning
- [See valkey-dev: config system](../valkey-dev/reference/config/config-system.md) - config parsing, validation, and rewrite internals
- [See valkey-dev: db management](../valkey-dev/reference/config/db-management.md) - database selection and key space internals
