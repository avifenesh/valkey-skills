# Cluster Failover

Use when you need to understand how Valkey detects node failures, how replicas get elected to replace a failed primary, or how manual failover works.

Source files: `cluster_legacy.c` (all failover logic), `cluster_legacy.h` (flag definitions)

## Contents

- Failure Detection: Two-Phase Model (line 19)
- Automatic Failover (line 84)
- Manual Failover (line 194)
- Replica Migration (line 241)
- State Machine Summary (line 256)
- Key Functions Reference (line 284)
- See Also (line 302)

---

## Failure Detection: Two-Phase Model

### Phase 1: PFAIL (Possible Failure)

A node marks another node as PFAIL when it hasn't received any response (PONG or other data) for longer than `cluster-node-timeout` milliseconds.

In `clusterCron()`:

```c
mstime_t node_delay = (ping_delay < data_delay) ? ping_delay : data_delay;

if (node_delay > server.cluster_node_timeout) {
    if (!(node->flags & (CLUSTER_NODE_PFAIL | CLUSTER_NODE_FAIL))) {
        node->flags |= CLUSTER_NODE_PFAIL;
        // If this node is a voting primary, immediately check quorum
        if (clusterNodeIsVotingPrimary(myself)) {
            markNodeAsFailingIfNeeded(node);
        }
    }
}
```

PFAIL is a local, subjective judgment. It means "I can't reach this node." The node considers both `ping_delay` (time since PING was sent) and `data_delay` (time since any data was received), using the smaller value. This prevents false positives during heavy pub/sub traffic, where a node might be sending data but unable to reply to PINGs promptly.

### Phase 2: PFAIL -> FAIL Promotion

PFAIL propagates through gossip. When a node includes another node in its gossip section with PFAIL or FAIL flags set, the receiver records a "failure report" from the sender. Only voting primaries (primaries with at least one slot) can file failure reports.

`markNodeAsFailingIfNeeded()` checks whether quorum has been reached:

```c
void markNodeAsFailingIfNeeded(clusterNode *node) {
    int failures;
    int needed_quorum = (server.cluster->size / 2) + 1;

    if (!nodeTimedOut(node)) return;  // Not in PFAIL state
    if (nodeFailed(node)) return;     // Already FAIL

    failures = clusterNodeFailureReportsCount(node);
    if (clusterNodeIsVotingPrimary(myself)) failures++;  // Count self
    if (failures < needed_quorum) return;

    // Quorum reached - promote to FAIL
    markNodeAsFailing(node);
    clusterSendFail(node->name);  // Broadcast FAIL to entire cluster
}
```

The quorum is `(cluster_size / 2) + 1` where `cluster_size` is the number of primaries with at least one slot. Failure reports expire after `cluster_node_timeout * CLUSTER_FAIL_REPORT_VALIDITY_MULT` (2x the timeout) to prevent stale reports from accumulating.

When FAIL is confirmed:
1. The PFAIL flag is cleared, FAIL flag is set
2. `fail_time` is recorded
3. A FAIL message is broadcast to force all reachable nodes to mark the node as FAIL immediately
4. If the failing node is our primary, `CLUSTER_NODE_MY_PRIMARY_FAIL` is set on ourselves and failover handling is triggered

### Clearing FAIL

`clearNodeFailureIfNeeded()` handles recovery:

- **Replicas and slot-less primaries**: FAIL is cleared as soon as the node is reachable again.
- **Primaries with slots**: FAIL is cleared only after `cluster_node_timeout * CLUSTER_FAIL_UNDO_TIME_MULT` (2x timeout) has passed AND the node is reachable AND still serving its slots (no failover occurred).

---

## Automatic Failover

When a primary enters FAIL state, its replicas compete for promotion. The entire process is driven by `clusterHandleReplicaFailover()`, called from `clusterCron()` and `clusterBeforeSleep()`.

### Preconditions

A replica proceeds with failover only if:
1. It is a replica node
2. Its primary is in FAIL state (or this is a manual failover)
3. `cluster-replica-no-failover` is not set (or this is manual)
4. Its data is recent enough per `cluster-replica-validity-factor`

### Step 1: Rank-Based Delay

Replicas don't all start elections at the same time. Each computes a delay:

```c
// Base delay proportional to node_timeout
long long delay = min(server.cluster_node_timeout / 30, 500);

// Schedule election
server.cluster->failover_auth_time = now +
    delay +                                    // Fixed propagation delay
    random() % delay;                          // Random jitter

// Rank-based additional delay (replica rank)
server.cluster->failover_auth_rank = clusterGetReplicaRank();
server.cluster->failover_auth_time += rank * (delay * 2);

// Failed-primary rank delay (prevents concurrent elections across shards)
server.cluster->failover_failed_primary_rank = clusterGetFailedPrimaryRank();
server.cluster->failover_auth_time += failed_primary_rank * delay;
```

`clusterGetReplicaRank()` orders replicas by replication offset (higher offset = lower rank = less delay). The replica most caught up with the primary gets rank 0 and starts first. Ties are broken by node name (lexicographic comparison).

**Best-ranked fast path**: If a replica determines it is rank 0, its primary is rank 0, AND all other replicas in the shard agree the primary has failed, it starts the election immediately with zero delay.

### Step 2: Request Votes

When the scheduled time arrives and no votes have been sent yet:

```c
server.cluster->currentEpoch++;
server.cluster->failover_auth_epoch = server.cluster->currentEpoch;
clusterRequestFailoverAuth();
server.cluster->failover_auth_sent = 1;
```

The replica increments the cluster-wide `currentEpoch` and broadcasts a `FAILOVER_AUTH_REQUEST` message to all nodes. The request includes the replica's claimed slots (inherited from its primary) and the new epoch.

### Step 3: Vote Granting

`clusterSendFailoverAuthIfNeeded()` runs on each primary that receives a vote request. A primary grants its vote if ALL of these conditions are met:

1. The voter is a voting primary (has slots)
2. The cluster is safe to join (not in startup delay)
3. The request epoch >= our currentEpoch
4. We haven't already voted in this epoch (`lastVoteEpoch != currentEpoch`)
5. The requester is a replica whose primary is in FAIL state (or FORCEACK for manual failover)
6. The requester's configEpoch >= the configEpoch of every current slot owner for the claimed slots

If all checks pass:
```c
server.cluster->lastVoteEpoch = server.cluster->currentEpoch;
clusterSendFailoverAuth(node);  // Send FAILOVER_AUTH_ACK
```

Each primary votes at most once per epoch. This ensures only one replica can win per election round.

### Step 4: Win Election and Promote

```c
if (server.cluster->failover_auth_count >= needed_quorum) {
    // Update configEpoch to the election epoch
    myself->configEpoch = server.cluster->failover_auth_epoch;
    // Take over the primary role
    clusterFailoverReplaceYourPrimary();
}
```

`clusterFailoverReplaceYourPrimary()` performs the actual promotion:
1. Set ourselves as a primary node (`clusterSetNodeAsPrimary`)
2. Claim all slots from the old primary (iterate the old primary's slot bitmap)
3. Update cluster state immediately
4. Broadcast our new configuration to all nodes (PONG flood)
5. Reset manual failover state
6. Delete keys in slots we don't own (cleanup)

### Timeouts

```c
auth_timeout = max(cluster_node_timeout * 2, 2000);  // Time to collect votes
auth_retry_time = auth_timeout * 2;                    // Time before retrying
```

If the election times out without quorum, the replica waits `auth_retry_time` before trying again with a new epoch.

### Epoch Conflict Handling

If a replica sees another node claim a configEpoch >= its failover epoch, the election is reset immediately:

```c
if (sender_claimed_config_epoch >= server.cluster->failover_auth_epoch) {
    server.cluster->failover_auth_time = 0;  // Reset, start new election ASAP
}
```

---

## Manual Failover

Triggered by `CLUSTER FAILOVER [FORCE|TAKEOVER]` sent to a replica.

### Standard (No Flag)

Graceful, zero-data-loss failover:

```
Replica                              Primary
  |                                    |
  |--- MFSTART ---------------------->|
  |                                    | (pauses client writes)
  |                                    |
  |<-- PING (PAUSED flag + offset) ---|
  |                                    |
  | (catches up replication to offset) |
  |                                    |
  | mf_can_start = 1                   |
  | (proceeds with election, FORCEACK) |
```

1. Replica sends `MFSTART` to its primary.
2. Primary sets `mf_end` and `mf_replica`, pauses client writes, and starts sending PINGs with the PAUSED flag and its current replication offset.
3. Replica receives the offset via a PAUSED PING and stores it in `mf_primary_offset`.
4. When the replica's replication offset catches up to `mf_primary_offset`, it sets `mf_can_start = 1`.
5. The replica starts an election immediately (no rank delay). The vote request includes the FORCEACK flag, so primaries grant votes even though the old primary isn't technically in FAIL state.

The timeout for manual failover is `server.cluster_mf_timeout` (default 5000ms, configurable since Valkey 8.1).

### FORCE

Skips the replication-offset synchronization step. The replica sets `mf_can_start = 1` immediately and proceeds with the election. This risks a small amount of data loss but works when the primary is unreachable.

### TAKEOVER

Bypasses the election entirely:

```c
clusterBumpConfigEpochWithoutConsensus();  // Self-assign a new epoch
clusterFailoverReplaceYourPrimary();       // Claim slots immediately
```

The replica unilaterally increments its configEpoch above all known epochs and claims the primary's slots. No votes are needed. This is the last resort when quorum is impossible (e.g., majority of primaries are down).

---

## Replica Migration

Separate from failover, replica migration (`clusterHandleReplicaMigration()`) automatically moves a replica from a well-covered primary to an orphaned one:

Conditions checked in `clusterCron()`:
1. There exists at least one orphaned primary (primary with slots but no healthy replicas)
2. At least one primary has >= 2 healthy replicas
3. This replica's primary has the max number of healthy replicas

The migration candidate is the replica with the smallest node ID among the primaries with the most replicas. This deterministic selection prevents multiple replicas from migrating simultaneously.

The migration barrier (`cluster-migration-barrier`, default 1) sets the minimum number of replicas that must remain with the source primary after migration.

---

## State Machine Summary

```
Normal Operation
    |
    | node_timeout exceeded (no response)
    v
PFAIL (local, per-observing-node)
    |
    | quorum of primaries report PFAIL via gossip
    v
FAIL (broadcast to all nodes)
    |
    | replica with highest offset starts first
    v
Election (FAILOVER_AUTH_REQUEST)
    |
    | majority of voting primaries grant AUTH_ACK
    v
Promotion (replica becomes primary)
    |
    | broadcast new config, claim slots
    v
New Primary serving traffic
```

---

## Key Functions Reference

| Function | Purpose |
|----------|---------|
| `markNodeAsFailingIfNeeded()` | Check quorum, promote PFAIL to FAIL |
| `markNodeAsFailing()` | Set FAIL flag, record time, trigger failover |
| `clearNodeFailureIfNeeded()` | Clear FAIL when node recovers |
| `clusterHandleReplicaFailover()` | Drive the entire automatic failover state machine |
| `clusterGetReplicaRank()` | Rank replicas by replication offset |
| `clusterGetFailedPrimaryRank()` | Rank failed primaries to stagger elections |
| `clusterSendFailoverAuthIfNeeded()` | Validate and grant a failover vote |
| `clusterFailoverReplaceYourPrimary()` | Execute promotion: claim slots, broadcast |
| `clusterHandleManualFailover()` | Drive manual failover offset synchronization |
| `clusterHandleReplicaMigration()` | Move replica to orphaned primary |
| `resetManualFailover()` | Clear all manual failover state |

---

## See Also

- [Sentinel Mode](../sentinel/sentinel-mode.md) - Sentinel provides failover for standalone (non-cluster) deployments using a separate monitoring process with SDOWN/ODOWN detection and Raft-like leader election, compared to cluster's integrated gossip-based PFAIL/FAIL protocol
- [Cluster Overview](overview.md) - Gossip protocol, PFAIL/FAIL propagation, and cluster state determination that feed into the failover process
- [Replication Overview](../replication/overview.md) - Dual replication IDs (`replid`/`replid2`) and `shiftReplicationId()` enable partial resync after failover without a full RDB transfer
- [RDB Snapshot Persistence](../persistence/rdb.md) - After failover promotion, replicas of the new primary perform full resync which triggers an RDB snapshot via BGSAVE
- [Event Loop](../architecture/event-loop.md) - `clusterHandleReplicaFailover()` runs from both `clusterCron()` (time event) and `clusterBeforeSleep()` (before-sleep hook), driving the failover state machine within the event loop cycle
