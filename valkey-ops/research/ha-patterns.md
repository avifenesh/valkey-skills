# High Availability Patterns - Deep Research

Research conducted 2026-03-29. Sources: Valkey official documentation (sentinel, cluster-tutorial, cluster-spec, replication topics), Valkey blog posts (operational-lessons, atomic-slot-migration, introducing-valkey-9, 1-billion-rps), and community production reports from the Unlocked Conference.

---

## 1. Sentinel Deployment Patterns

### 3 vs 5 Sentinels

**3 Sentinels (quorum=2)** - the minimum viable deployment. Tolerates 1 Sentinel failure. Majority is 2, so failover proceeds if 2 of 3 are reachable. This is the recommended starting point for most deployments.

**5 Sentinels (quorum=2 or 3)** - tolerates 2 Sentinel failures. With quorum=2, failure detection is more sensitive (only 2 need to agree on SDOWN->ODOWN), but authorization still requires majority (3). With quorum=3, both detection and authorization require 3, reducing false positives.

**Quorum vs majority distinction**: The quorum only controls failure detection (SDOWN->ODOWN transition). Authorization to actually perform the failover always requires an absolute majority (`> voters/2`). With 5 Sentinels and quorum=2: 2 Sentinels detect the failure, but 3 must authorize the failover. This is a key nuance that operators frequently misunderstand.

**Recommendation**: Use 5 Sentinels for production systems where Valkey is a critical data store. Use 3 Sentinels for caching-only use cases or where infrastructure cost is a constraint. Never use 2 - this creates a single point of failure (if the box with the primary + S1 goes down, S2 alone cannot authorize failover).

### Cross-Datacenter Sentinel Placement

**Pattern: 2-2-1 across 3 DCs**
```
DC-A: Primary + S1 + S2
DC-B: Replica + S3 + S4
DC-C: S5 (tiebreaker)
```
Quorum=3 ensures no single DC failure triggers unwanted failover. DC-C's sole Sentinel acts as the tiebreaker. If DC-A goes down, S3+S4+S5 (3 of 5) authorize failover to DC-B's replica.

**Pattern: 2-1 across 2 DCs (with application servers)**
```
DC-A: Primary + S1
DC-B: Replica + S2
App-Servers: S3, S4, S5 (collocated with clients)
```
Quorum=3. This places Sentinels where clients are, so failover reflects client connectivity. Documented in the official docs as "Example 3: Sentinel in the client boxes." The advantage: if a primary is reachable by the majority of clients, it stays primary. The disadvantage: no ability to use `min-replicas-to-write` to bound data loss since there is only one replica.

**Docker/NAT warning**: Sentinel auto-discovery breaks with port remapping. Each Sentinel announces its own IP:port via hello messages. With NAT/Docker port mapping, announced addresses are wrong. Use `sentinel announce-ip` and `sentinel announce-port` or run Docker with `--net=host`.

### Sentinel Timing Parameters (Production Values)

| Parameter | Default | Production Recommendation | Reasoning |
|-----------|---------|--------------------------|-----------|
| `down-after-milliseconds` | 30000 | 5000-10000 for low-latency; 30000 for cross-DC | Controls SDOWN detection. Lower = faster failover but higher false positive risk |
| `failover-timeout` | 180000 | 60000-180000 | Controls: (1) time before retrying failed failover, (2) time for replicas to reconfig, (3) time for MOVED state |
| `parallel-syncs` | 1 | 1 | Number of replicas that resync simultaneously after failover. Higher = faster failover completion but more replicas temporarily unavailable |
| Sentinel PING interval | 1000ms | Not configurable | Sentinel PINGs monitored instances every 1 second |
| Hello message interval | 2000ms | Not configurable | Sentinels publish to `__sentinel__:hello` every 2 seconds |
| INFO polling interval | 10000ms (1000ms during failover) | Not configurable | Sentinel polls INFO from instances |

### Coordinated Failover (Valkey 9.0+)

Valkey 9.0 introduced `SENTINEL FAILOVER <primary> COORDINATED` which performs an orderly handover using the server-side `FAILOVER` command. This is a planned maintenance feature that:

1. The Sentinel is elected leader for the failover
2. The current primary is told to hand off to the selected replica
3. The primary pauses writes, waits for the replica to catch up on replication offset, then the replica promotes itself
4. No data loss because the replica is fully caught up before promotion

**Warning**: Client libraries must fully implement the Sentinel client protocol (not just pub/sub) to handle the fast role change. Clients relying only on pub/sub messages may reconnect to the old (now-demoted) primary and get READONLY errors.

---

## 2. Cluster Topology Patterns

### 3-Primary, 6-Node (Standard)

The minimum recommended production topology. 3 primaries with 1 replica each.

```
Primary-A (slots 0-5460)      -> Replica-A1
Primary-B (slots 5461-10922)  -> Replica-B1
Primary-C (slots 10923-16383) -> Replica-C1
```

- Survives any single node failure
- Cannot survive simultaneous failure of a primary and its replica
- With `cluster-require-full-coverage yes` (default): cluster goes down if any slot range is uncovered
- Probability of cluster unavailability after 2 random node failures: `1/(5*2-1) = 11.11%`

### 6-Primary, 12-Node (Scaled)

Doubles throughput linearly. Same fault tolerance characteristics but lower per-node memory requirements. The 11.11% unavailability risk drops because more nodes mean lower probability that the 2 failures hit the same shard.

### Multi-DC Cluster Patterns

**Pattern: Replica per DC**
```
DC-A: Primary-A, Primary-B, Primary-C
DC-B: Replica-A1, Replica-B1, Replica-C1
```
On DC-A failure, all replicas in DC-B promote. Works with `cluster-node-timeout` detection. Problem: all primaries are in one DC, so DC-A failure requires promoting 3 replicas simultaneously.

**Pattern: Spread primaries across DCs**
```
DC-A: Primary-A, Replica-B1, Replica-C1
DC-B: Primary-B, Replica-A1, Primary-C
```
Better fault distribution. Single DC failure loses at most 1-2 primaries, not all.

**`replica-priority` for DC affinity**: Set lower priority values on replicas in the same DC as clients to prefer local promotion. Example: same-DC replicas at priority 10, cross-DC replicas at priority 100. Sentinel and Cluster both use this for replica selection. Priority 0 means "never promote."

**`CLUSTER FAILOVER TAKEOVER`**: For multi-DC scenarios where the majority partition is unreachable but you need to force promotion in the remaining DC. This bypasses the majority vote requirement but creates a new `configEpoch` unsafely. Use only for disaster recovery.

### Replica Migration (Automatic Rebalancing)

Cluster has built-in replica migration: when a primary becomes an orphan (no replicas), a replica from a primary with multiple replicas will automatically migrate to cover it.

**Configuration**: `cluster-migration-barrier <count>` - minimum number of replicas a primary must retain before one can migrate away. Default is 1.

**Strategy**: Instead of giving every primary 2 replicas (expensive), give 3 or 4 extra replicas to select primaries. Replica migration will automatically redistribute them to cover failures.

Example: 10 primaries, each with 1 replica (20 nodes), plus 3 additional replicas on arbitrary primaries (23 nodes total). When Primary-X's replica fails, one of the surplus replicas migrates to cover Primary-X. When Primary-X itself later fails, the migrated replica promotes. The cluster survives 2 sequential failures that would otherwise be fatal.

### Large Cluster Scaling (Valkey 9.0 - Up to 2000 Nodes)

Valkey 9.0 brought major improvements to cluster bus scalability, demonstrated at 2000 nodes achieving 1 billion RPS.

Key improvements:
- **Serialized failover with ranking**: Multiple primary failures no longer cause vote collisions. Shards are ranked by lexicographic shard ID; higher-rank shards failover first, lower-rank shards add delay. (Valkey 8.1, by Binbin Zhu)
- **Reconnection throttling**: Nodes no longer storm reconnections to failed nodes every 100ms. Throttled to reasonable attempts within `cluster-node-timeout`. (by Sarthak Aggarwal)
- **Optimized failure report tracking**: Radix tree storage for failure reports grouped by second, eliminating duplicate processing. (by Seungmin Lee)
- **Lightweight pub/sub headers**: Cluster bus pub/sub messages no longer carry the full 2KB slot bitmap. Light header is ~30 bytes.

Gossip overhead formula (from cluster spec): In a 100-node cluster with 60s node-timeout, each node pings ~99 nodes every 30 seconds = 3.3 pings/second per node = 330 pings/second cluster-wide. This scales linearly and has not been a reported bandwidth issue.

---

## 3. Failover Timing Analysis

### Sentinel Failover Timeline

```
T=0:     Primary becomes unreachable
T+1s:    First missed PING reply (Sentinel PINGs every 1s)
T+Nms:   down-after-milliseconds elapsed -> SDOWN flagged
         (default 30s, production: 5-10s)
T+Nms:   Sentinel queries other Sentinels for ODOWN agreement
         (via SENTINEL is-master-down-by-addr)
T+Nms:   ODOWN reached (quorum Sentinels agree)
T+Nms:   Leader election begins (Sentinels vote)
T+Nms:   Leader elected -> FAILOVER starts
T+Nms:   Leader sends REPLICAOF NO ONE to selected replica
T+Nms:   Replica promotes itself
T+Nms:   Leader observes promotion in INFO output -> failover success
T+Nms:   Other replicas reconfigured (limited by parallel-syncs)
```

**Typical end-to-end failover time**: `down-after-milliseconds + 1-2 seconds` for Sentinel coordination.

- With `down-after-milliseconds` = 5000: ~6-7 seconds total
- With `down-after-milliseconds` = 30000: ~31-32 seconds total
- Cross-DC with `down-after-milliseconds` = 60000: ~61-62 seconds total

The 1-2 second overhead includes: SDOWN->ODOWN gossip convergence, leader election (one round), and the `REPLICAOF NO ONE` + promotion detection.

### Cluster Failover Timeline

```
T=0:          Primary becomes unreachable
T+NODE_TIMEOUT:  Peers mark node as PFAIL
T+2*NODE_TIMEOUT: Majority primaries report PFAIL -> FAIL declared
              (FAIL_REPORT_VALIDITY_MULT = 2)
T+FAIL+DELAY: Replica election starts after:
              DELAY = 500ms + random(0-500ms) + REPLICA_RANK * 1000ms
T+DELAY+vote: Election requires majority of primaries to vote
              (wait up to 2*NODE_TIMEOUT, minimum 2 seconds)
T+elected:    Replica promotes, broadcasts new configEpoch
```

**Typical cluster failover time**: `NODE_TIMEOUT + 1-2 seconds` from the official docs. With default `cluster-node-timeout` of 15000ms, failover completes in ~16-17 seconds.

**From the Valkey 9.0 benchmark (1 billion RPS blog)**:
- Recovery time for multiple primary failures measured from PFAIL detection to all slots covered
- With ranking mechanism, recovery time is bounded and consistent even with many simultaneous failures
- Chart shows recovery completing within the node-timeout window plus election delay

**Manual failover (CLUSTER FAILOVER)**: Near-zero downtime. The primary pauses writes, the replica catches up on replication offset, then promotes. Clients are blocked briefly during the handover. Typical time: under 1 second for the actual promotion, bounded by replication lag.

### Client-Visible Downtime

From the cluster tutorial failover test: "the system was not able to accept 578 reads and 577 writes" during a simulated primary crash with continuous write load. No data inconsistency was created. This represents ~5-15 seconds of client errors during automatic failover.

---

## 4. Split-Brain Scenarios and Outcomes

### Scenario: 3-Node Sentinel with M1 Partitioned

```
Partition A (minority):      Partition B (majority):
+----+                       +------+    +----+
| M1 | <- Client C1          | [M2] |    | R3 |
| S1 |                       |  S2  |    | S3 |
+----+                       +------+    +----+
```

**Outcome**: S2+S3 detect M1 as ODOWN, authorize failover, promote R2 to M2. C1 continues writing to M1 in the minority partition. When partition heals, M1 discovers M2 exists, converts to replica, and ALL writes C1 sent during the partition are LOST.

**Mitigation**: Configure `min-replicas-to-write 1` and `min-replicas-max-lag 10` on the primary. M1 will stop accepting writes after 10 seconds of being unable to replicate. This bounds the data loss window to 10 seconds.

**Trade-off**: If both replicas go down (not partitioned, just crashed), the primary also stops accepting writes. Availability is sacrificed for consistency.

### Scenario: Cluster Partition with Minority Primary

```
Partition A (minority):      Partition B (majority):
+----------+                 +----------+  +----------+
| Primary-B|<- Client Z1     | Replica-B|  | Primary-A|
+----------+                 |(promoted)|  +----------+
                             +----------+  | Primary-C|
                                           +----------+
```

**Outcome**: Z1 writes to Primary-B in the minority. After `NODE_TIMEOUT`, the majority promotes Replica-B. Simultaneously, Primary-B stops accepting writes because it can't reach the majority of primaries. Maximum data loss window = `NODE_TIMEOUT`.

With default `cluster-node-timeout` of 15000ms: up to 15 seconds of writes to the minority primary can be lost.

### Scenario: 2-Sentinel Deployment (Anti-Pattern)

```
+----+         +----+
| M1 |---------| R1 |
| S1 |         | S2 |
+----+         +----+
```

**Outcome**: If M1's box fails, S1 also fails. S2 alone cannot achieve majority (needs 2 of 2). The system is DOWN with no failover. If quorum=1 and S2 could somehow failover, a network partition creates TWO primaries with no way to resolve which is correct.

**Rule**: NEVER deploy 2 Sentinels. This is explicitly documented as "DON'T DO THIS" in the official docs.

### Cluster-Specific: PFAIL/FAIL State Machine

- **PFAIL** (Possible Failure): Local to each node. Set when a node is unreachable for `NODE_TIMEOUT`. Not sufficient for failover.
- **FAIL**: Set when a majority of primaries report PFAIL/FAIL within `NODE_TIMEOUT * 2`. Triggers replica election.
- **FAIL clearing**: FAIL is "mostly one way." It can only be cleared when: (1) the node is reachable and is a replica, (2) the node is reachable and is a primary with no slots, or (3) the node is reachable and enough time has passed (`N * NODE_TIMEOUT`) without replica promotion.

The weak agreement protocol means: PFAIL->FAIL does not require simultaneous consensus. It is gossip-collected over a time window. This is sufficient for safety because the actual failover election uses a strict majority vote.

---

## 5. Replication Patterns and Tuning

### Asynchronous Replication Mechanics

1. Primary sends write commands to replicas in the replication stream
2. Replicas acknowledge processed offset periodically (every 1 second by default)
3. Primary tracks `master_repl_offset` and each replica's `slave_repl_offset`
4. The delta between these offsets is the replication lag

**WAIT command**: `WAIT <numreplicas> <timeout>` blocks the client until N replicas acknowledge the current offset or timeout expires. Does NOT make the system strongly consistent - a replica can still be promoted that did not receive the write if it crashes after acknowledging.

### Replication Backlog Sizing

| Write Rate | Max Disconnect | Safety Factor | Recommended Backlog |
|-----------|----------------|---------------|-------------------|
| 1 MB/s | 30s | 2x | 60 MB |
| 5 MB/s | 60s | 2x | 600 MB |
| 20 MB/s | 120s | 2x | 4800 MB (~5 GB) |
| 50 MB/s | 60s | 2x | 6000 MB (~6 GB) |

Default `repl-backlog-size` is 10MB - far too small for any production write-heavy workload. If the backlog overflows during a disconnect, the replica must do a FULL resync (expensive RDB transfer).

`repl-backlog-ttl` (default 3600s): How long to retain the backlog after the last replica disconnects. Set to 0 to retain forever if replicas might reconnect after long outages.

### Partial Resynchronization (PSYNC)

On reconnect, a replica sends `PSYNC <replication-id> <offset>`. The primary checks:
1. Does the replication ID match (current or secondary)?
2. Is the requested offset still within the backlog?

If both yes: partial resync (just the missing commands). If no: full resync (RDB snapshot + backlog).

**After failover**: The promoted replica retains its old replication ID as a secondary ID. Other replicas reconnecting can PSYNC using the old ID + offset, avoiding full resync. This is why Valkey uses two replication IDs.

### Diskless Replication

For full resyncs, the primary can stream the RDB directly to replicas without writing to disk first. Controlled by:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `repl-diskless-sync` | `yes` (8.0+) | Stream RDB to replicas without disk |
| `repl-diskless-sync-delay` | `5` | Seconds to wait for more replicas before starting |
| `repl-diskless-sync-period` | `0` | Minimum seconds between diskless syncs |
| `repl-diskless-load` | `disabled` | Replica loads RDB from socket directly to memory |

**Production recommendation**: Enable diskless sync when disk I/O is a bottleneck or when using cloud instances with slow EBS volumes. The `repl-diskless-sync-delay` allows batching multiple replica syncs into a single RDB generation.

### Replication Safety: Persistence-Off Primary

**Critical danger**: If the primary has persistence disabled (no RDB, no AOF) and auto-restarts after a crash, it starts with an EMPTY dataset. All connected replicas will then sync with the empty primary and LOSE ALL DATA.

**Rule**: If persistence is off on the primary, disable automatic restart. Let Sentinel/Cluster promote a replica that has the data.

### Monitoring Replication Lag

Key metrics from `INFO replication`:

```
# On primary
connected_slaves:2
slave0:ip=10.0.1.2,port=6379,state=online,offset=12345678,lag=0
slave1:ip=10.0.1.3,port=6379,state=online,offset=12345670,lag=1
master_repl_offset:12345678
repl_backlog_active:1
repl_backlog_size:104857600

# On replica
master_link_status:up
master_last_io_seconds_ago:0
master_sync_in_progress:0
slave_repl_offset:12345678
slave_read_repl_offset:12345678
```

**Alert thresholds**:
- `master_link_status:down` - immediate alert
- `lag > 5` seconds - warning
- `lag > 30` seconds - critical
- `master_repl_offset - slave_repl_offset > repl_backlog_size * 0.8` - backlog nearly full, full resync imminent

---

## 6. Dual-Channel Replication

Dual-channel replication was a proposed feature in the Valkey development process but is NOT documented as a released feature in the official Valkey docs as of 9.0. The `replication.md` documentation does not mention it.

The concept: Use a separate TCP connection for RDB transfer during full resync, allowing the main replication link to continue streaming incremental commands. This would reduce the "pause" during full syncs where the replica falls behind.

**Status**: Not confirmed as shipped in any release. The existing replication docs cover standard single-channel async replication, diskless replication, and PSYNC.

**What exists instead**: Diskless replication (`repl-diskless-sync`) is the primary mechanism for improving full-sync performance. The `repl-diskless-load` option on replicas can further reduce the sync window by loading the RDB directly from the socket.

---

## 7. Atomic Slot Migration (Valkey 9.0)

### How It Works

Unlike legacy key-by-key migration, atomic slot migration replicates entire slots using a fork-based snapshot process:

1. Source node receives `CLUSTER MIGRATESLOTS SLOTSRANGE <start> <end> NODE <target>`
2. Source connects to target, authenticates, sends `CLUSTER SYNCSLOTS ESTABLISH`
3. Source forks a child process to snapshot all keys in the migrating slots
4. Child streams the snapshot as commands; parent tracks mutations to migrating slots
5. After snapshot completes, parent sends accumulated mutations
6. When mutations are caught up, source pauses writes briefly
7. Target takes ownership, broadcasts to cluster
8. Source deletes the migrated keys and unpauses writes; clients get MOVED

### Performance Benchmarks (from Valkey blog)

Test: 40GB dataset, 16KB string keys, c4-standard-8 GCE VMs

| Test Case | Legacy | Atomic | Speedup |
|-----------|--------|--------|---------|
| No Load: 3 to 4 shards | 1m42s | 10.7s | 9.52x |
| No Load: 4 to 3 shards | 1m20s | 9.5s | 8.44x |
| Heavy Load: 3 to 4 shards | 2m27s | 31s | 4.75x |
| Heavy Load: 4 to 3 shards | 2m05s | 27s | 4.62x |

The speedup comes from eliminating per-key network round trips. Legacy migration of 4096 slots with 160 keys/slot at batch size 10 requires 212,992 round trips. At 300us RTT, that is >1 minute of pure network waiting.

### Advantages Over Legacy Migration

- **No ASK redirections**: Clients are completely unaware of ongoing migration. Slot ownership does not transfer until fully replicated.
- **No multi-key operation failures**: Since all keys remain on the source until atomic handover, MGET/MSET work normally.
- **Large key safety**: Collections are streamed as individual element commands (using AOF format), not serialized as a single huge payload. No more OOM or input buffer overflows.
- **Built-in rollback**: On failure or cancellation (`CLUSTER CANCELSLOTMIGRATIONS`), the staging area on the target is cleaned up. No manual intervention needed.
- **Observable**: `CLUSTER GETSLOTMIGRATIONS` provides status, duration, and failure descriptions.

### Configuration Tuning

- `client-output-buffer-limit replica` - Must be large enough to hold accumulated mutations during the snapshot phase. If the buffer overflows, the migration fails.
- `slot-migration-max-failover-repl-bytes` - For high-write workloads, allows the migration to proceed to the pause phase even if some mutations are still in-flight (below this threshold).
- `cluster-slot-migration-log-max-len` - Number of completed/failed migration entries retained in memory.

### Resilience Improvements (Valkey 8.0+)

- **CLUSTER SETSLOT replication** (8.0): The SETSLOT command is replicated to replicas and waits up to 2s for acknowledgment. Prevents slot ownership loss if the primary crashes immediately after SETSLOT.
- **Election in empty shards** (8.0): A primary can be elected in a shard with no slots, ensuring the shard is ready to receive slots during migration.
- **Auto-repair of migrating/importing state** (8.0): If a primary fails during legacy migration, the other shard's primary automatically updates its state to pair with the new primary.
- **Replica ASK redirects** (8.0): Replicas can now return ASK redirects during slot migrations, where previously they had no awareness.

---

## 8. Cross-Datacenter Replication

### Active-Passive Pattern

```
DC-A (Active):   Primary-A, Primary-B, Primary-C (serving reads + writes)
DC-B (Passive):  Replica-A1, Replica-B1, Replica-C1 (read replicas or standby)
```

- All writes go to DC-A
- DC-B replicas serve read traffic or remain on standby
- On DC-A failure: promote DC-B replicas (manual or automatic with CLUSTER FAILOVER TAKEOVER)
- Cross-DC replication lag is typically 1-10ms on same-region links, 50-200ms cross-region

**Risks**:
- `cluster-node-timeout` must be larger than cross-DC RTT to avoid false failovers. Default 15s is usually fine for cross-region.
- Full resync across WAN is expensive. Size the replication backlog generously for cross-DC links.
- Clock skew between DCs can trigger Sentinel TILT mode. Use NTP.

### Active-Active (Not Natively Supported)

Valkey does NOT support active-active multi-master replication. Each key has exactly one owner (the primary for that slot). There is no CRDT or conflict resolution mechanism.

Workarounds:
- **Application-level sharding by region**: Different slots/key prefixes per DC, with full cluster spanning both DCs
- **Proxy-based solutions**: Route writes to the correct primary based on key, allow reads from local replicas
- **External CRDT layers**: Solutions like Dynomite or application-level conflict resolution

### Disaster Recovery Procedures

**Sentinel-managed DR failover**:
1. Verify the primary is truly unreachable (not a transient network issue)
2. If Sentinel has not automatically failed over (e.g., minority partition), force: `SENTINEL FAILOVER <primary-name>`
3. Monitor `+switch-master` event in Sentinel pub/sub
4. Verify new primary is serving: `SENTINEL get-master-addr-by-name <primary-name>`
5. When old DC recovers, the old primary will automatically become a replica

**Cluster DR failover**:
1. If majority of primaries are in the surviving DC, automatic failover proceeds normally
2. If majority of primaries were in the failed DC, the cluster is in error state. Use `CLUSTER FAILOVER TAKEOVER` on replicas in the surviving DC to force promotion without majority vote
3. After forced promotion, verify with `CLUSTER INFO`: `cluster_state:ok`, `cluster_slots_ok:16384`
4. When failed DC recovers, old primaries will receive UPDATE messages and convert to replicas

**Post-incident verification**:
```bash
# Check cluster health
valkey-cli --cluster check <any-node-ip>:6379

# Verify all slots covered
valkey-cli CLUSTER INFO | grep cluster_slots

# Check for data loss (compare key counts)
valkey-cli INFO keyspace

# Verify replication is healthy
valkey-cli INFO replication
```

---

## 9. Production Incident Patterns and Mitigations

### Pattern: Cascading Full Resyncs

**Trigger**: Primary restart or brief network blip causes all replicas to reconnect simultaneously.
**Problem**: If the replication backlog is undersized, all replicas trigger full resync. The primary forks for each (or batches with diskless sync delay), consuming massive memory and CPU.
**Mitigation**:
- Size `repl-backlog-size` generously (see sizing table above)
- Use `repl-diskless-sync yes` with `repl-diskless-sync-delay 5` to batch replica syncs
- Monitor `sync_full` and `sync_partial_ok` counters in `INFO stats`

### Pattern: Large Key Blocking During Migration (Pre-9.0)

**Trigger**: Legacy slot migration encounters a sorted set with 10M+ members.
**Problem**: The MIGRATE command serializes the entire key, requiring contiguous memory on both source and target. Can cause OOM or timeout, blocking the migration.
**Mitigation**: Upgrade to Valkey 9.0 and use atomic slot migration, which streams collection members as individual commands.

### Pattern: Pub/Sub Amplification in Large Clusters

**Trigger**: Global pub/sub messages in a 100+ node cluster.
**Problem**: Each pub/sub message is broadcast to all nodes via the cluster bus with 2KB headers.
**Mitigation**: Use sharded pub/sub (available since Redis 7.0 / Valkey). Messages stay within the shard. Valkey 9.0 also uses lightweight ~30-byte headers for pub/sub messages.

### Pattern: Bandwidth-Driven Node Failures

**Source**: Mercado Libre production experience, presented at Unlocked Conference.
**Trigger**: Payload size distribution causes network bandwidth saturation before CPU or memory thresholds trigger alerts.
**Problem**: Nodes fail from bandwidth exhaustion, not traditional resource metrics.
**Mitigation**:
- Monitor payload size distribution, not just request count
- Monitor network bytes in/out per node
- Alert on bandwidth utilization (e.g., >70% of NIC capacity)
- Use MULTIPATH TCP (Valkey 9.0) to reduce network-induced latency by up to 25%

### Pattern: Vote Collision During Multi-Primary Failure (Pre-8.1)

**Trigger**: Multiple primaries crash simultaneously in a large cluster.
**Problem**: Replicas of different failed primaries start elections at the same time, causing vote splits. No shard achieves majority, requiring manual intervention.
**Mitigation**: Valkey 8.1 introduced shard-rank-based election delay. Higher-ranked shards elect first, lower-ranked shards wait. Guarantees bounded recovery time even with many simultaneous failures.

### Pattern: Reconnection Storm to Failed Nodes

**Trigger**: Hundreds of nodes fail in a large cluster.
**Problem**: Each surviving node attempts to reconnect to all failed nodes every 100ms, consuming significant CPU.
**Mitigation**: Valkey 9.0 throttles reconnection attempts to a reasonable rate within the `cluster-node-timeout` window.

---

## 10. Operational Lessons from Large-Scale Deployments

### From the Valkey Unlocked Conference (2026)

**"Scale exposes all truths"** (Khawaja Shams):
- Latency that feels negligible at low scale becomes visible at high scale
- Client behavior that looked harmless shapes tail latencies under load
- Operational shortcuts that worked at small volumes introduce instability at scale

**Five Guiding Performance Principles (Madelyn Olson)**:
1. (unstated - likely throughput)
2. Provide predictable user latency
3-5. (consistency is treated as a first-order goal alongside scalability and simplicity)

**Key operational metrics to track**:
- P99 AND P999 latency (not just medians) - tail percentiles reveal the edge cases that cause outages
- Payload size distribution alongside traditional metrics - bandwidth saturation appears before CPU/memory pressure
- Traffic shape as a first-class metric - bursty workloads explain instability better than raw request counts

**Valkey 9.0 improvements addressing these lessons**:
- Reply copy-avoidance for large values (reduces main event loop blocking)
- Pipeline memory prefetching (up to 40% higher throughput)
- MULTIPATH TCP support (up to 25% latency reduction)
- SIMD for BITCOUNT and HyperLogLog (up to 200% throughput improvement)

### Configuration Recommendations for Production

```
# Cluster mode
cluster-enabled yes
cluster-node-timeout 15000
cluster-require-full-coverage no  # Prefer availability over full-coverage guarantee
cluster-allow-reads-when-down yes  # Allow reads during partial failures
cluster-migration-barrier 1  # Enable replica migration

# Replication safety
min-replicas-to-write 1
min-replicas-max-lag 10

# Replication performance
repl-backlog-size 256mb  # Size based on write rate
repl-diskless-sync yes
repl-diskless-sync-delay 5

# IO threading (8+ core machines)
io-threads 6  # 1 main + 5 IO threads
io-threads-do-reads yes

# Persistence (if needed)
save ""  # Disable RDB if using AOF or external backup
appendonly yes
appendfsync everysec
```

---

## Sources

1. Valkey Official Documentation - Sentinel: https://valkey.io/topics/sentinel/
2. Valkey Official Documentation - Cluster Tutorial: https://valkey.io/topics/cluster-tutorial/
3. Valkey Official Documentation - Cluster Specification: https://valkey.io/topics/cluster-spec/
4. Valkey Official Documentation - Replication: https://valkey.io/topics/replication/
5. Valkey Official Documentation - Atomic Slot Migration: https://valkey.io/topics/atomic-slot-migration/
6. Valkey Blog - "Operational Lessons from Large-Scale Valkey Deployments" (2026-02-19)
7. Valkey Blog - "Resharding, Reimagined: Introducing Atomic Slot Migration" (2025-10-29)
8. Valkey Blog - "Valkey 9.0: innovation, features, and improvements" (2025-10-21)
9. Valkey Blog - "Scaling a Valkey Cluster to 1 Billion Requests per Second" (2025-10-20)
10. Valkey source code: `sentinel.c`, `cluster.c`, `replication.c`
