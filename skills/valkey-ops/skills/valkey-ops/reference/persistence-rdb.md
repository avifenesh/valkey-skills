# RDB Snapshots

Use when configuring or tuning RDB. Redis-baseline semantics carry over; this file is the Valkey-specific operational delta.

## `save` directives

`save <seconds> <changes>` triggers automatic BGSAVE. Defaults (set in `initServerConfig`, not the config table):

```
save 3600 1
save 300 100
save 60 10000
```

= snapshot if at least 1 write in 1 h OR 100 writes in 5 min OR 10000 writes in 1 min. Disable with `save ""`.

## Core knobs

| Parameter | Default | Notes |
|-----------|---------|-------|
| `dbfilename` | `dump.rdb` | Empty → no RDB file written; `BGSAVE` becomes a no-op. Useful for pure-cache setups. |
| `dir` | `./` | Working dir for RDB + AOF + nodes.conf. |
| `rdbcompression` | `yes` | LZF. ~10-20% CPU on save for ~30-50% file shrink. |
| `rdbchecksum` | `yes` | **Immutable.** CRC64 tail, ~10% save/load overhead. |
| `stop-writes-on-bgsave-error` | `yes` | Failed BGSAVE blocks writes until cleared. |
| `rdb-save-incremental-fsync` | `yes` | Fsync every 32 MB during save; smooths I/O. |
| `rdb-del-sync-files` | `no` | Delete replication-generated RDBs immediately. |
| `rdb-version-check` | `strict` | **Valkey-only.** `strict` rejects foreign RDB range (12-79, i.e. Redis CE 7.4+); `relaxed` attempts to load anyway. |

## RDB commands

| Command | Notes |
|---------|-------|
| `BGSAVE` | Fork + write in background. |
| `BGSAVE SCHEDULE` | Queue behind an in-flight AOF rewrite. |
| `BGSAVE CANCEL` | Valkey 8.1+. Kills the fork or cancels a scheduled BGSAVE. Emergency stop when fork memory is blowing up. |
| `SAVE` | Synchronous - blocks all clients. Emergency only. |
| `LASTSAVE` | Unix timestamp of last successful save. |

## Magic + version

Valkey 9.0+ writes RDB version **80** with magic `VALKEY080`. Loader accepts both `VALKEY080` (new) and `REDIS0011` (RDB 11, pre-Valkey-9.0) on the same code path. Redis CE 7.4+ writes into the foreign range (`RDB_FOREIGN_VERSION_MIN = 12`, `MAX = 79`) which Valkey rejects by default - set `rdb-version-check relaxed` to attempt loading them (at your own risk for CE-specific features).

## Fork overhead sanity check

```
latest_fork_usec     # INFO stats
rdb_last_cow_size    # INFO persistence - peak COW during save
```

Page-table cost formula: `page_table_bytes = dataset_bytes / 4096 * 8` (approx). Above 24 GB dataset, fork alone is tens of ms even on fast hardware.

COW overhead rules of thumb:
- Read-only traffic during save: near-zero COW.
- Moderate writes: 10-30% of dataset duplicated.
- Write-heavy: COW can approach **2× dataset size**. Plan `maxmemory` accordingly (60-70% of node RAM for AOF+RDB write-heavy setups).

**Always disable THP.** With transparent huge pages enabled, COW granularity becomes 2 MB per touched page instead of 4 KB → near-total memory duplication during save. `echo never > /sys/kernel/mm/transparent_hugepage/enabled`.

## Pure-cache setup (no RDB, no AOF)

```
save ""
dbfilename ""
appendonly no
stop-writes-on-bgsave-error no
```

`dbfilename ""` + `save ""` makes BGSAVE a no-op and skips the initial load attempt. Use when the Valkey instance is truly ephemeral cache - and pair with the **primary-without-persistence incident pattern** warning in `replication-safety.md` (systemd auto-restart of an empty primary wipes replicas).

## Monitoring

Alert on:
- `rdb_last_bgsave_status != ok` on primary.
- `rdb_changes_since_last_save` climbing unbounded = `save` rules not triggering (disk full? permission denied?).
- `rdb_last_cow_size` approaching `used_memory` during save (COW storm, likely THP).
- `latest_fork_usec > 500000` (500 ms) on any dataset - indicates slow kernel fork path (check virtualization overhead).
