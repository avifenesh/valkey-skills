Use when evaluating Valkey Cluster's write safety for your use case, understanding what can go wrong during network partitions, or deciding between consistency and availability trade-offs.

# Cluster Consistency Guarantees

## Contents

- Consistency Model (line 17)
- What Can Go Wrong (line 25)
- Write Safety Mechanisms (line 62)
- Cluster State Determination (line 118)
- Trade-Offs Operators Should Understand (line 130)
- Failure Detection Timing (line 171)
- See Also (line 181)

---

## Consistency Model

Valkey Cluster uses **asynchronous replication**. The primary acknowledges a write to the client before replicating it to replicas. This is a deliberate trade-off: higher throughput and lower latency at the cost of potential data loss during failures.

Valkey Cluster does NOT provide strong consistency. It provides eventual consistency under normal operation and best-effort consistency during failures.

---

## What Can Go Wrong

### Scenario 1: Primary Crash Before Replication

```
Client -> Primary (acknowledges write) -> [CRASH] -> Replica (never received write)
```

The write is confirmed to the client but lost. The promoted replica does not have it.

**Window**: The time between the primary acknowledging the write and the replica receiving and acknowledging it. Typically sub-millisecond on a healthy local network, but can be larger under load or network congestion.

### Scenario 2: Network Partition with Minority Writes

```
Partition A (minority):        Partition B (majority):
+----------+                   +----------+  +----------+  +----------+
|  Primary |  <- clients       | Replica  |  | Primary  |  | Primary  |
+----------+    writing        +----------+  | (shard2) |  | (shard3) |
                               (promoted)    +----------+  +----------+
```

1. A primary is isolated in the minority partition
2. Clients connected to this primary continue writing
3. The majority partition promotes the replica
4. When the partition heals, the old primary discovers a new primary and becomes a replica - discarding all writes it accepted during the partition

**Window**: Up to `cluster-node-timeout` before the cluster detects the failure, plus the failover election time. With the default 15-second timeout, this window can be 15-20 seconds of potentially lost writes. The minority primary stops accepting writes after `NODE_TIMEOUT` because it can no longer reach the majority of primaries, which provides a built-in bound on the data loss window.

### Scenario 3: Stale Client Routing

A client with a cached slot routing table may continue sending writes to a node that has lost ownership of a slot (after resharding or failover). The node responds with `-MOVED`, but there is a brief window where the client may not yet know about the topology change.

This is generally handled by client libraries that refresh their routing table on MOVED responses. The data loss risk here is minimal.

---

## Write Safety Mechanisms

### WAIT Command

For critical writes, use `WAIT` to block until a specified number of replicas have acknowledged the write:

```bash
SET important:key "value"
WAIT 1 5000
# Returns the number of replicas that acknowledged within 5000ms
```

| Parameter | Description |
|-----------|-------------|
| `numreplicas` | Number of replicas that must acknowledge |
| `timeout` | Maximum wait time in milliseconds (0 = wait forever) |

`WAIT` is synchronous - it blocks the client connection until the condition is met or the timeout expires. It does NOT make the write transactional or prevent the write from succeeding if replicas are unreachable. The write is already applied on the primary; `WAIT` only confirms replication.

Important: `WAIT` reduces but does not eliminate the data loss window. If the primary crashes after `WAIT` returns but before the replica applies the write (e.g., during a network partition that started after the ACK), the write can still be lost.

### min-replicas-to-write (Server-Side)

Configure each cluster primary to reject writes when not enough replicas are connected. This applies per-node, not cluster-wide - each primary independently checks its own replica count.

```
min-replicas-to-write 1
min-replicas-max-lag 10
```

When the number of connected, non-lagging replicas drops below the threshold, all write commands are rejected with `-NOREPLICAS`. See [Replication Safety](../replication/safety.md) for the full parameter reference, sizing guidelines, and deployment recommendations.

### cluster-require-full-coverage

When enabled (default), the cluster rejects all writes if any of the 16384 slots are unassigned or served by a node in FAIL state. This prevents writes to a degraded cluster but reduces availability.

| Setting | Behavior | Trade-off |
|---------|----------|-----------|
| `yes` (default) | Reject writes when any slot is uncovered | Consistency: no partial writes to a degraded cluster |
| `no` | Accept writes to slots that are still covered | Availability: surviving shards continue serving |

Source: `cluster_legacy.c` - `clusterUpdateState()` checks full slot coverage and majority partition

### cluster-allow-reads-when-down

When the cluster state is FAIL, this setting controls whether read commands are still served:

| Setting | Behavior |
|---------|----------|
| `no` (default) | All commands rejected when cluster is FAIL |
| `yes` | Read commands served for locally-owned slots even when cluster is FAIL |

Useful for read-heavy workloads that can tolerate stale data during a partition.

---

## Cluster State Determination

The cluster state (OK vs FAIL) is computed by `clusterUpdateState()`:

1. **Full coverage check**: If `cluster-require-full-coverage` is on, every slot must be assigned to a non-FAIL node. Any gap means CLUSTER_FAIL.
2. **Majority partition check**: The number of reachable primaries (with slots) must form a majority (`size / 2 + 1`). If not, the cluster enters CLUSTER_FAIL with reason MINORITY_PARTITION.
3. **Startup delay**: A primary that just restarted waits before accepting writes, giving the cluster time to reconfigure.

Source: `cluster_legacy.c` - `clusterUpdateState()`, `CLUSTER_FAIL_MINORITY_PARTITION`

---

## Trade-Offs Operators Should Understand

| Decision | Consistency | Availability | Performance |
|----------|------------|--------------|-------------|
| Default config (async replication) | Low - writes can be lost on crash | High - always available | Best - no sync overhead |
| `WAIT 1 5000` per critical write | Medium - confirmed on 1 replica | High (unless replica down) | Lower - blocks per write |
| `min-replicas-to-write 1` | Medium - stops writes when isolated | Lower - unavailable if replicas lag | No impact when healthy |
| `cluster-require-full-coverage yes` | Higher - no partial cluster writes | Lower - entire cluster stops on any uncovered slot | No impact when healthy |
| All combined | Highest achievable | Lowest | Moderate overhead |

### Recommendations by Use Case

**Cache (data can be regenerated)**:
```
# Accept data loss, maximize availability
cluster-require-full-coverage no
cluster-allow-reads-when-down yes
min-replicas-to-write 0
```

**Session store (loss is inconvenient)**:
```
# Balance availability and consistency
cluster-require-full-coverage yes
min-replicas-to-write 1
min-replicas-max-lag 10
```

**Financial/critical data (loss is unacceptable)**:
```
# Maximize consistency, accept lower availability
cluster-require-full-coverage yes
min-replicas-to-write 1
min-replicas-max-lag 5
# Application-level: WAIT 1 5000 after every write
```

For truly strong consistency requirements, consider whether Valkey Cluster is the right choice. Consensus-based systems (etcd, ZooKeeper, CockroachDB) provide linearizability at the cost of performance and simplicity.

---

## Failure Detection Timing

Understanding the timing helps estimate the data loss window. See [Cluster Operations](operations.md) for full failover timing, the PFAIL/FAIL state machine, and replica election delay.

Summary: typical failover time is `NODE_TIMEOUT + 1-2 seconds` (~16-17s with defaults). The data loss window during a partition equals the time before the isolated primary stops accepting writes - bounded by `cluster-node-timeout` (the primary detects it cannot reach the majority of primaries) or `min-replicas-max-lag` (whichever fires first).

Lowering `cluster-node-timeout` reduces the failure detection window but increases the risk of false positives (transient network issues triggering unnecessary failovers).

---
