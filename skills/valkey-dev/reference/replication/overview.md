# Replication Overview

Use when you need to understand how Valkey replicates data from a primary to replicas, the PSYNC protocol, the replication backlog, dual replication IDs, or the write propagation pipeline.

Source file: `src/replication.c`

---

## PSYNC Protocol

PSYNC (partial synchronization) allows a replica to resume replication from where it left off, avoiding a full dataset transfer when possible.

### Full Resync vs Partial Resync

| Scenario | Outcome |
|----------|---------|
| Replica connects for the first time | Full resync |
| Replica reconnects, data still in backlog | Partial resync |
| Replica reconnects, data no longer in backlog | Full resync |
| Replication ID mismatch | Full resync |
| Replica sends `PSYNC ? -1` | Forced full resync |

### PSYNC Command Format

```
PSYNC <replication-id> <offset>
```

The replica sends its last known replication ID and offset. The primary responds with one of:

| Response | Meaning |
|----------|---------|
| `+FULLRESYNC <replid> <offset>` | Full resync needed; RDB transfer follows |
| `+CONTINUE [<new-replid>]` | Partial resync accepted; backlog data follows |
| `+DUALCHANNELSYNC` | Dual-channel full sync (8.0+) |
| `-NOMASTERLINK` | Primary is itself a disconnected replica |
| `-LOADING` | Primary is still loading data |

### primaryTryPartialResynchronization

```c
int primaryTryPartialResynchronization(client *c, long long psync_offset);
```

The primary-side decision function. Returns `C_OK` for partial resync, `C_ERR` for full resync needed.

Decision logic:
1. Compare replica's replication ID against `server.replid` (primary ID) and `server.replid2` (secondary ID, valid up to `server.second_replid_offset`)
2. Check if the requested offset falls within the backlog range: `[server.repl_backlog->offset, server.repl_backlog->offset + server.repl_backlog->histlen]`
3. If both checks pass, send `+CONTINUE` and replay the backlog from the requested offset

---

## Replication Backlog

The replication backlog stores recent write commands so that temporarily disconnected replicas can resync without a full RDB transfer.

### Data Structure

```c
typedef struct replBacklog {
    listNode *ref_repl_buf_node;  // Reference to first buffer block
    size_t unindexed_count;       // Count since last index entry
    rax *blocks_index;            // Radix tree for fast offset lookup
    long long histlen;            // Total bytes of data in backlog
    long long offset;             // Replication offset of first byte
} replBacklog;
```

The backlog is not a simple circular buffer. It is a linked list of `replBufBlock` nodes (shared with connected replicas via reference counting):

```c
typedef struct replBufBlock {
    int refcount;           // Number of replicas + backlog referencing this
    long long id;           // Unique incremental number
    long long repl_offset;  // Start replication offset of this block
    size_t size, used;
    char buf[];
} replBufBlock;
```

### Backlog Index

For fast partial resync lookups, a radix tree (`rax`) indexes every Nth block (controlled by `REPL_BACKLOG_INDEX_PER_BLOCKS`). This allows binary-search-like lookup of the block containing a given replication offset:

```c
void createReplicationBacklogIndex(listNode *ln);
// Inserts an index entry every REPL_BACKLOG_INDEX_PER_BLOCKS blocks
```

When a replica requests offset X, `addReplyReplicationBacklog()` uses the radix tree to find the nearest block, then walks forward to locate the exact byte position.

### Lifecycle

- Created by `createReplicationBacklog()` when the first replica connects (or on startup if the server was previously a replica)
- Sized by `repl-backlog-size` (default 10 MB)
- Freed by `freeReplicationBacklog()` when the last replica disconnects and `repl-backlog-ttl` expires (default 3600 seconds)
- Old blocks are trimmed by `incrementalTrimReplicationBacklog()` called from `beforeSleep` on each event loop iteration

---

## Dual Replication IDs

Valkey maintains two replication IDs to enable partial resync across failovers.

```c
// In server state:
char replid[CONFIG_RUN_ID_SIZE+1];     // Primary replication ID
char replid2[CONFIG_RUN_ID_SIZE+1];    // Secondary replication ID
long long second_replid_offset;         // Valid up to this offset
```

### Why Two IDs

When a replica is promoted to primary (failover), it needs to:
1. Accept PSYNC from other replicas that were replicating from the old primary
2. Start its own new replication history

`shiftReplicationId()` handles this:

```c
void shiftReplicationId(void) {
    memcpy(server.replid2, server.replid, sizeof(server.replid));
    server.second_replid_offset = server.primary_repl_offset + 1;
    changeReplicationId();
}
```

After this call:
- `replid` = new random ID for the new primary's replication stream
- `replid2` = the old primary's replication ID
- `second_replid_offset` = the offset up to which `replid2` is valid

When a replica connects with `PSYNC <old-replid> <offset>`, the primary checks both IDs and can accept a partial resync if `offset <= second_replid_offset`.

### When IDs Change

| Event | replid | replid2 |
|-------|--------|---------|
| Server starts fresh | Random | Cleared (all zeros) |
| Full resync from primary | Inherited from primary | Cleared |
| Promoted to primary | New random | Previous replid |
| `REPLICAOF NO ONE` | New random | Previous replid |

---

## Replica Handshake Sequence

The replica-side state machine in `syncWithPrimary()` (connection handler):

```
REPL_STATE_CONNECTING          -> Send PING
REPL_STATE_RECEIVE_PING_REPLY  -> Expect +PONG
REPL_STATE_SEND_HANDSHAKE      -> Send AUTH, REPLCONF (port, ip, capa, version, nodeid)
REPL_STATE_RECEIVE_AUTH_REPLY  -> Expect +OK
REPL_STATE_RECEIVE_PORT_REPLY  -> Expect +OK
REPL_STATE_RECEIVE_IP_REPLY    -> Expect +OK
REPL_STATE_RECEIVE_CAPA_REPLY  -> Expect +OK
REPL_STATE_RECEIVE_VERSION_REPLY -> Expect +OK
REPL_STATE_RECEIVE_NODEID_REPLY -> Expect +OK
REPL_STATE_SEND_PSYNC          -> Send PSYNC <replid> <offset>
REPL_STATE_RECEIVE_PSYNC_REPLY -> Handle response
REPL_STATE_TRANSFER            -> Receiving RDB data
REPL_STATE_CONNECTED           -> Steady-state replication
```

The handshake uses pipelining - multiple REPLCONF commands are sent as a batch and replies are read in sequence.

### syncCommand (Primary Side)

```c
void syncCommand(client *c);
```

Handles both `SYNC` (legacy) and `PSYNC` from replicas. The primary-side flow:

1. Try partial resync via `primaryTryPartialResynchronization()`
2. If partial resync fails and replica supports dual-channel: respond `+DUALCHANNELSYNC`
3. Otherwise, initiate full resync:
   - Set replica state to `REPLICA_STATE_WAIT_BGSAVE_START`
   - Add to `server.replicas` list
   - Create replication backlog if this is the first replica
   - Start BGSAVE for replication (disk or socket target)

### Full Resync Cases

When a SYNC/PSYNC arrives requiring full resync, there are three cases:

| Case | Condition | Action |
|------|-----------|--------|
| 1 | BGSAVE in progress (disk target) | Attach to existing BGSAVE if compatible |
| 2 | BGSAVE in progress (socket target) | Wait for next BGSAVE |
| 3 | No BGSAVE in progress | Start new BGSAVE |

---

## Write Propagation

### propagateNow

```c
// server.c
static void propagateNow(int dbid, robj **argv, int argc, int target, int slot);
```

This is the central propagation point, called after every write command executes. It fans out to both persistence and replication:

```c
if (propagate_to_aof) feedAppendOnlyFile(dbid, argv, argc);
if (propagate_to_repl) replicationFeedReplicas(dbid, argv, argc);
```

Both AOF and replication receive the exact same command sequence in the same RESP format.

### replicationFeedReplicas

```c
void replicationFeedReplicas(int dictid, robj **argv, int argc);
```

1. If this instance is itself a replica (`server.primary_host != NULL`), return immediately - replicas proxy the primary's stream verbatim via `replicationFeedStreamFromPrimaryStream()` instead
2. If no backlog and no replicas, increment `server.primary_repl_offset` and return
3. Install write handlers on all replica connections (`prepareReplicasToWrite()`)
4. If the target DB changed, inject a `SELECT` command
5. Encode the command as RESP and write to the shared replication buffer via `feedReplicationBuffer()`

The replication buffer is shared between the backlog and all connected replicas. Each `replBufBlock` uses reference counting - data is freed only when the backlog trims it and no replica references it.

### Sub-Replica Proxying

When this server is itself a replica, it does not re-serialize commands. Instead, `replicationFeedStreamFromPrimaryStream()` takes the raw bytes received from the primary and feeds them directly to the replication buffer:

```c
void replicationFeedStreamFromPrimaryStream(char *buf, size_t buflen);
```

This preserves the exact same replication stream, allowing sub-replicas to use the primary's replication ID for PSYNC.

---

## Key Server State Fields

| Field | Type | Description |
|-------|------|-------------|
| `server.primary_repl_offset` | `long long` | Current replication offset (monotonically increasing byte count) |
| `server.replid` | `char[41]` | Primary replication ID |
| `server.replid2` | `char[41]` | Secondary replication ID |
| `server.second_replid_offset` | `long long` | Max offset for secondary ID |
| `server.repl_backlog` | `replBacklog *` | Replication backlog |
| `server.repl_backlog_size` | `long long` | Configured backlog size limit |
| `server.replicas` | `list *` | Connected replica clients |
| `server.repl_buffer_blocks` | `list *` | Shared replication buffer (list of replBufBlock) |
| `server.primary_host` | `sds` | Primary's hostname (NULL if this is a primary) |
| `server.repl_state` | `int` | Replica-side replication state machine |

---

## See Also

- [RDB Snapshot Persistence](../persistence/rdb.md) - RDB format and `rdbSaveRio()` used during full resync to generate the dataset snapshot sent to replicas
- [Dual-Channel Replication](dual-channel.md) - Valkey 8.0+ optimization that separates the RDB transfer from the replication stream during full resync, reducing primary memory overhead
- [AOF Persistence](../persistence/aof.md) - AOF and replication share the same write propagation path via `propagateNow()`, receiving identical RESP command sequences
- [Cluster Failover](../cluster/failover.md) - Dual replication IDs (`replid`/`replid2`) enable partial resync after cluster failover without requiring a full RDB transfer
- [Sentinel Mode](../sentinel/sentinel-mode.md) - Sentinel monitors replication topology and triggers failover when a primary becomes unreachable
- [Networking Layer](../architecture/networking.md) - Replicas connect as regular clients via the `connection *` abstraction. The replica handshake (PING, AUTH, REPLCONF, PSYNC) uses the same `readQueryFromClient`/`addReply` I/O path. Replica output is flushed via `handleClientsWithPendingWrites` in `beforeSleep`.
- [Command Dispatch](../architecture/command-dispatch.md) - Write propagation originates from `call()` in the command dispatch path, which calls `propagateNow()` when `server.dirty` increases
