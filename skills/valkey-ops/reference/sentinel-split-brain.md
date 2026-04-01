# Split-Brain Prevention

Use when planning for network partition scenarios, configuring write safety for Sentinel-managed deployments, or troubleshooting data loss after a failover.

## Contents

- The Split-Brain Problem (line 17)
- How Sentinel Prevents Split-Brain (line 29)
- Configuring Write Safety (line 51)
- Network Partition Scenarios (line 68)
- Operational Checklist (line 116)
- What min-replicas Cannot Prevent (line 128)

---

## The Split-Brain Problem

A network partition can isolate the primary from its replicas and Sentinels. During the partition:

1. The majority partition (containing most Sentinels) detects the primary as failed and promotes a replica
2. The minority partition (containing the old primary) may still accept writes from connected clients
3. When the partition heals, the old primary discovers a new primary exists and becomes a replica - discarding all writes it accepted during the partition

This is the fundamental trade-off of asynchronous replication: the system favors availability over consistency.

---

## How Sentinel Prevents Split-Brain

Sentinel's design includes several built-in protections:

### Majority Requirement

Failover requires an absolute majority of Sentinels (`> voters/2`), not just the configured quorum. This ensures that only the partition containing more than half the Sentinels can trigger a failover. The minority partition never triggers failover on its own.

Example with 5 Sentinels: a partition creating a 2-3 split means only the side with 3 Sentinels can authorize a failover.

### Single-Vote-Per-Epoch

Each Sentinel votes at most once per epoch, preventing multiple conflicting failovers from succeeding simultaneously.

Source: `sentinel.c` - `sentinelVoteLeader()` checks `leader_epoch < req_epoch` before granting a vote

### TILT Mode

If Sentinel detects clock anomalies (time delta > 2 seconds between timer invocations), it enters TILT mode and suspends all acting decisions for 30 seconds. This prevents incorrect failover decisions due to process freezes or clock jumps.

---

## Configuring Write Safety

The primary defense against split-brain data loss is configuring the primary to stop accepting writes when it cannot reach enough replicas.

### min-replicas-to-write and min-replicas-max-lag

Configure the primary to stop accepting writes when it cannot confirm replication:

```
min-replicas-to-write 1
min-replicas-max-lag 10
```

The primary tracks each replica's last acknowledged offset via `REPLCONF ACK`. When the count of replicas with recent ACKs drops below `min-replicas-to-write`, the primary rejects writes with `-NOREPLICAS`. See [Replication Safety](../replication/safety.md) for the full parameter reference, sizing guidelines, and deployment recommendations.

---

## Network Partition Scenarios

### Scenario 1: Primary Isolated from Replicas and Sentinels

```
Partition A (minority):        Partition B (majority):
+----------+                   +----------+  +----------+  +----------+
|  Primary |                   | Replica1 |  | Replica2 |  | Sentinel |
|  Client  |                   | Sentinel |  | Sentinel |  |          |
+----------+                   +----------+  +----------+  +----------+
```

**Without `min-replicas-to-write`**: Primary in partition A keeps accepting writes. Sentinels in partition B promote Replica1. When the partition heals, the old primary becomes a replica and discards all writes it accepted during the split.

**With `min-replicas-to-write 1`**: Primary in partition A stops accepting writes after `min-replicas-max-lag` seconds (default 10s). Data loss is limited to the writes accepted in that lag window. **Trade-off**: if both replicas go down (not partitioned, just crashed), the primary also stops accepting writes. Availability is sacrificed for consistency.

### Scenario 2: Sentinel Quorum Split

```
Partition A:                   Partition B:
+----------+  +----------+    +----------+  +----------+  +----------+
|  Primary |  | Sentinel |    | Replica  |  | Sentinel |  | Sentinel |
+----------+  +----------+    +----------+  +----------+  +----------+
```

With 3 Sentinels and quorum=2: Partition B has 2 Sentinels (meets quorum) and the majority (2 of 3). Failover proceeds in partition B. The primary in partition A continues serving, but with `min-replicas-to-write 1` it will stop writes since it has no connected replicas.

### Scenario 3: Even Sentinel Split (Anti-Pattern)

```
Partition A:                   Partition B:
+----------+  +----------+    +----------+  +----------+
|  Primary |  | Sentinel |    | Replica  |  | Sentinel |
+----------+  +----------+    +----------+  +----------+
```

With only 2 Sentinels: if the primary's box fails, S1 also fails. S2 alone cannot achieve majority (needs 2 of 2). The system is DOWN with no failover. If quorum=1 and S2 could somehow failover, a network partition creates TWO primaries with no way to resolve which is correct. This is explicitly documented as "DON'T DO THIS" in the official Sentinel docs. **Rule: NEVER deploy 2 Sentinels.**

### Scenario 4: Client on the Wrong Side

Even with `min-replicas-to-write`, a client library connected to the old primary through a private network path may continue sending writes during the lag window. To minimize this:

1. Use Sentinel-aware client libraries that subscribe to `+switch-master` events
2. Set aggressive connection timeouts on clients
3. Use `WAIT 1 <timeout>` for critical writes to confirm replication before returning success

---

## Operational Checklist

| Check | Command | Expected |
|-------|---------|----------|
| Quorum health | `SENTINEL ckquorum mymaster` | "OK `<n>` usable Sentinels" |
| Replica count | `SENTINEL replicas mymaster` | At least `min-replicas-to-write` replicas listed |
| Replication lag | `INFO replication` on primary | All replicas showing `lag` < `min-replicas-max-lag` |
| Sentinel count | `SENTINEL sentinels mymaster` | Expected number of Sentinels (odd, >= 3) |
| Config consistency | `SENTINEL get-primary-addr-by-name mymaster` on all Sentinels | All return the same address |

---

## What min-replicas Cannot Prevent

These settings reduce the data loss window but do not eliminate it:

1. **Lag window writes**: Writes accepted during the `min-replicas-max-lag` seconds before the primary detects it is isolated are still lost
2. **Async replication gap**: Even with `min-replicas-to-write >= 1`, writes are acknowledged before replication; a simultaneous crash of primary and all replicas loses those writes
3. **Clock skew**: If the primary's clock is wrong, the lag calculation may be inaccurate

For stronger guarantees, use `WAIT <numreplicas> <timeout>` on individual commands that require synchronous replication confirmation.

---
