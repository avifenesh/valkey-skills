# Replication Tuning

Use when sizing the replication backlog, picking diskless vs disk-based sync, enabling dual-channel, or handling NAT.

## Backlog sizing

Replication backlog is a circular buffer on the primary that holds recent writes, enabling partial resync (PSYNC CONTINUE). Too small = any reconnect beyond the buffer triggers a full resync.

| Parameter | Default | Notes |
|-----------|---------|-------|
| `repl-backlog-size` | 10 MB | Almost always too small for production. |
| `repl-backlog-ttl` | 3600 s | Seconds to retain after last replica disconnects. `0` = retain forever. |

Formula: `repl-backlog-size >= write_rate_bytes_per_sec * max_expected_disconnect_seconds * 2`. The 2× is bursty-traffic headroom.

Measure write rate from the offset delta:

```sh
o1=$(valkey-cli INFO replication | awk -F: '/^master_repl_offset:/ {print $2}' | tr -d '\r')
sleep 10
o2=$(valkey-cli INFO replication | awk -F: '/^master_repl_offset:/ {print $2}' | tr -d '\r')
echo "bytes/sec = $(( (o2-o1) / 10 ))"
```

Practical minimums: 256 MB for a prod instance with any replication, 1 GB+ for high-write clusters, generous (multi-GB) for cross-DC WAN replicas where the disconnect window is measured in minutes.

Monitor `repl_backlog_first_byte_offset` + `repl_backlog_size` vs `master_repl_offset - slave_repl_offset` - if the lag approaches 80% of the backlog, a full resync is about to happen.

## Diskless replication

| Parameter | Default | Notes |
|-----------|---------|-------|
| `repl-diskless-sync` | `yes` | Primary streams RDB directly over socket. Default differs from old Redis (was `no`). |
| `repl-diskless-sync-delay` | `5` s | Window to collect multiple replicas for a shared stream. Set `0` for single-replica. |
| `repl-diskless-sync-max-replicas` | `0` | Trigger immediately when this many replicas are waiting. `0` = disabled. |
| `repl-diskless-load` | `disabled` | Replica-side loading policy. |

Replica-side `repl-diskless-load` values:

| Value | Behavior |
|-------|---------|
| `disabled` | Save RDB to disk first, then load. Safest, most memory-efficient. |
| `on-empty-db` | Load direct-to-memory only when the replica's DB is empty. |
| `swapdb` | Load into a shadow DB, atomic swap on success. Best availability (serves old dataset until swap) but needs 2× memory. |
| `flush-before-load` | Flush current DB, load direct-to-memory. |

Use diskless when disk I/O is the bottleneck (spinning disks, IOPS-limited cloud volumes). Keep disk-based if you need the RDB file on disk for backups or multiple replicas reconnect at different times (disk-based allows RDB reuse; diskless regenerates per-replica unless they arrive in the delay window).

## Dual-channel replication

Valkey 8.0+ feature - full resync uses two TCP connections so the replica buffers streaming writes locally while loading the RDB, instead of the primary buffering per-replica.

| Parameter | Default | Notes |
|-----------|---------|-------|
| `dual-channel-replication-enabled` | `no` | Set `yes` on the replica. |

The primary auto-detects the replica's `capa dual-channel` advertisement during PSYNC; if the primary doesn't support it, it silently falls back to single-channel. Requires `repl-diskless-sync yes` on the primary since the second channel transfers the RDB over socket.

Protocol details (for context when reading logs):
- `+DUALCHANNELSYNC` response code on PSYNC (code `PSYNC_FULLRESYNC_DUAL_CHANNEL = 6`).
- RDB channel carries AUTH → `REPLCONF ip-address` → `$ENDOFF:<offset>` → RDB bytes.
- Main channel attaches to the backlog at the `$ENDOFF` offset and streams writes in parallel.
- Replica buffers main-channel bytes in `server.pending_repl_data` (list of `replDataBufBlock`) until RDB load completes, then drains via `streamReplDataBufToDb()`.

Back-pressure: if `pending_repl_data` exceeds the replica-side COB hard limit, the replica stops reading the main channel; the primary's output buffer for that replica grows instead. Net effect is same as single-channel but shifted, so the replica can apply back-pressure without the primary OOMing.

## Connection tuning

| Parameter | Default | Notes |
|-----------|---------|-------|
| `repl-timeout` | 60 s | Must be greater than `repl-ping-replica-period`. |
| `repl-ping-replica-period` | 10 s | |
| `repl-disable-tcp-nodelay` | `no` | `no` keeps TCP_NODELAY on. Set `yes` only to trade lag for bandwidth. |

## Docker/NAT - replica announcement

When the replica lives behind NAT (Docker port mapping, K8s NodePort), the primary needs the externally-reachable address, not the container IP:

```
replica-announce-ip   203.0.113.10
replica-announce-port 16379
```

These values are reported in `INFO replication` and used by Sentinel. Without them, failover picks an address that isn't routable.

For Docker Compose, inject via environment:

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

Or `--net=host` to skip port mapping entirely (container shares host netns).

## Monitoring

```sh
valkey-cli INFO replication | grep -E 'slave[0-9]+:|repl_backlog|master_repl_offset|second_repl_offset'
valkey-cli INFO stats       | grep -E 'sync_full|sync_partial'
```

Alert on: `master_link_status:down`, `slave_repl_offset` lag > 5 s (warn) / 30 s (crit), `sync_full` counter incrementing (means the backlog is undersized), `master_repl_offset - slave_repl_offset > repl_backlog_size * 0.8` (imminent full resync).
