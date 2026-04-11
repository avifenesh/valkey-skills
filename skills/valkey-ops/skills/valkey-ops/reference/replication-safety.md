# Replication Safety

Use when configuring write safety guarantees, preventing data loss during network partitions, understanding auto-restart risks, or hardening a replication deployment against failure modes.

Source: `src/config.c`, `src/replication.c` (Valkey source).

## Contents

- Safety Configuration (line 18)
- The WAIT Command (line 62)
- Critical Warnings (line 81)
- Monitoring Checklist (line 191)
- Pre-Deployment Safety Checklist (line 201)

---

## Safety Configuration

### min-replicas Settings

These settings prevent the primary from accepting writes when it cannot confirm that writes are being replicated.

| Parameter | Default | Mutable | Description |
|-----------|---------|---------|-------------|
| `min-replicas-to-write` | `0` | Yes | Minimum connected replicas to accept writes (0 = disabled) |
| `min-replicas-max-lag` | `10` | Yes | Maximum replication lag (seconds) for a replica to count as "connected" |

Defaults verified in `src/config.c`:
- `min-replicas-to-write`: `0` (disabled by default)
- `min-replicas-max-lag`: `10` seconds

### How They Work Together

A replica counts as "connected" only if its last interaction was within `min-replicas-max-lag` seconds. If the number of connected replicas drops below `min-replicas-to-write`, the primary rejects all write commands with an error.

**Example - require at least 1 replica within 10 seconds:**

```
min-replicas-to-write 1
min-replicas-max-lag 10
```

Effect:
- If the sole replica disconnects or falls more than 10 seconds behind, the primary stops accepting writes
- Clients receive `NOREPLICAS` error on write attempts
- Reads continue to work normally

### Recommended Settings by Deployment

| Deployment | min-replicas-to-write | min-replicas-max-lag | Rationale |
|------------|----------------------|---------------------|-----------|
| 1 primary + 1 replica | `1` | `10` | Stops writes immediately on replica loss |
| 1 primary + 2 replicas | `1` | `10` | Tolerates 1 replica failure |
| 1 primary + 2 replicas (strict) | `2` | `10` | Requires both replicas - more durable but less available |
| Cache-only (no durability) | `0` (default) | `10` | Writes always accepted |

### Trade-off

Higher `min-replicas-to-write` increases durability but reduces availability. If replicas go down for maintenance, the primary becomes read-only. Plan maintenance windows accordingly.

## The WAIT Command

`WAIT` provides synchronous replication for individual commands.

```bash
# Write a critical value
SET critical:key "value"

# Wait for at least 1 replica to acknowledge, with 5 second timeout
WAIT 1 5000
```

`WAIT` returns the number of replicas that acknowledged the write. If it returns 0, the write may not have been replicated.

Limitations:
- WAIT only confirms the write reached the replica's memory, not that it was persisted to disk
- WAIT does not make Valkey into a strongly consistent system
- Use for critical writes only - it adds latency equal to replication lag

## Critical Warnings

### 1. Primary Without Persistence: Cascading Data Loss

**The most dangerous misconfiguration in Valkey replication.**

Scenario:
1. Primary runs without persistence (no RDB, no AOF) - used as a pure cache
2. Primary crashes or is restarted by systemd
3. Primary starts with an empty dataset
4. All replicas connect and full-sync from the empty primary
5. All replicas wipe their data to match the empty primary

**Result:** Complete data loss across all nodes.

**Prevention:**

Option A - Always enable persistence on the primary:
```
appendonly yes
save 3600 1 300 100 60 10000
```

Option B - Disable auto-restart on the primary (if persistence is truly unwanted):
```ini
# In the systemd service file
[Service]
Restart=no
# Or limit restarts
Restart=on-failure
StartLimitBurst=0
```

Option C - Use Sentinel with the primary and do not auto-restart:
Sentinel detects the crash and promotes a replica. The old primary does not come back empty.

**This is not a theoretical risk.** It has caused production data loss. If you take away one thing from this document, configure persistence on every primary.

### 2. Writable Replicas Cause Inconsistency

The default `replica-read-only yes` is correct. If a replica accepts writes:

- Those writes exist only on the replica
- They are lost on the next full resync
- They create a divergent dataset that confuses monitoring
- Clients may read data that does not exist on the primary

Never set `replica-read-only no` in production unless you have a very specific use case and understand the consequences.

### 3. Network Partition Split-Brain

During a network partition:

```
[Partition A]           [Partition B]
Primary + Client        Replica + Sentinel majority
  (isolated)              (promotes replica)
```

- Client continues writing to the isolated primary
- Sentinel promotes the replica in Partition B
- When the partition heals, the old primary becomes a replica of the new primary
- All writes to the old primary during the partition are lost

**Mitigation:**

```
min-replicas-to-write 1
min-replicas-max-lag 10
```

The isolated primary stops accepting writes after `min-replicas-max-lag` seconds. The data loss window is limited to at most `min-replicas-max-lag` seconds of writes.

### 4. Cascading Full Resyncs

**Production incident pattern**: Primary restart or brief network blip causes all replicas to reconnect simultaneously. If the replication backlog is undersized, all replicas trigger full resync. The primary forks for each (or batches with diskless sync delay), consuming massive memory and CPU. This can cascade - the fork overhead causes further lag, triggering more resyncs.

**Mitigation:**
- Size `repl-backlog-size` generously to reduce full resyncs (see [Replication Tuning](replication-tuning.md))
- Use `repl-diskless-sync-delay 5` to batch multiple replicas into one transfer
- Stagger replica restarts during maintenance
- Monitor `sync_full` and `sync_partial_ok` counters in `INFO stats` to detect the pattern early

### 5. Replication Lag Under Load

High write throughput can cause replicas to fall behind. Monitor:

```bash
valkey-cli INFO replication | grep lag
# slave0:...,lag=0   <- healthy
# slave0:...,lag=15  <- replica is 15 seconds behind
```

If lag exceeds `min-replicas-max-lag`, that replica no longer counts toward `min-replicas-to-write`. If enough replicas fall behind, the primary stops accepting writes.

**Mitigation:**
- Ensure replicas have sufficient CPU and network bandwidth
- Reduce write batches or pipeline depth if lag is persistent
- Consider `repl-disable-tcp-nodelay no` (the default) for lowest latency

### 6. Bandwidth-Driven Node Failures

**Production incident pattern** (source: Mercado Libre, Valkey Unlocked Conference): Payload size distribution causes network bandwidth saturation before CPU or memory thresholds trigger alerts. Nodes fail from bandwidth exhaustion, not traditional resource metrics.

**Mitigation:**
- Monitor payload size distribution, not just request count
- Monitor network bytes in/out per node
- Alert on bandwidth utilization (e.g., >70% of NIC capacity)
- Use MULTIPATH TCP (`repl-mptcp yes`, Valkey 9.0) to reduce network-induced latency by up to 25%

## Monitoring Checklist

| Metric | Source | Alert Threshold |
|--------|--------|-----------------|
| `master_link_status` | `INFO replication` on replica | `down` |
| Replica lag | `INFO replication` on primary | > 5 seconds |
| `rdb_last_bgsave_status` | `INFO persistence` on primary | `err` |
| Connected replicas count | `INFO replication` on primary | < expected |
| Replication backlog coverage | `repl_backlog_size` vs write rate | < 60s of writes |

## Pre-Deployment Safety Checklist

- [ ] Persistence is enabled on the primary (`appendonly yes` or `save` directives)
- [ ] `min-replicas-to-write` is set to at least 1 (if durability matters)
- [ ] `replica-read-only yes` is set on all replicas
- [ ] `repl-backlog-size` is sized for your write rate and expected disconnection window
- [ ] Auto-restart behavior is reviewed (especially if persistence is off)
- [ ] Backup procedures are tested and verified
- [ ] Monitoring and alerting cover replication lag, link status, and BGSAVE status
