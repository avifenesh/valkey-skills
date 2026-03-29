# Blocking Operations

Use when working on BLPOP, BRPOP, BLMOVE, BZPOPMIN, XREAD, WAIT, module blocking, or the key-readiness notification system.

Source: `src/blocked.c`

---

## Data Structures

### blockingState - Per-Client Blocking State

```c
typedef struct blockingState {
    blocking_type btype;      // BLOCKED_LIST, BLOCKED_ZSET, BLOCKED_STREAM, etc.
    mstime_t timeout;         // Absolute UNIX time in ms; 0 = no timeout
    int unblock_on_nokey;     // Unblock when key is deleted (e.g. XREADGROUP)
    union {
        listNode *client_waiting_acks_list_node;  // BLOCKED_WAIT
        listNode *postponed_list_node;            // BLOCKED_POSTPONE
        listNode *generic_blocked_list_node;      // General-purpose
    };
    dict *keys;               // Keys we are blocked on (BLOCKED_LIST/ZSET/STREAM)
    int numreplicas;          // BLOCKED_WAIT: replicas to wait for
    int numlocal;             // BLOCKED_WAIT: whether waiting for local AOF fsync
    long long reploffset;     // BLOCKED_WAIT: replication offset target
    void *module_blocked_handle;   // BLOCKED_MODULE: opaque handle
    void *async_rm_call_handle;    // BLOCKED_MODULE: async RM_Call handle
} blockingState;
```

Lazily allocated via `initClientBlockingState()`. The union saves memory since a client can only be in one blocking state at a time.

### blocking_type Enum

```c
typedef enum blocking_type {
    BLOCKED_NONE,      // Not blocked
    BLOCKED_LIST,      // BLPOP, BRPOP, BLMOVE
    BLOCKED_WAIT,      // WAIT, WAITAOF
    BLOCKED_MODULE,    // Module-initiated blocking
    BLOCKED_STREAM,    // XREAD, XREADGROUP
    BLOCKED_ZSET,      // BZPOPMIN, BZPOPMAX, BZMPOP
    BLOCKED_POSTPONE,  // Deferred by processCommand (e.g. CLIENT PAUSE)
    BLOCKED_SHUTDOWN,  // SHUTDOWN
    BLOCKED_NUM,
    BLOCKED_END
} blocking_type;
```

### readyList - Key Readiness Signal

```c
typedef struct readyList {
    serverDb *db;
    robj *key;
} readyList;
```

Accumulated in `server.ready_keys` when data arrives on a key that has blocked clients.

## Entering Blocked State

### blockClient(client *c, int btype)

Core function that sets a client as blocked:

1. Assert replicated clients are only blocked for MODULE or POSTPONE.
2. Initialize blocking state if needed.
3. Set `c->flag.blocked = 1` and `c->bstate->btype`.
4. Increment `server.blocked_clients` and `server.blocked_clients_by_type[btype]`.
5. Add client to the timeout table for expiry tracking.

Once blocked, the client's query buffer accumulates data but commands are not processed.

### blockForKeys(client *c, int btype, robj **keys, int numkeys, mstime_t timeout, int unblock_on_nokey)

Used by BLPOP, BRPOP, BLMOVE, BZPOPMIN, BZPOPMAX, XREAD, XREADGROUP, and module blocking.

1. Set the timeout (skipped if client is re-executing after unblock).
2. For each key:
   - Add to `c->bstate->keys` dict.
   - Add client to `db->blocking_keys[key]` list (create list if first blocker).
   - If `unblock_on_nokey`, also register in `db->blocking_keys_unblock_on_nokey`.
3. Set `c->flag.pending_command = 1` (except for modules) - the command will be re-executed when unblocked.
4. Call `blockClient()`.

The `unblock_on_nokey` flag is used by XREADGROUP - the client must be unblocked even if the key (stream) is deleted, since the consumer group becomes invalid.

### blockClientForReplicaAck(client *c, mstime_t timeout, long long offset, long numreplicas, int numlocal)

Used by WAIT and WAITAOF. Records the replication offset target and replica count, adds client to `server.clients_waiting_acks`, then calls `blockClient(c, BLOCKED_WAIT)`.

### blockPostponeClient(client *c)

Used by CLIENT PAUSE and similar. Adds to `server.postponed_clients` and sets `pending_command = 1` for later re-execution.

### blockClientShutdown(client *c)

Used by SHUTDOWN to block until shutdown completes or is canceled.

## Key Readiness Detection

### signalKeyAsReady(serverDb *db, robj *key, int type) / signalDeletedKeyAsReady(...)

Called by command implementations (LPUSH, ZADD, XADD, etc.) when data is added to a key.

Internal logic (`signalKeyAsReadyLogic`):

1. Map the object type to blocking type. If the type never blocks, return.
2. Quick check: if no clients are blocked on this type (and no blocked modules), return.
3. For deletions: only proceed if the key is in `db->blocking_keys_unblock_on_nokey`.
4. For additions: only proceed if the key is in `db->blocking_keys`.
5. Add to `db->ready_keys` dict (O(1) dedup) and append a `readyList` entry to `server.ready_keys`.

## Processing Ready Keys

### handleClientsBlockedOnKeys(void)

Called from `blockedBeforeSleep()` in the event loop. Uses a static re-entrancy guard.

1. Swap `server.ready_keys` with a fresh list (so new signals during processing go to the new list).
2. For each readyList entry:
   - Remove from `db->ready_keys`.
   - Call `handleClientsBlockedOnKey(rl)`.
   - Free the readyList.
3. Repeat while `server.ready_keys` has entries (cascading unblocks from BLMOVE, etc.).

### handleClientsBlockedOnKey(readyList *rl) (static)

For each blocked client on this key (FIFO order, capped to initial count to avoid infinite loops):

1. Look up the key. Check if the value type matches the blocked type.
2. Module-blocked clients are served regardless of type.
3. `unblock_on_nokey` clients are served even if key is NULL or type changed.
4. Call `unblockClientOnKey()` or `moduleUnblockClientOnKey()`.

## Unblocking

### unblockClient(client *c, int queue_for_reprocessing)

Dispatches cleanup by blocking type:

| btype | Cleanup |
|-------|---------|
| BLOCKED_LIST/ZSET/STREAM | `unblockClientWaitingData` - remove from all per-key lists |
| BLOCKED_WAIT | `unblockClientWaitingReplicas` |
| BLOCKED_MODULE | `unblockClientWaitingData` (if key-blocked) + `unblockClientFromModule` |
| BLOCKED_POSTPONE | Remove from `server.postponed_clients` |
| BLOCKED_SHUTDOWN | No cleanup needed |

Then:
1. Reset client if no pending command and not shutdown-blocked.
2. Decrement `server.blocked_clients` and type-specific counter.
3. Clear `c->flag.blocked`, reset btype to `BLOCKED_NONE`.
4. Remove from timeout table.
5. If `queue_for_reprocessing`, add to `server.unblocked_clients`.

### unblockClientOnKey(client *c, robj *key) (static)

The key-specific unblock path:

1. Remove client from the per-key blocking list via `releaseBlockedEntry()`.
2. Call `unblockClient(c, 0)` - don't queue yet.
3. If `c->flag.pending_command` is set:
   - Clear it, set `reexecuting_command`.
   - Enter execution unit, call `processCommandAndResetClient()` to re-run the command.
   - If still not blocked, queue for reprocessing or call module unblock handler.
   - Exit execution unit, clear `reexecuting_command`.

This re-execution is the key mechanism: the original BLPOP command runs again, and this time the key has data so it succeeds as a normal LPOP.

### unblockClientOnTimeout(client *c)

1. Call `replyToBlockedClientTimedOut()` to send the timeout response.
2. Clear pending_command flag.
3. Call `unblockClient(c, 1)`.

Timeout responses by type:
- LIST/ZSET/STREAM: null array
- WAIT (waitCommand): count of replicas that acknowledged
- WAIT (waitaofCommand): array of [local_fsync_ok, replica_ack_count]
- MODULE: delegate to module timeout callback

### unblockClientOnError(client *c, const char *err_str)

Used for forced unblocking (primary->replica transition, cluster redirect). Sends error reply, updates stats as rejected, then unblocks.

## Cleanup Helpers

### releaseBlockedEntry(client *c, dictEntry *de, int remove_key) (static)

Removes a client from a per-key blocking list. Handles reference counting on `db->blocking_keys_unblock_on_nokey` - if the count drops to zero, the entry is deleted to prevent stale entries from triggering spurious unblocks.

### processUnblockedClients(void)

Called from `beforeSleep()`. Processes the `server.unblocked_clients` list:

1. For module clients: call `moduleCallCommandUnblockedHandler()`.
2. For regular clients: call `processPendingCommandAndInputBuffer()` to handle any accumulated query buffer.

## Mass Unblock

### disconnectOrRedirectAllBlockedClients(void)

Called during primary->replica transition. For each blocked client:

- POSTPONE clients are skipped (they will be reprocessed from scratch).
- In cluster mode: attempt `clusterRedirectBlockedClientIfNeeded()`, then unblock with error.
- In standalone with redirect capability: send `-REDIRECT host:port`.
- Read-only clients blocked on read commands: left alone.
- Otherwise: send `-UNBLOCKED` error and set `close_after_reply`.

### replyToClientsBlockedOnShutdown(void)

If shutdown is canceled, sends error to all SHUTDOWN-blocked clients and unblocks them.

## Event Loop Integration

### blockedBeforeSleep(void)

Called every event loop iteration from `beforeSleep()`. Orchestrates all blocking-related processing in order:

1. `handleBlockedClientsTimeout()` - check timeouts
2. `processClientsWaitingReplicas()` - check WAIT/WAITAOF conditions
3. `handleClientsBlockedOnKeys()` - serve clients whose keys became ready
4. `moduleHandleBlockedClients()` - handle module-unblocked clients
5. `processUnblockedClients()` - drain the unblocked queue

This ordering matters - handling keys may produce new unblocked clients that `processUnblockedClients` then serves.

## See Also

- [MULTI/EXEC Transactions](../transactions/multi-exec.md) - Blocking commands cannot be used inside MULTI/EXEC transactions; the `deny_blocking` flag is set during EXEC.
- [Custom Types and Advanced Commands](../modules/types-and-commands.md) - Modules implement blocking commands via `ValkeyModule_BlockClient` and `ValkeyModule_BlockClientOnKeys`. Module-blocked clients use the `BLOCKED_MODULE` type and follow the same key-readiness notification system.
- [Pub/Sub Subsystem](../pubsub/pubsub.md) - Pub/Sub subscriptions put clients into a restricted state (not blocked in the `blockingState` sense) where only subscribe/unsubscribe commands are accepted.
- [Latency Monitoring](../monitoring/latency.md) - the `command-unblocking` latency event measures the time to unblock clients; prolonged blocking can indicate performance issues tracked by the latency framework.
