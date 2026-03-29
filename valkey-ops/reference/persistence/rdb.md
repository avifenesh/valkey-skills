# RDB Snapshot Persistence

Use when configuring point-in-time snapshots, tuning BGSAVE behavior, or understanding RDB trade-offs for backup and recovery scenarios.

Source: `src/config.c`, `src/rdb.c` (Valkey source). Cross-ref: valkey-dev `reference/persistence/rdb.md` for binary format internals.

---

## When to Use RDB

- You need fast restarts from a compact binary file
- You want periodic backups with minimal runtime overhead
- Some data loss between snapshots is acceptable
- You need to ship snapshots to off-site storage

## Trade-offs

| Strength | Weakness |
|----------|----------|
| Compact single-file format | Data loss between snapshots |
| Fast server restart | Fork can cause latency spikes with large datasets |
| Low runtime overhead | Copy-on-write doubles memory during save (worst case) |
| Ideal for backups and disaster recovery | Not suitable for zero-data-loss requirements |

## Configuration Reference

All defaults verified against `src/config.c` in the Valkey source tree.

### Save Directives

The `save` directive triggers automatic background snapshots. Format: `save <seconds> <changes>`.

```
save 3600 1        # snapshot if >= 1 write in 3600 seconds
save 300 100       # snapshot if >= 100 writes in 300 seconds
save 60 10000      # snapshot if >= 10000 writes in 60 seconds
```

These are the compiled defaults (from `server.c`):

```c
appendServerSaveParams(60*60, 1);   // save after 1 hour and 1 change
appendServerSaveParams(300, 100);   // save after 5 minutes and 100 changes
appendServerSaveParams(60, 10000);  // save after 1 minute and 10000 changes
```

To disable automatic RDB snapshots entirely:

```
save ""
```

### Core Parameters

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `dbfilename` | `dump.rdb` | Yes (protected) | RDB file name |
| `dir` | `./` | Yes | Working directory for RDB and AOF files |
| `rdbcompression` | `yes` | Yes | LZF compression for string values |
| `rdbchecksum` | `yes` | No (immutable) | CRC64 checksum at end of file |
| `stop-writes-on-bgsave-error` | `yes` | Yes | Reject writes if last BGSAVE failed |
| `rdb-save-incremental-fsync` | `yes` | Yes | Fsync every 32MB during RDB save |
| `rdb-del-sync-files` | `no` | Yes | Delete RDB files created for replication |
| `rdb-version-check` | `strict` | Yes | RDB version validation mode (`strict` or `relaxed`) |

Note: `rdbchecksum` is IMMUTABLE - it cannot be changed at runtime via CONFIG SET. Plan this at deployment time.

### RDB Commands

| Command | Behavior | Use Case |
|---------|----------|----------|
| `BGSAVE` | Fork child process, write RDB in background | Production snapshots - non-blocking |
| `SAVE` | Write RDB synchronously, blocks all clients | Emergency only - avoid in production |
| `BGSAVE SCHEDULE` | Schedule BGSAVE when no AOF rewrite is running | Safe scheduling (since 3.2.2) |
| `BGSAVE CANCEL` | Terminate in-progress RDB save or scheduled BGSAVE | Emergency fork termination (8.1+) |
| `LASTSAVE` | Returns Unix timestamp of last successful save | Monitoring and backup verification |
| `DEBUG RELOAD` | Save + quit + restart + load | Testing only |

`BGSAVE CANCEL` (Valkey 8.1.0+) immediately terminates any in-progress RDB
save, replication full sync, or scheduled save. Use for emergency stop when
a fork is consuming too much memory.

## Operational Procedures

### Verify RDB Is Working

```bash
# Check last save status
valkey-cli INFO persistence | grep rdb_

# Key fields:
# rdb_last_save_time       - epoch of last successful save
# rdb_last_bgsave_status   - ok or err
# rdb_last_bgsave_time_sec - duration of last BGSAVE
# rdb_changes_since_last_save - unsaved write count
```

### Trigger Manual Snapshot

```bash
# Background save (non-blocking)
valkey-cli BGSAVE

# Wait for completion
while [ "$(valkey-cli LASTSAVE)" = "$PREV_LASTSAVE" ]; do
  sleep 1
done
```

### Estimate Fork Overhead

Fork time depends on dataset size and OS copy-on-write behavior. Monitor:

```bash
# Check fork duration in microseconds
valkey-cli INFO stats | grep latest_fork_usec
```

**Page table size formula** (from Valkey latency docs): Linux divides memory
into 4KB pages. Each page requires an 8-byte pointer in the page table.

```
page_table_size = dataset_size / 4KB * 8 bytes
```

| Dataset Size | Page Table Size | Approx Fork Time |
|-------------|-----------------|-------------------|
| 1 GB | 2 MB | ~1-2 ms |
| 10 GB | 20 MB | ~10-20 ms |
| 24 GB | 48 MB | ~24-48 ms |
| 64 GB | 128 MB | ~64-128 ms |
| 128 GB | 256 MB | ~128-256 ms |

**Fork rate quality thresholds** (from LATENCY DOCTOR):
Fork rate = dataset_size / fork_time. < 10 GB/s terrible, < 25 GB/s poor,
< 100 GB/s good, >= 100 GB/s excellent.

**Copy-on-write memory overhead**: Write-heavy workloads during fork can
use up to 2x memory (100% COW). Typical moderate writes: 10-30% additional.
Read-heavy: near-zero. With THP enabled, COW granularity jumps from 4KB to
2MB pages, causing near-total memory duplication - always disable THP.

### Disable RDB for Cache-Only Deployments

```
save ""
dbfilename ""
stop-writes-on-bgsave-error no
```

When `dbfilename` is empty, no RDB file is written and `BGSAVE` becomes a no-op.

## Production Recommendations

1. **Always combine with AOF** for durability - use RDB primarily for backups, not as sole persistence
2. **Set `stop-writes-on-bgsave-error yes`** (the default) to detect disk issues early
3. **Keep `rdbchecksum yes`** (the default) to detect corruption on load (~10% save/load overhead)
4. **Keep `rdbcompression yes`** (the default) to reduce file size and I/O
5. **Monitor `rdb_last_bgsave_status`** in your alerting system
6. **Size memory to 2x dataset** to handle copy-on-write during fork
7. **Disable THP** - causes unpredictable latency during BGSAVE fork

## RDB File Format Overview

For operational purposes, the key facts about the binary format:

- Magic string: `VALKEY080` (Valkey 9.0+) or `REDIS0011` (legacy)
- Ends with CRC64 checksum (8 bytes, little-endian)
- Contains database selectors, key-value pairs, and metadata
- Fully portable across architectures

For full binary format details, see valkey-dev `reference/persistence/rdb.md`.

## See Also

- [AOF Persistence](aof.md) - write-ahead log for higher durability
- [Backup and Recovery](backup-recovery.md) - automated backup procedures
- [Durability vs Performance](../performance/durability.md) - persistence trade-off spectrum
- [Replication Safety](../replication/safety.md) - replica-based backup and write safety
- [Configuration Essentials](../configuration/essentials.md) - RDB config defaults
- [Capacity Planning](../operations/capacity-planning.md) - memory sizing for fork overhead
- [Production Checklist](../production-checklist.md) - pre-launch persistence verification
- [See valkey-dev: rdb](../valkey-dev/reference/persistence/rdb.md) - RDB binary format internals
