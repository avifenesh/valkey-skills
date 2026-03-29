# Cluster Operations

Use when performing manual failovers, checking cluster health, diagnosing node issues, or planning for cluster scalability.

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

Use as a last resort when the majority of primaries are unreachable and a normal election is impossible. This can cause slot assignment conflicts if the cluster later re-merges with a different view of ownership.

Source: `cluster_legacy.c` - `clusterBumpConfigEpochWithoutConsensus()`, `clusterFailoverReplaceYourPrimary()`

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

---

## Cluster Scalability

### Limits

Valkey 9.0 supports clusters up to 2,000 nodes, capable of over 1 billion requests per second aggregate.

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

## See Also

- [Cluster Setup](setup.md) - creating a cluster, hash slots, configuration
- [Cluster Resharding](resharding.md) - moving slots, adding/removing nodes
- [Cluster Consistency](consistency.md) - write safety during partitions
- [Troubleshooting Cluster Partitions](../troubleshooting/cluster-partitions.md) - diagnosing cluster issues
- [See valkey-dev: cluster/failover](../valkey-dev/reference/cluster/failover.md) - PFAIL/FAIL detection, election protocol, replica rank delay
