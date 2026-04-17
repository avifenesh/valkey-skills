# Replication

Use when setting up primary/replica, tuning backlog, enabling diskless or dual-channel, or hardening against data loss. Redis-baseline PSYNC semantics apply - this file is the Valkey-specific operational layer.

## Terminology

| Redis | Valkey (aliased) |
|-------|------------------|
| `slaveof` | `replicaof` |
| `masterauth` | `primaryauth` |
| `masteruser` | `primaryuser` |
| `slave-read-only` | `replica-read-only` |
| `slave-priority` | `replica-priority` |

Redis names still accepted. `replicaof` is immutable in config files but changeable at runtime via `REPLICAOF`.

## Basic setup

```
replicaof 192.168.1.10 6379
primaryauth YOUR_PASSWORD
replica-read-only yes
```

Verify: `valkey-cli INFO replication` on both sides. On replica check `master_link_status:up`. Promote: `REPLICAOF NO ONE`.

Set `replica-priority 0` on dedicated backup replicas to prevent Sentinel promotion.

## Backlog sizing

The circular buffer on the primary holds recent writes for partial resync (PSYNC CONTINUE). Too small = any disconnect beyond the buffer triggers full resync.

| Parameter | Default | Notes |
|-----------|---------|-------|
| `repl-backlog-size` | 10 MB | Almost always too small for production. |
| `repl-backlog-ttl` | 3600 s | Retain window after last replica disconnects. `0` = retain forever. |

Formula: `repl-backlog-size >= write_rate_bytes_per_sec * max_expected_disconnect_seconds * 2`. The 2× is bursty-traffic headroom.

Measure write rate from offset delta:

```sh
o1=$(valkey-cli INFO replication | awk -F: '/^master_repl_offset:/ {print $2}' | tr -d '\r')
sleep 10
o2=$(valkey-cli INFO replication | awk -F: '/^master_repl_offset:/ {print $2}' | tr -d '\r')
echo "bytes/sec = $(( (o2-o1) / 10 ))"
```

Practical minimums: 256 MB for any prod replication, 1 GB+ for high-write clusters, multi-GB for cross-DC WAN replicas.

Monitor `repl_backlog_first_byte_offset` + `repl_backlog_size` vs `master_repl_offset - slave_repl_offset`. If lag approaches 80% of backlog, a full resync is imminent.

## Diskless replication

| Parameter | Default | Notes |
|-----------|---------|-------|
| `repl-diskless-sync` | `yes` | Primary streams RDB directly over socket. Default differs from old Redis. |
| `repl-diskless-sync-delay` | `5` s | Window to collect multiple replicas for a shared stream. `0` for single-replica. |
| `repl-diskless-sync-max-replicas` | `0` | Trigger immediately when this many replicas are waiting. `0` = disabled. |
| `repl-diskless-load` | `disabled` | Replica-side loading policy. |

Replica-side `repl-diskless-load` values:

| Value | Behavior |
|-------|---------|
| `disabled` | Save RDB to disk first, then load. Safest, most memory-efficient. |
| `on-empty-db` | Load direct-to-memory only when replica DB is empty. |
| `swapdb` | Load into shadow DB, atomic swap on success. Best availability but needs 2× memory. |
| `flush-before-load` | Flush current DB, load direct-to-memory. |

Use diskless when disk I/O is the bottleneck. Keep disk-based if you need RDB file on disk for backups, or when multiple replicas reconnect at different times (disk-based allows RDB reuse; diskless regenerates per-replica unless they arrive in the delay window).

## Dual-channel replication (8.0+)

Full resync uses two TCP connections so the replica buffers streaming writes locally while loading the RDB, instead of the primary buffering per-replica.

| Parameter | Default | Notes |
|-----------|---------|-------|
| `dual-channel-replication-enabled` | `no` | Set `yes` on the replica. |

Primary auto-detects replica's `capa dual-channel` advertisement during PSYNC; silently falls back to single-channel if not supported. Requires `repl-diskless-sync yes` on the primary.

Protocol (for log reading):
- `+DUALCHANNELSYNC` response on PSYNC (code `PSYNC_FULLRESYNC_DUAL_CHANNEL=6`).
- RDB channel: AUTH → `REPLCONF ip-address` → `$ENDOFF:<offset>` → RDB bytes.
- Main channel attaches to backlog at `$ENDOFF` offset and streams writes in parallel.
- Replica buffers main-channel bytes in `server.pending_repl_data` (list of `replDataBufBlock`) until RDB load completes, then drains via `streamReplDataBufToDb()`.

Back-pressure: if `pending_repl_data` exceeds replica-side COB hard limit, replica stops reading main channel; primary's output buffer for that replica grows instead. Net effect is the same as single-channel but shifted, so the replica can apply back-pressure without the primary OOMing.

## Connection tuning

| Parameter | Default | Notes |
|-----------|---------|-------|
| `repl-timeout` | 60 s | Must be > `repl-ping-replica-period`. |
| `repl-ping-replica-period` | 10 s | |
| `repl-disable-tcp-nodelay` | `no` | `no` keeps TCP_NODELAY on. `yes` trades lag for bandwidth. |

## Docker / NAT

Replicas behind NAT need externally-reachable addresses:

```
replica-announce-ip   203.0.113.10
replica-announce-port 16379
```

Reported in `INFO replication` and used by Sentinel. Without these, failover picks an unroutable address.

Docker Compose env injection:

```yaml
valkey-replica:
  image: valkey/valkey:9
  ports: ["6380:6379"]
  command: >
    valkey-server
    --replicaof valkey-primary 6379
    --replica-announce-ip   ${HOST_IP}
    --replica-announce-port 6380
```

Or `--net=host` to skip port mapping.

## Safety - min-replicas

| Parameter | Default | Notes |
|-----------|---------|-------|
| `min-replicas-to-write` | `0` | Minimum online replicas required to accept writes. |
| `min-replicas-max-lag` | `10` s | A replica counts as "online" only if last interaction was within this window. |

Example: `min-replicas-to-write 1` + `min-replicas-max-lag 10` rejects writes with `-NOREPLICAS` when no replica within 10 s. Reads still work. Trade-off: higher `min-replicas-to-write` makes primary read-only during replica maintenance. Typical 1+2 prod: `1`/`10`; strict durability: `2`/`10`.

## WAIT - per-command sync

```
WAIT <numreplicas> <timeout-ms>
```

Blocks until `numreplicas` replicas acknowledge in-memory apply, or timeout. Returns the ack'd count. **Confirms memory apply, not disk fsync.** Doesn't make Valkey strongly consistent - a subsequent failover can still lose writes. Adds latency equal to replication-ACK RTT per call.

## Incident patterns

### 1. Primary without persistence → cascading data loss

Primary runs pure in-memory (no `appendonly`, no `save`). systemd restarts it after crash. It comes back empty. Replicas full-sync from the empty primary and wipe their own data. Total loss.

Prevention:
- Enable persistence on every primary (`appendonly yes` + `save 3600 1 300 100 60 10000`), **or**
- Set `Restart=no` / `Restart=on-failure` + `StartLimitBurst=0` in systemd so the empty primary doesn't come back automatically, **or**
- Run Sentinel with `down-after-milliseconds` tight enough that promotion wins the race.

**Persistence on the primary is the single most important safety knob.**

### 2. Writable replicas

Default is `replica-read-only yes`. Flipping to `no` lets writes land on a replica, where they exist until the next full resync wipes them. Symptoms: phantom writes that vanish post-resync, divergent key counts.

### 3. Network partition split-brain

Classic Sentinel/cluster case: primary + client on one side, replica + failover quorum on the other. Partition heals, old primary becomes replica of the promoted one, writes from the isolated window are lost.

Mitigation: `min-replicas-to-write` + `min-replicas-max-lag` - isolated primary goes read-only after the lag threshold, bounding the write-loss window to roughly `min-replicas-max-lag` seconds.

### 4. Cascading full resyncs

Primary restart or brief network blip → all replicas reconnect simultaneously → undersized `repl-backlog-size` → full resyncs all around. Primary forks, CPU/memory spike cascades into more lag.

Mitigation: size `repl-backlog-size` generously, keep `repl-diskless-sync-delay 5` so multiple replicas share a transfer, stagger replica restarts during maintenance, alert on `sync_full` counter (should be ~0 in steady state).

### 5. Replication lag under write burst

Replicas fall behind. Once lag exceeds `min-replicas-max-lag`, they stop counting toward `min-replicas-to-write` - primary can go read-only. Check `INFO replication`'s `slave*:lag`. Sustained >5 s worth investigating; >30 s means the replica is underprovisioned (CPU or network).

### 6. Bandwidth-bound failures

Large payload distributions saturate network before CPU or memory thresholds trip. Alert on NIC utilization per node (>70% of line rate) alongside command-count metrics. MPTCP (`mptcp yes` / `repl-mptcp yes`, Valkey 9.0+, Linux 5.6+) can help by using multiple network paths - both ends must support it.

## Monitoring and alerts

```sh
valkey-cli INFO replication | grep -E 'slave[0-9]+:|repl_backlog|master_repl_offset|second_repl_offset'
valkey-cli INFO stats       | grep -E 'sync_full|sync_partial'
```

Alert on:
- `master_link_status:down` on any replica.
- `slave*:lag` > 5 s warn, > 30 s crit.
- `connected_slaves` lower than expected.
- `sync_full` counter incrementing in steady state.
- `master_repl_offset - slave_repl_offset > repl_backlog_size * 0.8` (imminent full resync).
- `rdb_last_bgsave_status:err` on primary.
