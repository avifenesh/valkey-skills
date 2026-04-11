# Cluster Operations

Use when performing manual failovers, checking cluster health, diagnosing node issues, or planning for cluster scalability.

## Contents

- Manual Failover (line 16)
- Cluster Health Checks (line 95)
- Automatic Replica Migration (line 186)
- Cluster Scalability (line 208)
- Operational Runbook: Rolling Restart (line 248)

---

## Manual Failover

Manual failover promotes a replica to primary in a controlled way. Use this for planned maintenance, not emergencies.

### Standard Failover (Zero Data Loss)

Execute on the replica you want to promote:

```bash
valkey-cli -p 7003 -a "password" CLUSTER FAILOVER
```

The sequence:

1. Replica sends MFSTART to its primary
2. Primary pauses client writes and sends its current replication offset
3. Replica catches up to the primary's offset
4. Replica starts an election with FORCEACK (primaries grant votes even though the old primary is not in FAIL state)
5. Replica wins election and claims the primary's slots
6. Old primary becomes a replica of the new primary

The timeout for manual failover defaults to 5000ms (configurable since Valkey 8.1). If the replica cannot catch up within this window, the failover is aborted.

Source: `cluster_legacy.c` - `clusterHandleManualFailover()`, `server.cluster_mf_timeout`

### FORCE Failover

Skips the replication-offset synchronization step. The replica proceeds immediately to election without waiting to catch up. Use when the primary is unreachable but you still want an election (requires a majority of primaries to be reachable for voting).

```bash
valkey-cli -p 7003 -a "password" CLUSTER FAILOVER FORCE
```

Risk: a small amount of unreplicated writes may be lost.

### TAKEOVER Failover

Bypasses the election entirely. The replica unilaterally assigns itself a new configEpoch above all known epochs and claims the primary's slots. No votes are needed.

```bash
valkey-cli -p 7003 -a "password" CLUSTER FAILOVER TAKEOVER
```

Use as a last resort when the majority of primaries are unreachable and a normal election is impossible. This can cause slot assignment conflicts if the cluster later re-merges with a different view of ownership. Particularly relevant for multi-DC deployments where the majority of primaries were in the failed DC and automatic failover cannot proceed.

Source: `cluster_legacy.c` - `clusterBumpConfigEpochWithoutConsensus()`, `clusterFailoverReplaceYourPrimary()`

### Automatic Failover Timing

Typical cluster failover time: `NODE_TIMEOUT + 1-2 seconds`. With default `cluster-node-timeout` of 15000ms, failover completes in ~16-17 seconds.

The timeline: PFAIL detected at NODE_TIMEOUT, FAIL declared after majority of primaries report PFAIL (within 2 * NODE_TIMEOUT), then replicas start elections with a rank-based delay of `500ms + random(0-500ms) + REPLICA_RANK * 1000ms`. The best-ranked replica (rank 0, where all replicas agree on FAIL) starts its election immediately with no additional delay beyond the base. Note: the 500ms base delay assumes the default `cluster-node-timeout` of 15000ms (the base is calculated as `min(cluster_node_timeout/30, 500)`).

**Client-visible downtime**: In the cluster tutorial's failover test, the system was unable to accept 578 reads and 577 writes during a simulated primary crash with continuous write load. No data inconsistency was created. This represents ~5-15 seconds of client errors during automatic failover.

### PFAIL/FAIL State Machine

- **PFAIL** (Possible Failure): Local to each node. Set when a node is unreachable for `NODE_TIMEOUT`. Not sufficient to trigger failover.
- **FAIL**: Set when a majority of primaries report PFAIL/FAIL within `NODE_TIMEOUT * 2` (`FAIL_REPORT_VALIDITY_MULT = 2`). This triggers the replica election.
- **FAIL clearing**: Mostly one-way. Can only be cleared when the node is reachable and is a replica, or is a primary with no slots, or enough time has passed (`N * NODE_TIMEOUT`) without replica promotion.

The weak agreement protocol means PFAIL->FAIL does not require simultaneous consensus - it is gossip-collected over a time window. This is sufficient for safety because the actual failover election uses a strict majority vote.

Source: `cluster_legacy.c` - PFAIL is set when node is unresponsive for `cluster_node_timeout`, FAIL reports expire after `cluster_node_timeout * 2`

### Comparison: Cluster vs Sentinel Failover

Both use a majority-vote protocol, but differ in structure. Sentinel is a separate process that monitors non-clustered Valkey; cluster failover is built into the data nodes themselves. Sentinel uses SDOWN/ODOWN detection with a configurable quorum, while cluster uses PFAIL/FAIL with gossip-based agreement. See [Sentinel Architecture](sentinel-architecture.md) for the Sentinel protocol details.

### Comparison

| Mode | Data Loss | Requires Primary | Requires Majority | Use Case |
|------|-----------|-----------------|-------------------|----------|
| (default) | None | Yes (must be reachable) | Yes | Planned maintenance |
| FORCE | Possible (small) | No | Yes | Primary unreachable, majority available |
| TAKEOVER | Possible | No | No | Emergency, majority unavailable |

---

## Cluster Health Checks

### Quick Health Check

```bash
valkey-cli --cluster check 192.168.1.10:7000 -a "password"
```

This verifies:
- All 16384 slots are assigned
- All nodes are reachable
- Replication is functioning
- No slots are in migrating/importing state

### Cluster State

```bash
valkey-cli -p 7000 -a "password" CLUSTER INFO
```

Key fields:

| Field | Healthy Value | Description |
|-------|---------------|-------------|
| `cluster_state` | ok | `ok` if all slots are covered and no FAIL nodes; `fail` otherwise |
| `cluster_slots_assigned` | 16384 | Must equal 16384 |
| `cluster_slots_ok` | 16384 | Slots served by non-FAIL nodes |
| `cluster_slots_pfail` | 0 | Slots on possibly-failed nodes |
| `cluster_slots_fail` | 0 | Slots on confirmed-failed nodes |
| `cluster_known_nodes` | (expected count) | Total nodes in the cluster |
| `cluster_size` | (expected primaries) | Number of primaries with at least one slot |

### Node Status

```bash
valkey-cli -p 7000 -a "password" CLUSTER NODES
```

Output format (one line per node):

```
<node-id> <ip:port@cport> <flags> <primary-id|--> <ping-sent> <pong-recv> <config-epoch> <link-state> <slots>
```

Key flags to watch for:

| Flag | Meaning | Action |
|------|---------|--------|
| `master` | Primary node | Normal |
| `slave` | Replica node | Normal |
| `myself` | This node | Informational |
| `pfail` | Possible failure (local judgment) | Monitor - may resolve on its own |
| `fail` | Confirmed failure (quorum agreement) | Investigate immediately; failover should trigger automatically |
| `handshake` | Node joining, not yet acknowledged | Wait for completion |
| `noaddr` | No address known | Node configuration issue |
| `nofailover` | Will not participate in failover | Intentional if `cluster-replica-no-failover` is set |

### Fix Broken Clusters

```bash
# Reassign orphaned slots and fix inconsistencies
valkey-cli --cluster fix 192.168.1.10:7000 -a "password"
```

This attempts to:
- Assign uncovered slots to available primaries
- Clear stuck MIGRATING/IMPORTING states
- Resolve slot ownership conflicts

Use with caution in production - review the proposed changes before confirming.

### Per-Node Diagnostics

```bash
# Replication status on a specific node
valkey-cli -p 7000 -a "password" INFO replication

# Memory usage
valkey-cli -p 7000 -a "password" INFO memory

# Connected clients
valkey-cli -p 7000 -a "password" INFO clients

# Slot distribution
valkey-cli -p 7000 -a "password" CLUSTER SLOTS
# or (Valkey 8+):
valkey-cli -p 7000 -a "password" CLUSTER SHARDS
```

---

## Automatic Replica Migration

Valkey Cluster automatically migrates a replica from a well-covered primary to an orphaned one (a primary with slots but no healthy replicas). This is configured via:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `cluster-migration-barrier` | 1 | Minimum replicas that must remain with a primary after migration |

The migration candidate is the replica with the smallest node ID among the primaries with the most replicas. This deterministic selection prevents multiple replicas from migrating simultaneously.

Source: `cluster_legacy.c` - `clusterHandleReplicaMigration()`

Set `cluster-allow-replica-migration no` to disable automatic migration. Setting `cluster-migration-barrier` to 0 means a primary can donate its last replica.

### Surplus Replica Strategy

Instead of giving every primary 2 replicas (expensive), give 3 or 4 extra replicas to select primaries. Replica migration will automatically redistribute them to cover failures.

Example: 10 primaries, each with 1 replica (20 nodes), plus 3 additional replicas on arbitrary primaries (23 nodes total). When Primary-X's replica fails, one of the surplus replicas migrates to cover Primary-X. When Primary-X itself later fails, the migrated replica promotes. The cluster survives 2 sequential failures that would otherwise be fatal.

---

## Cluster Scalability

### Limits

Valkey 9.0 supports clusters up to 2,000 nodes, capable of over 1 billion requests per second aggregate. Key scalability improvements in 8.1/9.0:

- **Serialized failover with ranking** (8.1): Multiple primary failures no longer cause vote collisions. Shards are ranked by lexicographic shard ID; higher-rank shards failover first, lower-rank shards add delay.
- **Reconnection throttling** (9.0): Nodes no longer storm reconnections to failed nodes every 100ms. Throttled to reasonable attempts within `cluster-node-timeout`.
- **Lightweight pub/sub headers** (9.0): Cluster bus pub/sub messages no longer carry the full 2KB slot bitmap. Light header is ~30 bytes.

The practical scaling considerations:

| Factor | Impact | Mitigation |
|--------|--------|------------|
| Gossip overhead | Increases with N^2 connections | Cluster bus uses lightweight protocol; gossip messages carry limited node samples |
| Failure detection time | `cluster-node-timeout` applies per-node | Keep timeout reasonable (15s default); too low causes false positives |
| Slot migration | More nodes means more potential resharding operations | Use atomic migration (9.0+) for faster, less disruptive resharding |
| Client routing | More nodes means more potential redirects | Use smart client libraries that maintain slot-to-node mapping |

### Sizing Guidelines

| Cluster Size | Typical Use | Notes |
|--------------|-------------|-------|
| 6 nodes (3P+3R) | Small to medium workloads | Minimum HA deployment |
| 12-18 nodes | Medium to large workloads | Good balance of capacity and operational simplicity |
| 30-60 nodes | Large-scale deployments | Consider separate monitoring and management tooling |
| 100+ nodes | Very large scale | Requires careful `cluster-node-timeout` tuning and robust monitoring |

### CLUSTER SHARDS (Valkey 8+)

For large clusters, `CLUSTER SHARDS` provides a more structured view than `CLUSTER NODES`:

```bash
valkey-cli -p 7000 -a "password" CLUSTER SHARDS
```

Returns shard-oriented output grouped by primary with slot ranges and replica lists, making it easier to assess topology in large deployments.

---

## Operational Runbook: Rolling Restart

To restart all nodes without downtime:

```bash
# 1. Start with replicas (order does not matter among replicas)
for port in 7003 7004 7005; do
  valkey-cli -p $port -a "password" SHUTDOWN NOSAVE
  # Wait for restart via systemd
  sleep 5
  valkey-cli -p $port -a "password" PING
done

# 2. For each primary, failover first, then restart
for port in 7000 7001 7002; do
  # Find a replica of this primary
  REPLICA=$(valkey-cli -p $port -a "password" INFO replication | grep "slave0:ip" | cut -d, -f1 | cut -d= -f2)
  REPLICA_PORT=$(valkey-cli -p $port -a "password" INFO replication | grep "slave0:ip" | cut -d, -f2 | cut -d= -f2)

  # Failover to the replica
  valkey-cli -p $REPLICA_PORT -a "password" CLUSTER FAILOVER
  sleep 5

  # Restart the now-replica
  valkey-cli -p $port -a "password" SHUTDOWN NOSAVE
  sleep 5
  valkey-cli -p $port -a "password" PING
done
```

---
