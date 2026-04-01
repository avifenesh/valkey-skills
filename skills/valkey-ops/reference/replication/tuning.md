Use when sizing the replication backlog, configuring diskless or dual-channel replication, tuning sync behavior, or handling Docker/NAT networking for replicas.

# Replication Tuning

Source: `src/config.c`, `src/replication.c` (Valkey source).

## Contents

- Replication Backlog (line 19)
- Diskless Replication (line 80)
- Dual-Channel Replication (line 127)
- Connection Tuning (line 151)
- Docker and NAT Considerations (line 169)
- Monitoring Replication Health (line 219)
- See Also (line 239)

---

## Replication Backlog

The replication backlog is a fixed-size circular buffer on the primary that holds recent write commands. It enables partial resynchronization (PSYNC) when replicas reconnect after brief disconnections.

### Configuration

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `repl-backlog-size` | `10mb` | Yes | Size of the replication backlog buffer |
| `repl-backlog-ttl` | `3600` (1 hour) | Yes | Seconds to retain backlog after last replica disconnects |

Defaults verified in `src/config.c`:
- `repl-backlog-size`: `10 * 1024 * 1024` (10MB)
- `repl-backlog-ttl`: `60 * 60` (3600 seconds)

### Sizing the Backlog

If the backlog is too small, any replica disconnection longer than the buffer can hold triggers an expensive full resync.

**Formula:**

```
repl-backlog-size >= write_rate_bytes_per_second * max_expected_disconnect_seconds * 2
```

The 2x safety factor accounts for write bursts.

**Example:** If your write rate is 2MB/s and replicas may disconnect for up to 60 seconds:

```
repl-backlog-size = 2MB/s * 60s * 2 = 240MB
```

**Measure your write rate:**

```bash
# Sample write throughput over 10 seconds
OFFSET1=$(valkey-cli INFO replication | grep master_repl_offset | cut -d: -f2 | tr -d '\r')
sleep 10
OFFSET2=$(valkey-cli INFO replication | grep master_repl_offset | cut -d: -f2 | tr -d '\r')
RATE=$(( (OFFSET2 - OFFSET1) / 10 ))
echo "Write rate: $RATE bytes/sec"
```

### Production Recommendations

| Write Rate | Max Disconnect | Safety Factor | Recommended Backlog |
|-----------|----------------|---------------|-------------------|
| 1 MB/s | 30s | 2x | 60 MB |
| 5 MB/s | 60s | 2x | 600 MB |
| 20 MB/s | 120s | 2x | ~5 GB |
| 50 MB/s | 60s | 2x | ~6 GB |

- **Minimum 256MB** for production workloads with replication
- **1GB or more** for high-write-throughput systems
- The default 10MB is almost always too small for production
- For cross-DC links, size generously - WAN disconnections last longer
- Monitor `INFO replication` for `repl_backlog_size` and `repl_backlog_first_byte_offset` to confirm coverage

`repl-backlog-ttl` (default 3600s): How long to retain the backlog after the last replica disconnects. Set to 0 to retain forever if replicas might reconnect after long outages.

## Diskless Replication

Diskless replication streams the RDB directly from the primary to replicas over the network, skipping disk I/O entirely.

### Configuration

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `repl-diskless-sync` | `yes` | Yes | Enable diskless RDB transfer to replicas |
| `repl-diskless-sync-delay` | `5` | Yes | Seconds to wait for more replicas before starting |
| `repl-diskless-sync-max-replicas` | `0` | Yes | Start immediately when this many replicas are waiting (0 = disabled) |
| `repl-diskless-load` | `disabled` | Yes | How replica handles diskless RDB loading |

Defaults verified in `src/config.c`:
- `repl-diskless-sync`: `1` (yes) - note: this is the Valkey default, different from legacy Redis
- `repl-diskless-sync-delay`: `5` seconds
- `repl-diskless-sync-max-replicas`: `0` (disabled)
- `repl-diskless-load`: `REPL_DISKLESS_LOAD_DISABLED` (disabled)

### When to Use Diskless Sync

Use diskless sync when:
- Disk I/O is slow (spinning disks, network-attached storage, cloud volumes with IOPS limits)
- Network bandwidth is good
- You want to avoid temporary RDB files on the primary

Keep disk-based sync when:
- You need the RDB file on disk for other purposes (backups)
- Multiple replicas connect at different times (disk-based allows reuse of the same RDB)

### Diskless Sync Delay

The `repl-diskless-sync-delay` setting (default: 5 seconds) controls how long the primary waits before starting a diskless transfer. This allows multiple replicas to arrive and receive the same stream, avoiding repeated full syncs.

Set to `0` for single-replica setups. Increase for environments where multiple replicas may reconnect simultaneously.

### Diskless Load Options (Replica Side)

| Value | Behavior |
|-------|----------|
| `disabled` | Save RDB to disk, then load (default, safest) |
| `on-empty-db` | Load directly into memory only if the database is empty |
| `swapdb` | Load into a separate database, swap atomically on success |
| `flush-before-load` | Flush current database, then load directly |

`swapdb` provides the best availability - the replica serves the old dataset until the new one is fully loaded, then swaps atomically. However, it requires enough memory to hold both datasets simultaneously.

## Dual-Channel Replication

Dual-channel replication was a proposed feature in the Valkey development process that uses a separate TCP connection for RDB transfer during full resync, allowing the main replication link to continue streaming incremental commands.

**Status**: The config parameter `dual-channel-replication-enabled` exists in the source code (default `no`), and capability negotiation is present in `replication.c`. However, dual-channel replication is NOT documented as a released feature in the official Valkey replication docs as of 9.0. The official `replication.md` topic does not mention it. Use standard diskless replication (`repl-diskless-sync`) as the primary mechanism for improving full-sync performance.

### Configuration

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `dual-channel-replication-enabled` | `no` | Yes | Enable dual-channel sync |

### How It Would Work

In traditional full sync, the primary sends the RDB snapshot, buffers writes during transfer, then sends buffered commands. With dual-channel, the primary would send the RDB on a dedicated channel while simultaneously streaming replication commands on the main channel. The replica applies both in parallel, reducing total sync time.

### Requirements

- Both primary and replica must have `dual-channel-replication-enabled yes`
- `repl-diskless-sync` must be enabled on the primary (dual-channel uses socket-based transfer)
- The replica advertises `dual-channel` capability during PSYNC handshake

If the primary has dual-channel disabled, it ignores the capability and falls back to normal sync.

## Connection Tuning

### TCP Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `repl-disable-tcp-nodelay` | `no` | When `no`, uses TCP_NODELAY for lower latency |
| `repl-timeout` | `60` | Seconds before considering replication link dead |
| `repl-ping-replica-period` | `10` | Seconds between primary PING to replicas |

Rule: `repl-timeout` should be greater than `repl-ping-replica-period`. A timeout shorter than the ping interval causes spurious disconnections.

### TCP_NODELAY

With `repl-disable-tcp-nodelay no` (the default), Valkey sets TCP_NODELAY on the replication socket. This sends commands immediately without Nagle buffering, reducing replication lag by up to 40ms.

Set to `yes` only if you want to reduce bandwidth at the cost of higher replication lag (rarely useful).

## Docker and NAT Considerations

When Valkey runs behind NAT or Docker port mapping, replicas and Sentinel cannot discover the correct IP/port automatically.

### Problem

Docker maps container ports to host ports (e.g., container 6379 -> host 16379). The replica reports its container IP and port, which are unreachable from outside the container.

### Solution

Set explicit announcement addresses on each replica:

```
replica-announce-ip 203.0.113.10
replica-announce-port 16379
```

These values are reported in `INFO replication` and used by Sentinel for failover decisions.

### Docker Compose Example

```yaml
services:
  valkey-primary:
    image: valkey/valkey:9
    ports:
      - "6379:6379"
    command: valkey-server --bind 0.0.0.0

  valkey-replica:
    image: valkey/valkey:9
    ports:
      - "6380:6379"
    command: >
      valkey-server --bind 0.0.0.0
        --replicaof valkey-primary 6379
        --replica-announce-ip ${HOST_IP}
        --replica-announce-port 6380
```

### Alternative: Host Networking

Use `--net=host` to avoid port mapping entirely. The container shares the host's network namespace.

```bash
docker run --net=host valkey/valkey:9 valkey-server --port 6379
```

This is simpler but gives up container network isolation.

## Monitoring Replication Health

```bash
# Check replication lag across all replicas
valkey-cli INFO replication | grep -E "slave[0-9]+:|repl_backlog"

# Monitor sync counters for cascading resync detection
valkey-cli INFO stats | grep -E "sync_full|sync_partial"
```

### Alert Thresholds

| Condition | Threshold | Severity |
|-----------|-----------|----------|
| `master_link_status:down` | Any occurrence | Immediate alert |
| Replica `lag` | > 5 seconds | Warning |
| Replica `lag` | > 30 seconds | Critical |
| `master_repl_offset - slave_repl_offset` > `repl_backlog_size * 0.8` | Approaching limit | Critical - full resync imminent |
| `sync_full` counter incrementing | Unexpected increase | Investigate - possible backlog undersize |
