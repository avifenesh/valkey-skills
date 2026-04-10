# Replication Internals for Application Developers

Use when you need to understand why replicas fall out of sync, what triggers expensive full resyncs, how to size the replication backlog, or when to use diskless or dual-channel replication.

## Contents

- Partial vs Full Resync (line 13)
- Replication Backlog (line 48)
- Client Output Buffer for Replicas (line 84)
- Diskless Replication (line 108)
- Dual-Channel Replication (line 133)
- Replica Priority and Failover Selection (line 158)
- Replica-of-Replica Chains (line 175)
- Minimum Replicas for Writes (line 195)
- Valkey Version Changes (line 222)

---

## Partial vs Full Resync

When a replica connects (or reconnects) to a primary, the PSYNC2 protocol determines whether a partial or full resync is needed.

### Partial Resync (Fast)

The replica sends its last known replication ID and byte offset. If both match and the requested offset is still available in the primary's replication backlog, only the missing commands are streamed. This takes milliseconds to seconds.

### Full Resync (Expensive)

The primary forks to generate an RDB snapshot, transfers the entire dataset to the replica, then sends all commands that accumulated during the transfer. This is costly in CPU (fork), memory (copy-on-write), network (full dataset transfer), and time.

### What Triggers Full Resync

| Trigger | Why It Happens |
|---------|----------------|
| First-ever connection | Replica has no history with this primary. |
| Replication ID mismatch | Primary was restarted or replaced. The new primary has a different replication ID. |
| Offset outside backlog | Replica was disconnected too long. The commands it missed have been evicted from the backlog. |
| Backlog overflow | The primary's output buffer for this replica exceeded `client-output-buffer-limit replica`. The connection was killed, and by the time it reconnects, the backlog may have rotated. |
| Explicit `PSYNC ? -1` | Client or operator forced a full resync. |

### Dual Replication IDs

After a failover, the new primary remembers the old primary's replication ID as a secondary ID. This means replicas that were replicating from the old primary can partial-resync with the new primary without a full transfer - as long as their offset is still within the backlog. This is why Sentinel failovers usually do not cause full resyncs on the remaining replicas.

---

## Replication Backlog

The replication backlog is a buffer on the primary that stores recent write commands. Its size determines the window during which a disconnected replica can partial-resync instead of requiring a full resync.

### Configuration

```
# Default: 10 MB (almost always too small for production)
CONFIG SET repl-backlog-size 268435456   # 256 MB

# How long to retain the backlog after the last replica disconnects
# Default: 3600 seconds (1 hour)
CONFIG SET repl-backlog-ttl 3600
```

### Sizing Formula

```
repl-backlog-size >= write_rate_bytes_per_second * max_disconnect_seconds * 2
```

The 2x safety factor accounts for write bursts. Measure your write rate:

```
# Take two samples of master_repl_offset 10 seconds apart
127.0.0.1:6379> INFO replication
master_repl_offset:123456789

# ... wait 10 seconds ...

127.0.0.1:6379> INFO replication
master_repl_offset:123656789
# Delta: 200,000 bytes in 10 seconds = 20 KB/s write rate
```

### Practical Sizing

| Write Rate | Max Disconnect | Recommended Backlog |
|-----------|----------------|---------------------|
| 1 MB/s | 30 seconds | 64 MB |
| 5 MB/s | 60 seconds | 600 MB |
| 20 MB/s | 120 seconds | 5 GB |

**Rule of thumb**: 256 MB minimum for production. 1 GB or more for write-heavy workloads. The default 10 MB covers only a few seconds on most production systems.

---

## Client Output Buffer for Replicas

During full resync, the primary buffers new write commands that arrive while the RDB is being transferred. This buffer is controlled by `client-output-buffer-limit replica`.

```
# Default: 256 MB hard limit, 64 MB soft limit over 60 seconds
client-output-buffer-limit replica 256mb 64mb 60
```

If this buffer overflows:

1. The primary kills the replica connection
2. The replica reconnects and likely triggers another full resync
3. The full resync generates more buffered data, which can overflow again
4. This creates a **resync loop** - the replica can never finish syncing

### Detecting the Resync Loop

```
127.0.0.1:6379> INFO stats
sync_full:47        # This number keeps growing = resync loop
sync_partial_ok:3
sync_partial_err:44
```

If `sync_full` is climbing while the same replica keeps reconnecting, the output buffer is too small for the RDB transfer time. Solutions:

- Increase `client-output-buffer-limit replica` (coordinate with ops)
- Enable diskless replication to reduce transfer time
- Reduce dataset size if possible
- Use dual-channel replication (Valkey 8.0+) to avoid this buffering entirely

---

## Diskless Replication

In standard replication, the primary writes the RDB to disk, then sends the file to the replica. Diskless replication streams the RDB directly from the fork's memory to the replica over the socket, skipping disk entirely.

```
# Default: yes (Valkey default, changed from Redis which defaulted to no)
repl-diskless-sync yes

# Wait this many seconds for additional replicas before starting transfer
# Multiple replicas arriving during the delay share one RDB stream
repl-diskless-sync-delay 5
```

### When Diskless Helps

- **Slow disk, fast network** - cloud instances with IOPS-limited volumes transfer RDB faster over the network.
- **Multiple replicas syncing** - one fork streams to all waiting replicas simultaneously.

Keep disk-based sync when you need the RDB file for backups, or when replicas connect at very different times (disk-based allows reusing the same RDB without forking again).

On the replica side, `repl-diskless-load swapdb` loads the RDB directly into memory while serving old data, then swaps atomically. This provides the best availability but requires enough memory to hold two copies of the dataset during the swap.

---

## Dual-Channel Replication

Dual-channel replication (Valkey 8.0+) is an enhancement to full resync that uses two separate TCP connections: one for the RDB transfer and one for the ongoing replication stream.

### The Problem It Solves

In traditional full resync, the primary must buffer all new write commands while the RDB transfers. For a 10 GB dataset over a 1 Gbps link, the transfer takes ~80 seconds. If the write rate is 5 MB/s, that is 400 MB of buffered data. With dual-channel, the replication stream flows in parallel on its own connection, and the replica buffers it locally instead of the primary holding it in memory.

### Benefits for Application Developers

- **Fewer failed syncs** - the primary's memory pressure during full resync is dramatically reduced, eliminating the resync loop problem.
- **Faster total sync time** - the replica receives incremental data during the RDB transfer, not after. The catch-up phase after RDB load is shorter.
- **No application changes needed** - this is transparent to clients.

### Configuration

```
# Enable on the replica side (default: no)
CONFIG SET dual-channel-replication-enabled yes
```

Both primary and replica must support it. The capability is negotiated during the PSYNC handshake. If either side does not support it, standard single-channel sync is used as a fallback.

Note: `repl-diskless-sync` must also be enabled on the primary for dual-channel to work, since dual-channel uses socket-based RDB transfer.

---

## Replica Priority and Failover Selection

When Sentinel promotes a replica to primary during failover, it uses `replica-priority` to choose which replica gets promoted.

```
# Default: 100. Lower values = higher priority for promotion.
# 0 = never promote this replica (use for dedicated read replicas or backup replicas).
CONFIG SET replica-priority 100
```

### Selection Order

Sentinel picks the replica with:
1. Lowest `replica-priority` (excluding 0)
2. Most advanced replication offset (least data loss)
3. Smallest run ID (tiebreaker)

### Application Impact

If your application reads from replicas, the promoted replica stops being a read endpoint and becomes the write endpoint. Your client library handles this automatically if using Sentinel-aware connections - but there is a brief window (5-30 seconds) where reads may fail.

Set `replica-priority 0` on replicas that should never be promoted - for example, a replica used solely for backups or analytics queries.

---

## Replica-of-Replica Chains

Replicas can replicate from other replicas: `Primary -> Replica A -> Replica B`. This reduces primary network load (it only sends data once to Replica A), which is useful for 4+ replicas or cross-DC setups where a local replica fans out to others.

**Trade-offs**: each hop adds replication lag; if Replica A needs a full resync from the primary, all downstream replicas also require full resyncs (the replication ID changes); Sentinel does not automatically rewire chains if the intermediate replica fails. For 2-3 replicas, direct replication from the primary is simpler.

---

## Minimum Replicas for Writes

You can configure the primary to reject writes unless a minimum number of replicas are connected and acknowledging data. This prevents accepting writes that would be lost if the primary fails with no up-to-date replicas.

```
# Reject writes if fewer than 1 replica is connected and responding
CONFIG SET min-replicas-to-write 1

# A replica is considered lagging if it has not sent an ACK in this many seconds
CONFIG SET min-replicas-max-lag 10
```

### How It Works

Replicas send `REPLCONF ACK <offset>` to the primary every second. If fewer than `min-replicas-to-write` replicas have sent an ACK within the last `min-replicas-max-lag` seconds, the primary returns an error on write commands:

```
(error) NOREPLICAS Not enough good replicas to write.
```

### Application Considerations

- **Handle the NOREPLICAS error** - your application must catch this and either retry or report the failure. This is a deliberate safety mechanism, not a transient error.
- **Set reasonable values** - `min-replicas-to-write 1` with `min-replicas-max-lag 10` is a common choice. It allows writes as long as at least one replica is within 10 seconds of the primary.
- **Zero means disabled** - `min-replicas-to-write 0` (the default) means the primary accepts writes regardless of replica status.
- **Interaction with Sentinel** - during failover, the old primary may briefly reject writes (if replicas disconnect before Sentinel promotes one). This is actually desirable - it prevents split-brain writes.

---

## Valkey Version Changes

### Valkey 8.0

- **Dual-channel replication** introduced. Uses two TCP connections for full resync, reducing primary memory pressure. Requires `dual-channel-replication-enabled yes` on the replica and `repl-diskless-sync yes` on the primary.
- **Default for `repl-diskless-sync` changed to `yes`** (was `no` in Redis). New Valkey deployments use diskless replication by default.

### Valkey 9.0

- **Multipath TCP (MPTCP) for replication** - when `repl-mptcp yes` is set and the kernel supports it, replication traffic can use multiple network paths. This benefits deployments with redundant NICs or cross-DC links. Note: `repl-mptcp` requires a restart.
- Replication remains asynchronous by default. Use `WAIT` or `WAITAOF` for synchronous confirmation on critical writes.

---
