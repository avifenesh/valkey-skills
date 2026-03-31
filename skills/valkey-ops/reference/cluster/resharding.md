# Cluster Resharding

Use when moving hash slots between nodes, adding or removing cluster nodes, or migrating to Valkey 9.0's atomic slot migration.

## Contents

- Resharding Overview (line 16)
- Traditional Resharding (Key-by-Key) (line 28)
- Atomic Slot Migration (Valkey 9.0+) (line 84)
- Adding Nodes (line 171)
- Removing Nodes (line 214)
- See Also (line 246)

---

## Resharding Overview

Resharding moves hash slots (and their keys) from one node to another. Common reasons:

- Rebalancing load after adding a new primary
- Draining a node before decommissioning
- Adjusting capacity for hot shards

Two approaches exist: the traditional key-by-key method (all versions) and atomic slot migration (Valkey 9.0+).

---

## Traditional Resharding (Key-by-Key)

An external tool (typically `valkey-cli --cluster reshard`) orchestrates key migration one slot at a time:

```
1. Target:  CLUSTER SETSLOT <slot> IMPORTING <source-id>
2. Source:  CLUSTER SETSLOT <slot> MIGRATING <target-id>
3. Loop:
   a. Source:  CLUSTER GETKEYSINSLOT <slot> <count>
   b. Source:  MIGRATE <target-ip> <target-port> "" 0 5000 KEYS <key1> <key2> ...
4. All nodes: CLUSTER SETSLOT <slot> NODE <target-id>
```

Source: `cluster_legacy.c` - `clusterCommandSetSlot()`, `cluster.c` - `migrateCommand()`

### Interactive Resharding

```bash
valkey-cli --cluster reshard 192.168.1.10:7000 -a "password"
```

The tool will prompt for:
- Number of slots to move
- Destination node ID
- Source node IDs (or `all` for balanced redistribution)

### Automated Resharding

```bash
valkey-cli --cluster reshard 192.168.1.10:7000 \
  --cluster-from <source-node-id> \
  --cluster-to <target-node-id> \
  --cluster-slots 1000 \
  --cluster-yes \
  -a "password"
```

### Rebalancing

Redistribute slots evenly across all primaries:

```bash
valkey-cli --cluster rebalance 192.168.1.10:7000 -a "password"
```

### Limitations of Traditional Migration

| Issue | Impact |
|-------|--------|
| Large keys block the event loop | A multi-million element set causes latency spikes during MIGRATE |
| ASK redirect storms | Every missing key on the source triggers a redirect; high-throughput slots are disruptive |
| External orchestration required | The tool must repeatedly call GETKEYSINSLOT and MIGRATE |
| Single-database only | Only migrates keys from the default database |

---

## Atomic Slot Migration (Valkey 9.0+)

Valkey 9.0 introduces `CLUSTER MIGRATESLOTS` - a server-driven approach that transfers entire slots at once using fork-based snapshotting and streaming replication.

Source: `cluster_migrateslots.c`, `cluster_migrateslots.h`

### How It Works

1. **Snapshot**: Source forks a child process that writes an RDB-format snapshot of all keys in the target slots
2. **Stream**: After the snapshot, the source streams incremental writes (like replication) to the target
3. **Pause and cutover**: Source pauses client writes briefly, target takes ownership atomically
4. **Cleanup**: Source deletes remaining keys in transferred slots

### Command Syntax

```bash
# On the source node:
CLUSTER MIGRATESLOTS SLOTSRANGE <start> <end> NODE <target-node-id>

# Multiple ranges to multiple targets in a single command:
CLUSTER MIGRATESLOTS \
  SLOTSRANGE 0 5460 NODE <target-1-id> \
  SLOTSRANGE 5461 10922 NODE <target-2-id>
```

### Monitoring and Cancellation

```bash
# List all active and completed migration jobs
CLUSTER GETSLOTMIGRATIONS

# Cancel all in-progress exports
CLUSTER CANCELSLOTMIGRATIONS
```

Each job reports its current state: connecting, snapshotting, replicating, paused, success, or failed.

### Performance Comparison

Benchmarked with a 40GB dataset, 16KB string keys, c4-standard-8 GCE VMs (from Valkey blog):

| Scenario | Traditional | Atomic | Speedup |
|----------|------------|--------|---------|
| No load, 3 to 4 shards | 1m42s | 10.7s | 9.5x |
| No load, 4 to 3 shards | 1m20s | 9.5s | 8.4x |
| Heavy load, 3 to 4 shards | 2m27s | 31s | 4.75x |
| Heavy load, 4 to 3 shards | 2m5s | 27s | 4.6x |

The speedup comes from eliminating per-key network round trips. Legacy migration of 4096 slots with 160 keys/slot at batch size 10 requires ~213,000 round trips. At 300us RTT, that is over 1 minute of pure network waiting.

Key advantages:
- No `-ASK` redirections during migration - clients are completely unaware
- No multi-key operation failures during migration (MGET/MSET work normally)
- Large keys are streamed as individual element commands (AOF format), not serialized as a single huge payload - no OOM or input buffer overflows
- No event loop blocking for large keys (fork-based)
- Built-in rollback on failure via `CLUSTER CANCELSLOTMIGRATIONS`
- Observable via `CLUSTER GETSLOTMIGRATIONS` (status, duration, failure descriptions)

### Failure Handling

The migration can fail due to: connection loss, ACK timeout, child process OOM during snapshot, slot ownership change by another node, FLUSHDB during migration, node demotion, or user cancellation. On failure, both source and target clean up automatically. The operator must restart the migration.

Source: `cluster_migrateslots.c` - `proceedWithSlotMigration()`, `finishSlotMigrationJob()`

### Configuration Tuning

| Parameter | Purpose |
|-----------|---------|
| `client-output-buffer-limit replica` | Must be large enough to hold accumulated mutations during the snapshot phase. If the buffer overflows, the migration fails. |
| `slot-migration-max-failover-repl-bytes` | For high-write workloads, allows migration to proceed to the pause phase even if some mutations are still in-flight (below this threshold). |
| `cluster-slot-migration-log-max-len` | Number of completed/failed migration entries retained in memory. |

### Write-Loss Window

After the source grants ownership transfer, there is a brief window where the source is paused but has not yet received the target's topology update. If the target crashes during this window, the source eventually unpauses (timeout) and may accept writes that conflict with the target's state. This is logged as a warning.

### Resilience Improvements (Valkey 8.0+)

These improvements reduce the risk of slot ownership loss during and after migration:

- **CLUSTER SETSLOT replication**: The SETSLOT command is now replicated to replicas and waits up to 2s for acknowledgment. Prevents slot ownership loss if the primary crashes immediately after SETSLOT.
- **Election in empty shards**: A primary can be elected in a shard with no slots, ensuring the shard is ready to receive slots during migration.
- **Auto-repair of migrating/importing state**: If a primary fails during legacy migration, the other shard's primary automatically updates its state to pair with the new primary.
- **Replica ASK redirects**: Replicas can now return ASK redirects during slot migrations, where previously they had no awareness.

---

## Adding Nodes

### Add a Primary

```bash
# Add the new node to the cluster (starts with 0 slots)
valkey-cli --cluster add-node 192.168.1.16:7006 192.168.1.10:7000 \
  -a "password"

# Reshard slots to the new node
valkey-cli --cluster reshard 192.168.1.10:7000 \
  --cluster-to <new-node-id> \
  --cluster-from all \
  --cluster-slots 4096 \
  --cluster-yes \
  -a "password"
```

Or with atomic migration (9.0+):

```bash
# On an existing primary, migrate a range to the new node:
CLUSTER MIGRATESLOTS SLOTSRANGE 0 4095 NODE <new-node-id>
```

### Add a Replica

```bash
# Add as replica of a specific primary
valkey-cli --cluster add-node 192.168.1.16:7007 192.168.1.10:7000 \
  --cluster-replica \
  --cluster-master-id <primary-node-id> \
  -a "password"
```

Or from the node itself:

```bash
valkey-cli -p 7007 -a "password" CLUSTER REPLICATE <primary-node-id>
```

---

## Removing Nodes

### Remove a Replica

```bash
valkey-cli --cluster del-node 192.168.1.10:7000 <replica-node-id> \
  -a "password"
```

### Remove a Primary

A primary must have zero slots before it can be removed. Reshard all slots to other primaries first:

```bash
# Move all slots from the node being removed
valkey-cli --cluster reshard 192.168.1.10:7000 \
  --cluster-from <node-to-remove-id> \
  --cluster-to <destination-node-id> \
  --cluster-slots <total-slots-on-node> \
  --cluster-yes \
  -a "password"

# Verify the node has 0 slots
valkey-cli -p 7000 -a "password" CLUSTER NODES | grep <node-to-remove-id>

# Remove the empty node
valkey-cli --cluster del-node 192.168.1.10:7000 <node-to-remove-id> \
  -a "password"
```

---

## See Also

- [Cluster Setup](setup.md) - initial cluster creation and hash slot basics
- [Cluster Operations](operations.md) - manual failover, health checks
- [Cluster Consistency](consistency.md) - write safety during migrations
- [Replication Tuning](../replication/tuning.md) - backlog sizing (relevant for `client-output-buffer-limit replica` during migration)
