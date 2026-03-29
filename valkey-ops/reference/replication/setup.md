# Primary-Replica Replication Setup

Use when configuring Valkey replication, setting up read replicas, promoting replicas to primary, or understanding how initial synchronization works.

Source: `src/config.c`, `src/replication.c` (Valkey source).

---

## When to Use Replication

- You need read scaling across multiple nodes
- You want a hot standby for failover (manual or via Sentinel)
- You need a dedicated replica for backups (avoids fork on primary)
- You are building a high-availability deployment

## Configuration Reference

All defaults verified against `src/config.c` in the Valkey source tree.

### Replica-Side Configuration

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `replicaof` | (none) | No (immutable via config) | Primary host and port |
| `primaryauth` | (none) | Yes | Password for primary authentication |
| `primaryuser` | (none) | Yes | ACL username for primary authentication |
| `replica-read-only` | `yes` | Yes | Reject write commands on replica |
| `replica-serve-stale-data` | `yes` | Yes | Serve data during sync or when link is down |
| `replica-lazy-flush` | `yes` | Yes | Async flush on full resync (avoid blocking) |
| `replica-announced` | `yes` | Yes | Announce this replica to Sentinel/clients |
| `replica-announce-ip` | (none) | Yes | Override IP for Sentinel/client discovery |
| `replica-announce-port` | `0` | Yes | Override port for Sentinel/client discovery |
| `replica-priority` | `100` | Yes | Failover priority (0 = never promote) |

### Primary-Side Configuration

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `repl-timeout` | `60` | Yes | Replication timeout in seconds |
| `repl-ping-replica-period` | `10` | Yes | Seconds between PING to replicas |
| `repl-disable-tcp-nodelay` | `no` | Yes | Disable TCP_NODELAY on replication socket |
| `repl-mptcp` | `no` | No (immutable) | Enable Multipath TCP for replication |

Note: `replicaof` is IMMUTABLE in config files but can be changed at runtime via the `REPLICAOF` command. `repl-mptcp` is immutable and requires restart.

## Setup Procedures

### Configure via valkey.conf

On each replica host:

```
replicaof 192.168.1.10 6379
primaryauth YOUR_PASSWORD
replica-read-only yes
```

### Configure at Runtime

```bash
# Make this instance a replica of 192.168.1.10:6379
valkey-cli REPLICAOF 192.168.1.10 6379

# Set auth if needed
valkey-cli CONFIG SET primaryauth YOUR_PASSWORD
```

### Promote Replica to Primary

```bash
valkey-cli REPLICAOF NO ONE
```

This detaches the replica and makes it accept writes. Existing data is preserved.

### Verify Replication Status

```bash
# On the primary
valkey-cli INFO replication

# Key fields:
# role:master
# connected_slaves:2
# slave0:ip=192.168.1.11,port=6379,state=online,offset=12345,lag=0
# slave1:ip=192.168.1.12,port=6379,state=online,offset=12345,lag=1

# On a replica
valkey-cli INFO replication

# Key fields:
# role:slave
# master_host:192.168.1.10
# master_port:6379
# master_link_status:up
# master_last_io_seconds_ago:1
# master_sync_in_progress:0
```

## Synchronization Mechanisms

### Full Synchronization

Occurs on first connection or when partial sync is not possible:

1. Primary forks a child process (BGSAVE) or streams RDB directly (diskless)
2. Primary sends the RDB snapshot to the replica
3. Primary buffers all new write commands in the replication backlog during transfer
4. Replica loads the RDB (replaces its current dataset)
5. Primary sends buffered commands to bring the replica up to date

Full sync is expensive - it involves fork overhead on the primary and full data transfer. See [Replication Tuning](tuning.md) for backlog sizing to minimize full resyncs.

### Partial Synchronization (PSYNC)

When a replica reconnects after a brief disconnection:

1. Replica sends its replication ID and current offset to the primary
2. Primary checks if the requested offset is still in the replication backlog
3. If yes, only the missing commands are sent (partial resync)
4. If no, a full resync is triggered

The replication backlog size determines how long a replica can be disconnected before requiring a full resync.

### Replication ID

Each Valkey instance has a replication ID. When a replica connects, it must present the correct replication ID. After a failover, the new primary generates a new replication ID but remembers the old one (secondary ID), allowing replicas of the old primary to partial-resync with the new primary.

## Operational Notes

### Authentication

If the primary requires a password (`requirepass`), set `primaryauth` on each replica. For ACL-based auth, also set `primaryuser`.

### Multiple Replicas

A primary can serve multiple replicas simultaneously. Each replica maintains its own replication offset. Adding replicas does not require changes to the primary configuration.

### Chained Replication

Replicas can replicate from other replicas (replica-of-replica). This reduces load on the primary but adds replication lag.

```
Primary -> Replica A -> Replica B
                     -> Replica C
```

### Read-Only Mode

With `replica-read-only yes` (the default), replicas reject all write commands. This prevents accidental writes that would diverge from the primary and be lost on the next resync.

### Stale Data Serving

With `replica-serve-stale-data yes` (the default), replicas continue serving read requests during initial sync or when the primary link is down. Set to `no` if stale reads are unacceptable - clients will receive errors instead.

## See Also

- [Replication Tuning](tuning.md) - backlog sizing, diskless sync, dual-channel
- [Replication Safety](safety.md) - min-replicas settings, data loss prevention
- [Sentinel Architecture](../sentinel/architecture.md) - automatic failover for replicated setups
- [Configuration Essentials](../configuration/essentials.md) - replication config defaults
- [See valkey-dev: replication overview](../valkey-dev/reference/replication/overview.md) - replication protocol internals
- [See valkey-dev: dual-channel](../valkey-dev/reference/replication/dual-channel.md) - dual-channel replication internals
