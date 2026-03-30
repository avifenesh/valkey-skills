# Dual-Channel Replication

Use when you need to understand how Valkey 8.0+ separates the RDB transfer from the replication stream during full resync, reducing memory overhead and enabling faster resynchronization.

Source file: `src/replication.c` (search for `dualChannel`)

---

## Problem: Classic Full Resync

In traditional single-channel full resync:

1. Primary forks and generates RDB
2. While RDB is being sent, the primary buffers all new write commands in the replica's output buffer
3. After RDB transfer completes, the buffered commands are sent
4. The replica discards its entire dataset, loads the RDB, then processes the backlog

The problem: during a large RDB transfer, the primary accumulates a potentially enormous output buffer for each syncing replica. If the transfer takes minutes, this can consume gigabytes of memory and risk OOM.

---

## Solution: Two Separate Connections

Dual-channel replication uses two TCP connections:

| Channel | Purpose | Data Direction |
|---------|---------|----------------|
| **Main channel** | Incremental replication stream (PSYNC) | Primary -> Replica |
| **RDB channel** | RDB snapshot transfer | Primary -> Replica |

The key insight: instead of buffering commands on the primary, the replica buffers them locally while loading the RDB. This shifts memory pressure from the primary to the replica.

---

## Protocol Flow

### Negotiation

1. Replica connects via the main channel and performs the standard handshake
2. Replica sends `PSYNC <replid> <offset>` on the main channel
3. Primary determines that a full resync is needed
4. If the replica advertised `REPLICA_CAPA_DUAL_CHANNEL`, primary responds with `+DUALCHANNELSYNC\r\n` instead of starting an RDB transfer

```c
// In syncCommand(), when partial resync fails:
if (c->repl_data->replica_capa & REPLICA_CAPA_DUAL_CHANNEL) {
    const char *buf = "+DUALCHANNELSYNC\r\n";
    connWrite(c->conn, buf, strlen(buf));
    return;
}
```

### RDB Channel Setup

5. Replica opens a second connection (the RDB channel) to the primary
6. Replica sends `REPLCONF set-rdb-client-id <rdb-channel-client-id>` on the **main channel** (links the two connections)
7. RDB channel performs its own handshake:
   - AUTH if needed
   - REPLCONF ip-address
8. Primary sends `$ENDOFF <repl-offset>` - the replication offset at which the RDB snapshot ends
9. Primary attaches the replica's main channel to the replication backlog starting from that offset
10. Primary forks and sends the RDB via the RDB channel

### Parallel Transfer

11. **RDB channel**: Primary's child process sends RDB data directly to the replica
12. **Main channel**: Primary's main thread sends incremental replication data (commands that arrive after the snapshot point)
13. **Replica**: Loads the RDB from the RDB channel while buffering incremental data from the main channel into `server.pending_repl_data`

### Completion

14. Replica finishes loading the RDB
15. Replica closes the RDB channel
16. Replica sends `PSYNC <replid> <snapshot-end-offset>` on the main channel
17. Primary responds with `+CONTINUE` (partial resync from the snapshot end point)
18. Replica streams the locally buffered replication data into memory via `streamReplDataBufToDb()`
19. Normal steady-state replication continues on the main channel

---

## Replica-Side State Machine (RDB Channel)

```c
// States for the RDB channel:
REPL_DUAL_CHANNEL_SEND_HANDSHAKE        // Send AUTH, REPLCONF ip-address on RDB channel
REPL_DUAL_CHANNEL_RECEIVE_AUTH_REPLY     // Wait for AUTH response
REPL_DUAL_CHANNEL_RECEIVE_REPLCONF_REPLY // Wait for REPLCONF response
REPL_DUAL_CHANNEL_RECEIVE_ENDOFF        // Wait for $ENDOFF <offset>
REPL_DUAL_CHANNEL_RDB_LOAD              // Loading RDB from this channel
REPL_DUAL_CHANNEL_RDB_LOADED            // RDB loaded, draining local buffer
```

The handler `dualChannelFullSyncWithPrimary()` implements this state machine:

```c
static void dualChannelFullSyncWithPrimary(connection *conn) {
    switch (server.repl_rdb_channel_state) {
    case REPL_DUAL_CHANNEL_SEND_HANDSHAKE:
        ret = dualChannelReplHandleHandshake(conn, &err);
        break;
    case REPL_DUAL_CHANNEL_RECEIVE_AUTH_REPLY:
        ret = dualChannelReplHandleAuthReply(conn, &err);
        break;
    case REPL_DUAL_CHANNEL_RECEIVE_REPLCONF_REPLY:
        ret = dualChannelReplHandleReplconfReply(conn, &err);
        break;
    case REPL_DUAL_CHANNEL_RECEIVE_ENDOFF:
        ret = dualChannelReplHandleEndOffsetResponse(conn, &err);
        break;
    }
}
```

---

## Local Replication Buffer

While the RDB loads, the replica buffers incoming replication data from the main channel.

### Data Structure

```c
typedef struct replDataBufBlock {
    size_t size, used;
    char buf[];
} replDataBufBlock;
```

Stored in `server.pending_repl_data` as a linked list of blocks:

```c
void replDataBufInit(void);            // Initialize the buffer infrastructure
void bufferReplData(connection *conn); // Read handler that buffers incoming data
```

### Memory Limits

The buffer respects the replica output buffer limit (`client-output-buffer-limit replica`):

```c
if (server.client_obuf_limits[CLIENT_TYPE_REPLICA].hard_limit_bytes &&
    server.pending_repl_data.len > hard_limit_bytes) {
    // Stop accumulating; further data stays on primary side
    connSetReadHandler(conn, NULL);
}
```

When the limit is hit, the replica stops reading from the main channel. The primary's output buffer for this replica will grow instead, but this is bounded by the same output buffer limits that would apply in the single-channel case.

### Draining the Buffer

After RDB loading completes, `dualChannelSyncSuccess()` streams the buffered data:

```c
void dualChannelSyncSuccess(void) {
    server.primary_initial_offset = server.repl_provisional_primary.reploff;
    replicationResurrectProvisionalPrimary();
    streamReplDataBufToDb(server.primary);
    freePendingReplDataBuf();
    replicationSteadyStateInit();
    replicationSendAck();
}
```

`streamReplDataBufToDb()` walks the linked list, appending each block to the primary client's query buffer and calling `processInputBuffer()` to execute the commands:

```c
int streamReplDataBufToDb(client *c) {
    while ((cur = listFirst(server.pending_repl_data.blocks))) {
        replDataBufBlock *o = listNodeValue(cur);
        c->querybuf = sdscatlen(c->querybuf, o->buf, o->used);
        c->repl_data->read_reploff += o->used;
        processInputBuffer(c);
        listDelNode(server.pending_repl_data.blocks, cur);
    }
}
```

---

## Primary-Side Handling

### Attaching to Backlog Early

When the primary decides to use dual-channel sync, it attaches the replica's main channel to the replication backlog before the fork:

```c
// Primary sends $ENDOFF with the current replication offset
// Then attaches the replica to start receiving backlog from that point
```

This means the replica starts receiving incremental updates immediately, even before the RDB is fully generated. The end-offset tells the replica where the RDB snapshot ends so it knows which PSYNC offset to request after loading.

### PSYNC After RDB Load

On the main channel, the replica sends another PSYNC using the snapshot end offset. The primary handles this in `dualChannelReplMainConnRecvPsyncReply()`:

```c
int dualChannelReplMainConnRecvPsyncReply(connection *conn, sds *err) {
    if (psync_result == PSYNC_CONTINUE) {
        dualChannelSyncHandlePsync();  // Success - complete the sync
    }
}
```

---

## Benefits

1. **Reduced primary memory**: The primary does not need to buffer all commands during RDB transfer. The backlog stores data once (shared), rather than per-replica output buffers.

2. **Faster resync**: Incremental data arrives at the replica during RDB transfer, not after. The total resync time is reduced because the replica does not need to wait for a large backlog replay after the RDB load.

3. **Better utilization**: Both channels transfer data in parallel, making better use of available bandwidth.

---

## Configuration and Backwards Compatibility

| Parameter | Default | Description |
|-----------|---------|-------------|
| `dual-channel-replication-enabled` | no | Enable dual-channel on the replica side |
| `repl-backlog-size` | 10mb | Affects local buffer block sizing (max block = backlog/16) |

### Capability Negotiation

- The replica advertises `REPLICA_CAPA_DUAL_CHANNEL` via `REPLCONF capa dual-channel` during the handshake
- If the primary does not support it, it ignores the capability and proceeds with standard full resync
- If the primary supports it but a partial resync is possible, it still uses partial resync (dual-channel is only for full resync)
- The replica falls back to single-channel sync if the RDB channel connection fails

### PSYNC Result Codes

```c
#define PSYNC_WRITE_ERROR 0
#define PSYNC_WAIT_REPLY 1
#define PSYNC_CONTINUE 2
#define PSYNC_FULLRESYNC 3
#define PSYNC_NOT_SUPPORTED 4
#define PSYNC_TRY_LATER 5
#define PSYNC_FULLRESYNC_DUAL_CHANNEL 6
```

`PSYNC_FULLRESYNC_DUAL_CHANNEL` (6) is the new result code that triggers dual-channel setup on the replica side.

---

## See Also

- [RDB Snapshot Persistence](../persistence/rdb.md) - The RDB format and `rdbSaveRio()` function used for the snapshot transferred over the RDB channel
- [Replication Overview](overview.md) - PSYNC protocol, replication backlog, and the single-channel full resync that dual-channel replaces
- [AOF Persistence](../persistence/aof.md) - After the RDB load completes, the replica may enter `AOF_WAIT_REWRITE` state to enable AOF persistence
- [Networking Layer](../architecture/networking.md) - Both the main channel and RDB channel use the `connection *` abstraction; `processInputBuffer()` is called during `streamReplDataBufToDb()` to replay buffered commands
