# Primary-Replica Replication Setup

Use when configuring Valkey replication, setting up read replicas, promoting replicas to primary, or understanding how initial synchronization works.

Source: `src/config.c`, `src/replication.c` (Valkey source).

## Contents

- Tested Example: Primary + Replica via Docker (line 19)
- When to Use Replication (line 45)
- Configuration Reference (line 52)
- Setup Procedures (line 82)
- Synchronization Mechanisms (line 136)
- Operational Notes (line 167)

---

## Tested Example: Primary + Replica via Docker

```bash
# Start primary
docker run -d --name vk-primary --net=host valkey/valkey:9 \
  valkey-server --port 6379 --requirepass secret

# Start replica
docker run -d --name vk-replica --net=host valkey/valkey:9 \
  valkey-server --port 6380 --replicaof 127.0.0.1 6379 \
  --masterauth secret --requirepass secret

# Write on primary, read on replica
valkey-cli -p 6379 -a secret SET hello "replication works"
valkey-cli -p 6380 -a secret GET hello
# Expected: "replication works"

# Verify replication status
valkey-cli -p 6379 -a secret INFO replication | grep connected_slaves
# Expected: connected_slaves:1
valkey-cli -p 6380 -a secret INFO replication | grep master_link_status
# Expected: master_link_status:up
```

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
| `masterauth` | (none) | Yes | Password for primary authentication (alias: `primaryauth`) |
| `masteruser` | (none) | Yes | ACL username for primary authentication (alias: `primaryuser`) |
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

`replicaof` is IMMUTABLE in config files but can be changed at runtime via the `REPLICAOF` command. `repl-mptcp` is immutable and requires restart.

## Setup Procedures

### Configure via valkey.conf

On each replica host:

```
replicaof 192.168.1.10 6379
masterauth YOUR_PASSWORD
replica-read-only yes
```

### Configure at Runtime

```bash
# Make this instance a replica of 192.168.1.10:6379
valkey-cli REPLICAOF 192.168.1.10 6379

# Set auth if needed
valkey-cli CONFIG SET masterauth YOUR_PASSWORD
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

Each Valkey instance has a replication ID. When a replica connects, it must present the correct replication ID. After a failover, the new primary generates a new replication ID but remembers the old one (secondary ID), allowing replicas of the old primary to partial-resync with the new primary. This is why Valkey uses two replication IDs - it avoids expensive full resyncs on the common case of failover followed by replica reconnection.

On reconnect, a replica sends `PSYNC <replication-id> <offset>`. The primary checks: (1) does the replication ID match (current or secondary)? (2) is the requested offset still within the backlog? If both yes: partial resync. If no: full resync.

## Operational Notes

### Authentication

If the primary requires a password (`requirepass`), set `masterauth` on each replica. For ACL-based auth, also set `masteruser`. Valkey also accepts the aliases `primaryauth` and `primaryuser`.

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
