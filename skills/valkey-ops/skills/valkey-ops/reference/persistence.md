# Persistence

Use when configuring RDB/AOF, planning backup strategy, or recovering from disaster.

## RDB - `save` directives

Defaults (set in `initServerConfig`, not the config table):

```
save 3600 1
save 300 100
save 60 10000
```

= snapshot if ≥1 write in 1h OR 100 in 5m OR 10000 in 1m. Disable with `save ""`.

## RDB - config

| Parameter | Default | Notes |
|-----------|---------|-------|
| `dbfilename` | `dump.rdb` | Empty → no RDB file written; `BGSAVE` becomes a no-op. |
| `dir` | `./` | Working dir for RDB + AOF + nodes.conf. |
| `rdbcompression` | `yes` | LZF. ~10-20% CPU on save for ~30-50% shrink. |
| `rdbchecksum` | `yes` | **Immutable.** CRC64 tail, ~10% save/load overhead. |
| `stop-writes-on-bgsave-error` | `yes` | Failed BGSAVE blocks writes until cleared. |
| `rdb-save-incremental-fsync` | `yes` | Fsync every 32 MB during save; smooths I/O. |
| `rdb-del-sync-files` | `no` | Delete replication-generated RDBs immediately. |
| `rdb-version-check` | `strict` | **Valkey-only.** `strict` rejects foreign RDB range (12-79, i.e. Redis CE 7.4+); `relaxed` attempts to load anyway. |

## RDB - commands

| Command | Notes |
|---------|-------|
| `BGSAVE` | Fork + write in background. |
| `BGSAVE SCHEDULE` | Queue behind an in-flight AOF rewrite. |
| `BGSAVE CANCEL` | Valkey 8.1+. Kills the fork or cancels a scheduled BGSAVE. Emergency stop when fork memory is blowing up. |
| `SAVE` | Synchronous - blocks all clients. Emergency only. |
| `LASTSAVE` | Unix timestamp of last successful save. |

## RDB - magic and version

Valkey 9.0+ writes RDB version **80** with magic `VALKEY080`. Loader accepts both `VALKEY080` and `REDIS0011` (RDB 11, pre-9.0) on the same code path. Redis CE 7.4+ writes into the foreign range (`RDB_FOREIGN_VERSION_MIN=12`, `MAX=79`) which Valkey rejects by default - set `rdb-version-check relaxed` to attempt loading them (at your own risk for CE-specific features).

## Fork / COW

```
latest_fork_usec     # INFO stats
rdb_last_cow_size    # INFO persistence - peak COW during save
```

Page-table cost: `page_table_bytes ≈ dataset_bytes / 4096 * 8`. Above 24 GB dataset, fork alone is tens of ms even on fast hardware.

COW rules of thumb:
- Read-only traffic during save: near-zero COW.
- Moderate writes: 10-30% of dataset duplicated.
- Write-heavy: COW can approach **2× dataset**. Plan `maxmemory` accordingly (60-70% of node RAM for AOF+RDB write-heavy setups).

**Always disable THP.** With transparent huge pages, COW granularity becomes 2 MB per touched page instead of 4 KB → near-total duplication during save. `echo never > /sys/kernel/mm/transparent_hugepage/enabled`.

## AOF - config

| Parameter | Default | Notes |
|-----------|---------|-------|
| `appendonly` | `no` | |
| `appendfsync` | `everysec` | |
| `aof-use-rdb-preamble` | `yes` | Hybrid mode. Preamble accepts `REDIS` or `VALKEY` magic on load. |
| `no-appendfsync-on-rewrite` | `no` | |
| `auto-aof-rewrite-percentage` | `100` | |
| `auto-aof-rewrite-min-size` | `64mb` | |
| `aof-load-truncated` | `yes` | |
| `aof-timestamp-enabled` | `no` | Required for point-in-time recovery. |
| `appendfilename` | `appendonly.aof` | **Immutable** - plan at deployment. |
| `appenddirname` | `appendonlydir` | **Immutable.** Multi-part AOF. |

## AOF - multi-part architecture

Since 7.0, AOF uses a manifest file + multiple files in `appendonlydir/`:
- Base file: `.base.rdb` (hybrid) or `.base.aof`
- Incremental files: `.incr.aof`

Load precedence: when both RDB and AOF exist, Valkey loads AOF (more complete).

## AOF - commands

```sh
valkey-cli BGREWRITEAOF
valkey-check-aof --fix appendonlydir/appendonly.aof.1.incr.aof
```

## AOF - worst-case data loss

`appendfsync everysec` can lose up to **2 seconds** (not 1). If background fsync takes >1 s, a blocking write is forced after the second second.

## Hybrid persistence (recommended)

```
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes
```

Fast restarts (RDB base) + high durability (AOF incremental).

## Pure-cache setup

```
save ""
dbfilename ""
appendonly no
stop-writes-on-bgsave-error no
```

`dbfilename ""` + `save ""` makes BGSAVE a no-op and skips initial load attempt. **Pair with the primary-without-persistence warning in `replication.md`** - systemd auto-restart of an empty primary wipes replicas.

## Backup strategies

### RDB backup trigger

```sh
valkey-cli -a $VALKEY_PASSWORD BGSAVE
valkey-cli -a $VALKEY_PASSWORD LASTSAVE   # poll for completion
```

### AOF hardlink backup window

Disable auto-rewrite temporarily, hardlink, re-enable:

```sh
valkey-cli CONFIG SET auto-aof-rewrite-percentage 0
# ... hardlink appendonlydir/ ...
valkey-cli CONFIG SET auto-aof-rewrite-percentage 100
```

### Replica-based backup

```
replicaof primary-host 6379
replica-priority 0    # never promote this replica
```

### Retention tiers

Hourly (24h local), daily (30d local+offsite), weekly (90d offsite), monthly (1yr cold storage). Always verify restores - see below.

## Disaster recovery

### RDB restore

```sh
sudo systemctl stop valkey
cp /backups/dump_DATE.rdb /var/lib/valkey/dump.rdb
chown valkey:valkey /var/lib/valkey/dump.rdb
sudo systemctl start valkey
valkey-cli DBSIZE
```

### Accidental FLUSHALL

Stop server immediately, edit the last `.incr.aof` file in `appendonlydir/`, remove the FLUSHALL line, restart. **Do not let the server rewrite the AOF before stopping** - rewrite coalesces the flush into the base file.

### Point-in-time recovery

```sh
valkey-check-aof --truncate-to-timestamp 1711699200 \
  appendonlydir/appendonly.aof.manifest
```

Requires `aof-timestamp-enabled yes` set **before** the incident.

### Backup verification

```sh
valkey-server --port 6399 --dir /tmp/valkey-verify \
  --dbfilename backup.rdb --daemonize yes
valkey-cli -p 6399 DBSIZE
valkey-cli -p 6399 SHUTDOWN NOSAVE
```

## Monitoring

Alert on:
- `rdb_last_bgsave_status != ok` on primary.
- `rdb_changes_since_last_save` climbing unbounded = `save` rules not triggering (disk full? permission denied?).
- `rdb_last_cow_size` approaching `used_memory` during save (COW storm, likely THP).
- `latest_fork_usec > 500000` (500 ms) - slow kernel fork path (check virtualization overhead).
