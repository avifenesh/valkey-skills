# Cluster Partition Issues

Use when cluster state is degraded, nodes are marked as failed, slots are uncovered, or clients receive CLUSTERDOWN errors.

## Contents

- Symptoms (line 19)
- Diagnosis (line 28)
- Network Split Scenarios (line 105)
- Resolution (line 133)
- Prevention (line 208)
- Large Key Migration Blocked (Cluster Incident Pattern) (line 228)
- Cluster Scaling Improvements (Valkey 8.1+) (line 246)

---

## Symptoms

- `CLUSTER INFO` returns `cluster_state:fail`
- Clients receive: `CLUSTERDOWN The cluster is down`
- `CLUSTER NODES` shows nodes with `fail` or `pfail` flags
- `cluster_slots_ok` is less than 16384
- Intermittent `-MOVED` or `-ASK` redirections to unreachable nodes
- Split-brain: replicas promoting to primaries on both sides of a partition

## Diagnosis

### Step 1: Check Cluster State

```bash
valkey-cli CLUSTER INFO
```

| Field | Healthy Value | Problem Indicator |
|-------|--------------|-------------------|
| `cluster_state` | `ok` | `fail` |
| `cluster_slots_assigned` | 16384 | < 16384 (unassigned slots) |
| `cluster_slots_ok` | 16384 | < 16384 (uncovered slots) |
| `cluster_slots_pfail` | 0 | > 0 (possible failures) |
| `cluster_slots_fail` | 0 | > 0 (confirmed failures) |
| `cluster_known_nodes` | expected count | lower = nodes missing |
| `cluster_size` | expected count | lower = primaries missing |

### Step 2: Inspect Node Topology

```bash
valkey-cli CLUSTER NODES
```

Each line shows: `<id> <ip:port@cport> <flags> <master-id> <ping-sent> <pong-recv> <config-epoch> <link-state> <slots>`

Flags to watch:
- `fail` - node confirmed failed by majority
- `pfail` - node possibly failed (detected by this node but not yet confirmed)
- `handshake` - node in handshake state (not yet joined)
- `noaddr` - node address unknown

Check `link-state` column: `connected` or `disconnected`.

### Step 3: Test Network Connectivity

Valkey cluster uses two ports per node:
- Client port (default 6379)
- Cluster bus port (client port + 10000, so 16379)

Both must be reachable between all nodes.

```bash
# Test client port
nc -zv <node-ip> 6379

# Test cluster bus port
nc -zv <node-ip> 16379

# Test from each node to every other node
for node in node1 node2 node3 node4 node5 node6; do
  echo "=== Testing $node ==="
  nc -zv $node 6379
  nc -zv $node 16379
done
```

### Step 4: Check Cluster Node Timeout

Source-verified: `cluster-node-timeout` defaults to 15000ms (15 seconds)
in `src/config.c` line 3430.

```bash
valkey-cli CONFIG GET cluster-node-timeout
```

A node is marked `pfail` when it has not responded to pings for
`cluster-node-timeout` milliseconds. It is promoted to `fail` when the
majority of primaries agree on the failure within `cluster-node-timeout * 2`.

### Step 5: Check Logs

```bash
# Check each node's logs for failure detection and failover events
journalctl -u valkey --since "1 hour ago" | grep -i "fail\|election\|vote\|partition"
```

## Network Split Scenarios

### Scenario 1: Minority Partition

A minority of primaries lose connectivity to the majority. The majority side
continues operating. The minority side:
- Cannot reach quorum for writes (if `cluster-require-full-coverage yes`)
- Replicas on the majority side get promoted to replace failed primaries
- When connectivity restores, minority nodes rejoin as replicas

### Scenario 2: Even Split

With an even number of primaries, a 50/50 split means neither side has a
majority. Both sides go into `fail` state. This is why odd numbers of primaries
(3, 5, 7) are recommended.

### Scenario 3: Single Node Failure

One primary becomes unreachable. After `cluster-node-timeout`, its replica
is promoted via automatic failover. The cluster remains available if the
failed primary had at least one replica.

### Scenario 4: Bus Port Blocked

If only the cluster bus port (16379) is blocked but the client port (6379)
works, nodes cannot gossip. They will mark each other as failed even though
they are individually healthy. Check firewall rules for both ports.

## Resolution

### 1. Restore Network Connectivity

Fix the underlying network issue first. Once connectivity is restored, nodes
will automatically rejoin and sync.

```bash
# Verify firewall rules
iptables -L -n | grep -E "6379|16379"

# Ensure both ports are open
firewall-cmd --add-port=6379/tcp --permanent
firewall-cmd --add-port=16379/tcp --permanent
firewall-cmd --reload
```

### 2. Manual Failover

If a primary is permanently lost and has a replica available:

```bash
# On the replica that should become primary
valkey-cli -h <replica-host> -p <replica-port> CLUSTER FAILOVER

# For force failover (when primary is unreachable)
valkey-cli -h <replica-host> -p <replica-port> CLUSTER FAILOVER FORCE

# Last resort when even the replica can't coordinate
valkey-cli -h <replica-host> -p <replica-port> CLUSTER FAILOVER TAKEOVER
```

### 3. Fix Slot Coverage

```bash
# Automatic cluster repair
valkey-cli --cluster fix <any-node-host>:<port>

# Check slot coverage
valkey-cli --cluster check <any-node-host>:<port>
```

The `--cluster fix` command will:
- Reassign uncovered slots to existing primaries
- Fix migrating/importing slot states left from interrupted migrations

### 4. Remove Permanently Lost Nodes

```bash
# Get the node ID of the lost node
valkey-cli CLUSTER NODES | grep fail

# Forget it on EVERY remaining node
for node in node1:6379 node2:6379 node3:6379; do
  valkey-cli -h ${node%:*} -p ${node#*:} CLUSTER FORGET <node-id>
done
```

The `CLUSTER FORGET` command must be sent to all remaining nodes within
60 seconds (before gossip re-adds the forgotten node).

### 5. Add Replacement Nodes

```bash
# Add a new node to the cluster
valkey-cli --cluster add-node <new-host>:<port> <existing-host>:<port>

# Assign it as a replica
valkey-cli --cluster add-node <new-host>:<port> <existing-host>:<port> \
  --cluster-replica --cluster-master-id <master-id>

# Rebalance slots if needed
valkey-cli --cluster rebalance <any-node-host>:<port>
```

## Prevention

```
# Require all slots covered for cluster to accept writes
cluster-require-full-coverage yes

# Allow reads during partition (if acceptable for your use case)
cluster-allow-reads-when-down no

# Set reasonable timeout
cluster-node-timeout 15000

# Enable replica migration (replicas move to orphan primaries)
cluster-migration-barrier 1
```

Use an odd number of primary nodes (3, 5, 7) to avoid even-split scenarios.
Ensure each primary has at least one replica. Place replicas in different
failure domains (racks, availability zones).

## Large Key Migration Blocked (Cluster Incident Pattern)

**Symptoms**: Slot migration hangs, `CLUSTER NODES` shows slot in
`migrating`/`importing` state indefinitely, multi-key commands on the affected
slot fail.

**Root cause**: A very large key (e.g., sorted set with millions of members)
exceeds the target node's input buffer limit during key-by-key migration.

**Resolution (pre-Valkey 9.0)**: Increase `proto-max-bulk-len` on the target
node, or delete the large key and re-create, or force slot assignment with
`CLUSTER SETSLOT <slot> NODE <node-id>` (data loss for keys in that slot).

**Valkey 9.0 fix**: Atomic slot migration replaces key-by-key migration. Entire
slots are migrated atomically using AOF format for streaming, preventing
large-key blocking and eliminating mini-outages for multi-key operations during
migration. This also enables 4.6-9.5x faster cluster resharding.

## Cluster Scaling Improvements (Valkey 8.1+)

For large clusters (hundreds to thousands of nodes):

- **Ranked failover elections** - Replicas are ranked by replication offset so
  the most up-to-date replica always tries first, preventing vote collisions
  during multi-primary failures.
- **Reconnection throttling** - Prevents reconnect storms to failed nodes
  (previously every 100ms per node).
- **Optimized failure reports** - Radix tree storage grouped by second,
  reducing overhead in large clusters.

---
