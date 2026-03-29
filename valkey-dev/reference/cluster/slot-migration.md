# Slot Migration

Use when you need to understand how slots are moved between nodes during resharding - both the traditional key-by-key approach (CLUSTER SETSLOT + MIGRATE) and the atomic slot migration introduced in Valkey 9.0.

Source files: `cluster_legacy.c` (SETSLOT, MIGRATE), `cluster_migrateslots.c` and `cluster_migrateslots.h` (atomic migration), `cluster.c` (redirect logic)

---

## Traditional Slot Migration (CLUSTER SETSLOT + MIGRATE)

The legacy approach moves keys one at a time between source and target nodes. This is the same mechanism used by Redis and all Valkey versions.

### Slot States

Two slot states are tracked in `clusterState`:

- **MIGRATING**: `migrating_slots_to` dict maps slot -> target clusterNode. The source node is transferring this slot's keys to the target.
- **IMPORTING**: `importing_slots_from` dict maps slot -> source clusterNode. The target node is receiving keys for this slot.

### Resharding Workflow

A resharding tool (typically `valkey-cli --cluster reshard`) orchestrates these steps:

```
1. Target:  CLUSTER SETSLOT <slot> IMPORTING <source-id>
2. Source:  CLUSTER SETSLOT <slot> MIGRATING <target-id>
3. Loop:
   a. Source:  CLUSTER GETKEYSINSLOT <slot> <count>
   b. Source:  MIGRATE <target-ip> <target-port> "" 0 5000 KEYS <key1> <key2> ...
4. Source:  CLUSTER SETSLOT <slot> NODE <target-id>
5. Target:  CLUSTER SETSLOT <slot> NODE <target-id>
6. Others:  CLUSTER SETSLOT <slot> NODE <target-id>
```

### CLUSTER SETSLOT Subcommands

Handled in `clusterCommandSetSlot()` and `clusterParseSetSlotCommand()`:

**MIGRATING** - Sets the slot's migration target. Only valid if this node currently owns the slot. Stored in `migrating_slots_to`.

**IMPORTING** - Sets the slot's import source. Only valid if this node does NOT own the slot. Stored in `importing_slots_from`.

**STABLE** - Clears both MIGRATING and IMPORTING state for the slot. Used to abort a migration.

**NODE** - Assigns slot ownership to a specific node. If the slot was in MIGRATING state and has no remaining keys, the MIGRATING state is cleared. This is the finalization step.

### Replication-Before-Execution

Since Valkey 8.0, CLUSTER SETSLOT is replicated to replicas BEFORE executing on the primary. This prevents topology state loss if the primary crashes between executing SETSLOT and broadcasting the change:

```c
if (nodeIsPrimary(myself) && myself->num_replicas != 0 && !c->flag.replication_done) {
    forceCommandPropagation(c, PROPAGATE_REPL);
    blockClientForReplicaAck(c, timeout_ms, server.primary_repl_offset + 1,
                             num_eligible_replicas, 0);
    c->flag.pending_command = 1;
    return;
}
```

The primary blocks the client, replicates the command, waits for ACKs from all eligible replicas (version > 7.2), and only then executes locally.

### Client Redirect Behavior During Migration

`getNodeByQuery()` in `cluster.c` implements the redirect rules:

```
Source node (slot in MIGRATING state):
  - Key exists locally    -> serve the request
  - Key missing, no other keys exist -> ASK redirect to target
  - Key missing, some keys exist     -> TRYAGAIN (mixed state)
  - MIGRATE command                  -> always serve locally

Target node (slot in IMPORTING state):
  - Client sent ASKING    -> serve locally
  - Client did not ASKING -> MOVED redirect to source (source still owns slot)
```

### MIGRATE Command

The MIGRATE command (`cluster.c:migrateCommand()`) performs atomic key transfer:

1. Serialize the key using RDB format (`createDumpPayload`)
2. Connect to the target node (connections are cached)
3. Send `RESTORE-ASKING <key> <ttl> <serialized-data> REPLACE`
4. The target receives the key and stores it
5. On success, the source deletes the local copy

The `REPLACE` flag is used so the target overwrites if the key already exists (idempotent retry).

### Limitations of Traditional Migration

- **Large keys**: A single MIGRATE of a large key blocks the event loop for the duration of the transfer. Multi-million element sets or sorted sets can cause noticeable latency.
- **Redirect storms**: During migration, every request for a missing key on the source triggers an ASK redirect. High-throughput workloads with many keys in the migrating slot experience cascading redirects.
- **Manual orchestration**: An external tool must drive the entire process, repeatedly calling GETKEYSINSLOT and MIGRATE.

---

## Atomic Slot Migration (Valkey 9.0+)

Valkey 9.0 introduces `CLUSTER MIGRATESLOTS` - a server-driven, atomic approach that transfers entire slots at once using fork-based snapshotting and streaming replication.

Source: `cluster_migrateslots.c`, `cluster_migrateslots.h`

### Core Concept

Instead of moving keys one at a time, the source node:
1. Forks a child process that snapshots all data in the target slots (RDB-format)
2. Streams the snapshot to the target over a dedicated connection
3. After the snapshot, continues streaming incremental changes (like replication)
4. Pauses writes, waits for the target to catch up, then atomically transfers ownership

### The slotMigrationJob Struct

```c
typedef struct slotMigrationJob {
    slotMigrationJobType type;              // EXPORT or IMPORT
    char target_node_name[CLUSTER_NAMELEN]; // Target node ID
    char source_node_name[CLUSTER_NAMELEN]; // Source node ID
    char name[CLUSTER_NAMELEN];             // Unique job ID
    client *client;                         // Connection to other node
    slotMigrationJobState state;            // Current state
    list *slot_ranges;                      // Ranges being migrated
    mstime_t mf_end;                        // Pause timeout
    // ...
} slotMigrationJob;
```

### Command Syntax

```
CLUSTER MIGRATESLOTS SLOTSRANGE <start> <end> [<start> <end> ...] NODE <target-id>
                    [SLOTSRANGE <start> <end> ... NODE <target-id> ...]
```

Multiple slot ranges to multiple targets can be specified in a single command. All ranges must currently be owned by the executing node.

### Source State Machine (Export)

```
SLOT_EXPORT_CONNECTING
    | Connected to target
SLOT_EXPORT_SEND_AUTH
    | AUTH command sent (if password configured)
SLOT_EXPORT_READ_AUTH_RESPONSE
    | Authenticated
SLOT_EXPORT_SEND_ESTABLISH
    | SYNCSLOTS ESTABLISH command sent
SLOT_EXPORT_READ_ESTABLISH_RESPONSE
    | Target acknowledged (+OK)
SLOT_EXPORT_WAITING_TO_SNAPSHOT
    | No active child process, no pending writes
SLOT_EXPORT_SNAPSHOTTING
    | Child process producing RDB snapshot of slot data
SLOT_EXPORT_STREAMING
    | Snapshot done, streaming incremental changes
SLOT_EXPORT_WAITING_TO_PAUSE
    | Target requested pause, draining output buffer
SLOT_EXPORT_FAILOVER_PAUSED
    | Writes paused, waiting for target to request ownership
SLOT_EXPORT_FAILOVER_GRANTED
    | Target granted ownership, waiting for topology update
    v
SLOT_MIGRATION_JOB_SUCCESS  or  SLOT_MIGRATION_JOB_FAILED
```

### Target State Machine (Import)

```
SLOT_IMPORT_WAIT_ACK
    | Source sent ACK
SLOT_IMPORT_RECEIVE_SNAPSHOT
    | Receiving RDB snapshot data
SLOT_IMPORT_WAITING_FOR_PAUSED
    | Received SNAPSHOT-EOF, waiting for PAUSED signal
SLOT_IMPORT_FAILOVER_REQUESTED
    | Requested failover (ownership transfer)
SLOT_IMPORT_FAILOVER_GRANTED
    | Failover granted, performing ownership takeover
    v
SLOT_MIGRATION_JOB_SUCCESS
    | (if demoted to replica during import)
SLOT_IMPORT_OCCURRING_ON_PRIMARY
    | Replica tracking an import happening on its primary
```

### How It Works - Step by Step

**1. Connection establishment**: Source connects to target, authenticates if needed, sends `CLUSTER SYNCSLOTS ESTABLISH` with the job name and slot ranges.

**2. Snapshot**: Source waits for no active child processes, then forks. The child process writes an RDB-format snapshot of all keys in the migrating slots to the target's socket. The parent continues serving reads (copy-on-write).

**3. Streaming**: After the child finishes, the source enters STREAMING state. All write commands affecting the migrating slots are replicated to the target in real time (similar to replication).

**4. Pause and cutover**: When the target requests a pause, the source drains its output buffer and pauses all client writes (`PAUSE_DURING_SLOT_MIGRATION`). This ensures no new writes occur during the final ownership transfer.

**5. Failover**: The target takes ownership of the slots by updating its slot assignments and bumping its configEpoch. The source detects the topology change and unpauses.

**6. Cleanup**: Both sides transition to SUCCESS or FAILED. On success, the source deletes any remaining keys in the transferred slots. On failure, the target cleans up imported data.

### Monitoring

```
CLUSTER GETSLOTMIGRATIONS    -- List all active/completed migration jobs
CLUSTER CANCELSLOTMIGRATIONS -- Cancel all in-progress exports
```

Each job reports its state as a human-readable string (e.g., "connecting", "snapshotting", "replicating", "paused").

### Failure Handling

The migration can fail at any point due to:
1. Connection loss between source and target
2. ACK timeout (no heartbeat from other side within `repl-timeout`)
3. Child process OOM during snapshot
4. Slot ownership change (another node claims the slot)
5. FLUSHDB during migration
6. Node demotion to replica
7. User cancellation via CANCELSLOTMIGRATIONS

On failure, the source cleans up the job and the operator must restart the migration. The target also detects the failure (via connection close or explicit SYNCSLOTS FINISH message) and cleans up imported data.

### Write-Loss Window

After the source grants the failover, there is a brief window where the source is paused but has not yet received the target's topology update. If the target crashes during this window, the source will eventually unpause (timeout) and accept writes that may conflict with the target's state. This is logged as a warning:

```
Write loss risk! During slot migration, new owner did not broadcast
ownership before we unpaused ourselves.
```

### Replica Awareness

Replicas track imports occurring on their primary via the `SLOT_IMPORT_OCCURRING_ON_PRIMARY` state. They learn about ongoing migrations through:
- `CLUSTER SYNCSLOTS ESTABLISH` replicated from the primary
- RDB aux field `cluster-slot-states` during full sync
- `CLUSTER SYNCSLOTS FINISH` messages for completion/failure

This ensures replicas can correctly handle failover during an in-progress migration.

---

## Comparison: Traditional vs Atomic

| Aspect | Traditional | Atomic (9.0+) |
|--------|-------------|----------------|
| Granularity | Key-by-key | Entire slot(s) at once |
| Orchestration | External tool required | Server-driven |
| Large keys | Blocks event loop per key | Fork-based, non-blocking |
| Redirect storms | Yes, per-key ASK | Minimal, bulk transfer |
| Write pause | None (gradual) | Brief pause at cutover |
| Failure recovery | Manual cleanup | Automatic cleanup |
| Command | SETSLOT + MIGRATE loop | CLUSTER MIGRATESLOTS |
| Multi-database | Not supported | Supported (all DBs migrated) |

---

## Key Functions Reference

| Function | File | Purpose |
|----------|------|---------|
| `clusterCommandSetSlot()` | cluster_legacy.c | Handle CLUSTER SETSLOT subcommands |
| `clusterParseSetSlotCommand()` | cluster_legacy.c | Validate and parse SETSLOT arguments |
| `migrateCommand()` | cluster.c | MIGRATE key-by-key transfer |
| `getNodeByQuery()` | cluster.c | Determine MOVED/ASK/TRYAGAIN redirects |
| `clusterCommandMigrateSlots()` | cluster_migrateslots.c | Handle CLUSTER MIGRATESLOTS |
| `proceedWithSlotMigration()` | cluster_migrateslots.c | Drive the atomic migration state machine |
| `clusterSlotMigrationCron()` | cluster_migrateslots.c | Periodic migration job maintenance |
| `clusterCommandSyncSlots()` | cluster_migrateslots.c | Handle CLUSTER SYNCSLOTS subcommands |
| `clusterCommandCancelSlotMigrations()` | cluster_migrateslots.c | Cancel in-progress exports |
| `backgroundSlotMigrationDoneHandler()` | cluster_migrateslots.c | Handle child process completion |
| `performSlotImportJobFailover()` | cluster_migrateslots.c | Target takes slot ownership |
| `finishSlotMigrationJob()` | cluster_migrateslots.c | Transition job to terminal state |

---

## See Also

- [Replication Overview](../replication/overview.md) - Atomic slot migration uses a replication-like streaming phase after the initial snapshot, and replicas track in-progress imports to handle failover during migration
- [RDB Snapshot Persistence](../persistence/rdb.md) - Both traditional MIGRATE (via `createDumpPayload`) and atomic migration (via fork-based snapshot) use RDB-format serialization to transfer key data between nodes
- [Cluster Failover](failover.md) - Failover during an in-progress migration requires replica awareness of the migration state; the atomic migration pause/cutover protocol resembles the manual failover pause mechanism
- [Cluster Overview](overview.md) - MOVED/ASK/TRYAGAIN redirect logic in `getNodeByQuery()` governs client behavior during migration
- [kvstore](../valkey-specific/kvstore.md) - `kvstoreSetIsImporting()` marks slots being imported, excluding them from Fenwick tree counts. `CLUSTER GETKEYSINSLOT` uses `kvstoreScan` restricted to a single hashtable index to enumerate keys in a slot.
