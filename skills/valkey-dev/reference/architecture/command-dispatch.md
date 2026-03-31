# Command Dispatch

Use when you need to understand how a client request goes from raw bytes on the wire to command execution and reply.

## Contents

- End-to-End Flow (line 17)
- The Command Table (line 47)
- processCommand() - Pre-Execution Checks (`server.c:4222`) (line 99)
- call() - Command Execution (`server.c:3831`) (line 145)
- Pipelining (line 179)
- MULTI/EXEC Transactions (line 196)
- See Also (line 202)

---

## End-to-End Flow

```
Network bytes arrive
  |
  v
readQueryFromClient()          # File event callback on the client fd
  +-- readToQueryBuf()         # Read bytes into client->querybuf
  +-- handleReadResult()       # Check for errors, update stats
  +-- processInputBuffer()     # Parse RESP, execute commands
       |
       +-- parseInputBuffer()  # Detect inline vs multibulk, parse into argc/argv
       +-- prepareCommand()    # Look up command in table, validate arity
       +-- processCommand()    # All pre-execution checks
       |    +-- ACL check
       |    +-- Cluster redirect check
       |    +-- OOM / eviction check
       |    +-- Replication state checks
       |    +-- call()         # Actually execute the command
       |         +-- c->cmd->proc(c)  # The command function
       |
       +-- Reply is buffered
  |
  v
beforeSleep()
  +-- handleClientsWithPendingWrites()
       +-- writeToClient() / sendReplyToClient()
            +-- Write reply buffer to socket
```

## The Command Table

Commands are registered in a global `hashtable *` at `server.commands` (see [../data-structures/hashtable.md](../data-structures/hashtable.md)). Each entry is a `struct serverCommand` (`server.h:2692`):

```c
struct serverCommand {
    /* Declarative data */
    const char *declared_name;     /* Command name string */
    const char *summary;           /* Optional summary */
    const char *complexity;        /* Optional complexity description */
    const char *since;             /* Version when introduced */
    serverCommandProc *proc;       /* Implementation function pointer */
    int arity;                     /* Argument count. Negative means >= |arity| */
    uint64_t flags;                /* CMD_WRITE, CMD_READONLY, CMD_FAST, etc. */
    uint64_t acl_categories;       /* ACL category bitmask */
    keySpec *key_specs;            /* Key position specifications */
    int key_specs_num;
    serverGetKeysProc *getkeys_proc; /* Custom key extraction (for Cluster) */
    struct serverCommand *subcommands; /* Subcommand array (e.g., CLIENT|SETNAME) */

    /* Runtime populated data */
    long long microseconds, calls, rejected_calls, failed_calls;
    int id;                        /* Progressive ID for ACL bitmap */
    sds fullname;                  /* "parentcmd|childcmd" format */
    struct serverCommand *parent;  /* Parent command (for subcommand hierarchy) */
    sds current_name;              /* Current name after COMMAND RENAME */
    commandDbIdArgs *get_dbid_args; /* Argument positions containing database IDs */
    struct hdr_histogram *latency_histogram;
    hashtable *subcommands_ht;     /* Subcommand lookup table */
};
```

The command table is populated at startup from auto-generated definitions in `commands.c`. Each command's `proc` field points to its C implementation function (e.g., `getCommand`, `setCommand`).

### Command Flags

Key flags that affect dispatch:

| Flag | Meaning |
|------|---------|
| `CMD_WRITE` | Modifies data; rejected on read-only replicas |
| `CMD_READONLY` | Read-only; safe on replicas |
| `CMD_FAST` | O(1) or O(log N); tracked separately in latency |
| `CMD_DENYOOM` | Rejected when over maxmemory |
| `CMD_STALE` | When NOT set, rejected on stale replica |
| `CMD_LOADING` | When NOT set, rejected during data loading |
| `CMD_NO_AUTH` | Allowed before authentication (AUTH, HELLO) |
| `CMD_NO_MULTI` | Cannot be used inside MULTI/EXEC |
| `CMD_ALLOW_BUSY` | Allowed during busy script/module |
| `CMD_PROTECTED` | Requires explicit config to enable (DEBUG, MODULE) |
| `CMD_MAY_REPLICATE` | May propagate to replicas even if not strictly CMD_WRITE |

## processCommand() - Pre-Execution Checks (`server.c:4222`)

`processCommand()` is the gatekeeper. It runs a series of checks in this order before allowing execution:

```c
int processCommand(client *c) {
```

1. **Command lookup** - `c->cmd` is set from `c->parsed_cmd` (looked up during parsing). If not found, returns "unknown command" error.

2. **Authentication** - If `authRequired(c)` and command lacks `CMD_NO_AUTH`, reject with `NOAUTH`.

3. **Existence and arity** - Verify command exists and argument count matches `arity`.

4. **Protected commands** - Check `CMD_PROTECTED` against `enable-debug-command` / `enable-module-command` config.

5. **ACL check** - `ACLCheckAllPerm(c, &acl_errpos)` verifies the user has permission for the command, its keys, and channels.

6. **Cluster redirect** - If cluster-enabled, check slot ownership. If the key maps to a different node, send `MOVED` or `ASK` redirect.

7. **Failover redirect** - During failover, redirect writes with `-REDIRECT host:port` or postpone the client.

8. **Client eviction** - `evictClients()` to free memory from oversized client buffers.

9. **OOM check** - If `maxmemory` is set, run `performEvictions()`. If still OOM and command has `CMD_DENYOOM`, reject with `OOM`.

10. **Disk error check** - If persistence is failing, reject write commands.

11. **Min replicas check** - Reject writes if `min-replicas-to-write` threshold not met.

12. **Read-only replica** - Reject writes on read-only replicas (unless from primary).

13. **Pub/Sub restriction** - In RESP2 Pub/Sub mode, only subscription commands allowed.

14. **Stale replica** - Reject non-stale-safe commands when replica has broken primary link.

15. **Loading check** - Reject non-loading-safe commands during RDB/AOF load.

16. **Busy script/module** - Reject most commands during long-running Lua or module execution.

17. **Client pause** - Postpone if server is paused.

18. **MULTI/EXEC queuing** - If inside a transaction, queue the command instead of executing.

19. **Execute** - Call `call(c, CMD_CALL_FULL)`.

## call() - Command Execution (`server.c:3831`)

```c
void call(client *c, int flags) {
```

This function wraps the actual command execution with instrumentation:

1. **Save state** - Record previous `executing_client`, old `server.dirty` count, old replication offset.

2. **Clear per-call flags** - Reset `force_aof`, `force_repl`, `prevent_prop`.

3. **Execute** - `c->cmd->proc(c)` - the actual command function runs here.

4. **Measure duration** - Uses monotonic clock when available (hardware TSC), falls back to `ustime()`.

5. **Update stats** - Increment `cmd->calls`, accumulate `cmd->microseconds`. Record in latency histogram.

6. **Propagation** - If the command modified data (`dirty > 0`), propagate to AOF and replicas:
   - Append to `server.aof_buf`
   - Send to all connected replicas via the replication backlog

7. **Command log** - Check against slow-log and large-reply thresholds. Log if exceeded.

8. **Post-call hooks** - Module post-execution notifications, client-side caching invalidation tracking.

### The CMD_CALL Flags

| Flag | Effect |
|------|--------|
| `CMD_CALL_PROPAGATE_AOF` | Propagate to AOF |
| `CMD_CALL_PROPAGATE_REPL` | Propagate to replicas |
| `CMD_CALL_FULL` | `CMD_CALL_PROPAGATE_AOF \| CMD_CALL_PROPAGATE_REPL` (statistics are always updated unconditionally) |

## Pipelining

Valkey supports command pipelining - multiple commands sent without waiting for replies. The parsing layer handles this in `parseMultibulkBuffer()` (`networking.c:3478`):

After parsing one command, if more data is available in `querybuf` starting with `*`, it continues parsing into a command queue (`cmdQueue`). Up to 1024 queued commands are allowed.

```c
/* Try parsing pipelined commands. */
while ((flag & READ_FLAGS_PARSING_COMPLETED) &&
       sdslen(c->querybuf) > c->qb_pos &&
       c->querybuf[c->qb_pos] == '*') {
    /* ... parse into queue->cmds[] ... */
}
```

Commands from the queue are consumed one at a time in `processInputBuffer()`. Key prefetching (`prefetchCommandQueueKeys`) is applied to queued commands to warm the CPU cache before execution.

## MULTI/EXEC Transactions

When a client is in `MULTI` state (`c->flag.multi`), commands are not executed immediately. Instead, `processCommand()` calls `queueMultiCommand()` which stores the command in `c->mstate` (the multi-state queue) and replies with `+QUEUED`.

When `EXEC` arrives, all queued commands are executed sequentially via `call()`, and their replies are sent as an array.

## See Also

- [networking.md](networking.md) - How bytes arrive at `readQueryFromClient`
- [resp-protocol.md](resp-protocol.md) - RESP parsing details
- [event-loop.md](event-loop.md) - How `beforeSleep` flushes replies
- [../data-structures/hashtable.md](../data-structures/hashtable.md) - The `hashtable *` backing `server.commands`
- [../data-structures/encoding-transitions.md](../data-structures/encoding-transitions.md) - How command execution triggers encoding conversions
- [../valkey-specific/object-lifecycle.md](../valkey-specific/object-lifecycle.md) - The `robj` that commands receive in `c->argv[]`
- [../replication/overview.md](../replication/overview.md) - After `call()` executes a write command, `propagateNow()` fans out the command to both AOF and replicas via `replicationFeedReplicas()`
- [../persistence/aof.md](../persistence/aof.md) - Write commands are appended to `server.aof_buf` via `feedAppendOnlyFile()` in the same propagation path
- [../cluster/overview.md](../cluster/overview.md) - Step 6 in `processCommand()` checks slot ownership and sends MOVED/ASK redirects for cluster-enabled nodes
