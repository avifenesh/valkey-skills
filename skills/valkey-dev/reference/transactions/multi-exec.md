# MULTI/EXEC Transactions

Use when working on command queuing, optimistic locking, or transaction execution in Valkey.

Source: `src/multi.c`

## Contents

- Data Structures (line 21)
- Lazy Initialization (line 66)
- MULTI Command (line 70)
- Command Queuing (line 78)
- DISCARD Command (line 91)
- EXEC Command (line 99)
- WATCH Mechanism (line 138)
- Memory Overhead Tracking (line 178)
- See Also (line 186)

---

## Data Structures

### multiCmd - Single Queued Command

```c
typedef struct multiCmd {
    robj **argv;
    int argv_len;
    int argc;
    struct serverCommand *cmd;
    int slot;             // cluster slot for this command
} multiCmd;
```

### multiState - Transaction State

```c
typedef struct multiState {
    multiCmd *commands;      // Array of MULTI commands
    int count;               // Total number of MULTI commands
    int cmd_flags;           // Accumulated command flags OR-ed together
    int cmd_inv_flags;       // Inverted flags (~flags) OR-ed together
    size_t argv_len_sums;    // Memory used by all command arguments
    int alloc_count;         // Reserved multiCmd array capacity
    list watched_keys;       // List of watchedKey structs
    int transaction_db_id;   // Currently SELECTed DB in transaction context
} multiState;
```

The `cmd_flags` / `cmd_inv_flags` pair allows checking both "any command has flag X" and "all commands have flag X" without iterating.

### watchedKey - WATCH Tracking

```c
typedef struct watchedKey {
    listNode node;       // Embedded node for the per-key client list
    robj *key;
    serverDb *db;
    client *client;
    unsigned expired : 1; // Flag: key was already expired when WATCH was called
} watchedKey;
```

The `node` field is embedded directly in the struct - its `value` pointer points back to the containing list. This avoids a separate allocation and enables O(1) removal from the per-key client list without `listSearchKey`.

## Lazy Initialization

`multiState` is allocated lazily via `initClientMultiState()`. It is only created when MULTI or WATCH is first called. The `c->mstate` pointer is NULL for clients that have never used transactions.

## MULTI Command

```c
void multiCommand(client *c);
```

Sets `c->flag.multi = 1` and initializes transaction state. After this, all commands except EXEC, DISCARD, WATCH, and a few others are queued instead of executed.

## Command Queuing

### queueMultiCommand(client *c, uint64_t cmd_flags)

Called by the command dispatcher when `c->flag.multi` is set.

1. If `dirty_cas` or `dirty_exec` is already set, return immediately - no point wasting memory on a transaction that will abort.
2. Grow the commands array if needed (starts at 2, doubles up to INT_MAX).
3. Copy `c->cmd`, `c->argc`, `c->argv`, and `c->slot` into a new `multiCmd`.
4. If the queued command is SELECT, track the new DB id in `transaction_db_id`.
5. Transfer ownership of argv from the client to the multiCmd (`c->argv = NULL`).
6. Accumulate `cmd_flags` and `~cmd_flags` into the aggregate flag fields.

## DISCARD Command

```c
void discardTransaction(client *c);
```

Resets transaction state: frees all queued commands, clears MULTI flag, clears `dirty_cas` and `dirty_exec`, and unwatches all keys.

## EXEC Command

### execCommand(client *c)

Execution flow:

**Pre-checks:**
1. Verify client is in MULTI state.
2. Check if any WATCHed key expired since WATCH was called (`isWatchedKeyExpired`).
3. If `dirty_cas` is set (watched key modified) - return null array (not an error).
4. If `dirty_exec` is set (queuing error) - return `-EXECABORT`.

**Execution:**
1. Set `c->flag.deny_blocking = 1` - blocking commands inside MULTI are not allowed.
2. Call `unwatchAllKeys()` immediately to release WATCH resources.
3. Set `server.in_exec = 1`.
4. Send array reply header with count of queued commands.
5. For each queued command:
   - Restore `argc`, `argv`, `cmd` from the multiCmd.
   - Re-check ACL permissions (may have changed since queuing). On denial, reply with `-NOPERM`.
   - Call `call(c, CMD_CALL_FULL)` to execute.
   - Assert client is not blocked after each command.
   - Free original argv after processing.
6. Restore original EXEC command argv.
7. Call `discardTransaction()` to clean up.
8. Clear `server.in_exec`.

Per-command errors do NOT abort the transaction. Each command's reply (success or error) is included in the array response. Only `dirty_cas` and `dirty_exec` cause full abort before execution begins.

### Error Handling: EXECABORT vs Per-Command Errors

- **EXECABORT**: Returned when `dirty_exec` is set (a command failed during queuing, e.g. syntax error). No commands execute. The `-EXECABORT` message includes the original error.
- **Null array**: Returned when `dirty_cas` is set (a WATCHed key was modified). This is not technically an error - it is the expected optimistic locking behavior.
- **Per-command errors**: Individual commands that fail during EXEC (e.g. wrong type) return their error in the array response. Other commands still execute.

### flagTransaction(client *c)

Called whenever there is an error while queuing a command. Sets `dirty_exec` and resets the command queue (frees already-queued commands to save memory, since the transaction will abort anyway).

## WATCH Mechanism

WATCH implements optimistic locking - a check-and-set (CAS) pattern.

### Data Flow

Two-way mapping:
- `c->mstate->watched_keys` - list of `watchedKey` structs per client
- `db->watched_keys` - dict mapping key -> list of `watchedKey` nodes (via embedded listNode)

### watchForKey(client *c, robj *key)

1. First WATCH call increments `server.watching_clients`.
2. Check if already watching this key in this DB - skip if so.
3. Look up or create the client list in `db->watched_keys`.
4. Create a `watchedKey`, record whether key is currently expired.
5. Add to both the client's list and the per-key list.

### touchWatchedKey(serverDb *db, robj *key)

Called by command implementations when a key is modified.

1. Look up clients watching this key in `db->watched_keys`.
2. For each watcher:
   - If the key was already expired at WATCH time and is now being deleted, treat it as no logical change - clear the expired flag and skip.
   - Otherwise, set `c->flag.dirty_cas = 1` and call `resetClientMultiState()` to free queued commands early.
   - Call `unwatchAllKeys(c)` to stop watching - no point continuing once dirty.

### touchAllWatchedKeysInDb(serverDb *emptied, serverDb *replaced_with)

Handles bulk operations: FLUSHDB, FLUSHALL, SWAPDB, diskless replication completion. Marks all watching clients dirty, with special logic for SWAPDB where a key might exist in the replacement DB.

### isWatchedKeyExpired(client *c)

Checked at EXEC time. Iterates watched keys; if any key that was NOT expired at WATCH time is now expired, returns true. Keys that were already expired when watched are ignored - this prevents false positives from lazy expiry.

### unwatchAllKeys(client *c)

Removes the client from all per-key watch lists and frees all `watchedKey` structs. Decrements `server.watching_clients` counter.

## Memory Overhead Tracking

```c
size_t multiStateMemOverhead(client *c);
```

Returns the memory used by queued commands (argument data + robj pointers) plus watched key overhead plus reserved multiCmd array space. Used by CLIENT NO-EVICT and memory reporting.

## See Also

- [EVAL Subsystem](../scripting/eval.md) - Lua scripts execute atomically like transactions but support conditional logic and loops. EVAL is preferred when commands depend on intermediate results. MULTI/EXEC is simpler for unconditional command batching.
- [Functions Subsystem](../scripting/functions.md) - Named, persistent scripts that also execute atomically. Functions are the modern replacement for EVAL when server-side logic is needed.
- [Blocking Operations](../transactions/blocking.md) - Blocking commands (BLPOP, BRPOP, etc.) inside MULTI are rejected; the `deny_blocking` flag is set during EXEC.
- [ACL Subsystem](../security/acl.md) - ACL permissions are re-checked at EXEC time for each queued command, so permission changes between MULTI and EXEC are enforced.
- [Database Management](../config/db-management.md) - `signalModifiedKey()` calls `touchWatchedKey()` on every key mutation, which triggers the `dirty_cas` flag for WATCH-based optimistic locking.
