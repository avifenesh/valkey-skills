# Blocking Clients - BlockClient, UnblockClient, and Lifecycle

Use when implementing commands that block the client while waiting for background work (thread pool, network I/O), need to handle timeouts or disconnections of blocked clients, or want to measure background execution time.

Source: `src/module.c` (lines 8406-8908), `src/valkeymodule.h`

## Contents

- BlockClient (line 21)
- UnblockClient (line 59)
- AbortBlock (line 78)
- Disconnect Handling (line 86)
- Introspection APIs (line 107)
- Time Measurement (line 127)
- Private Data Access (line 142)
- Blocking Lifecycle Diagram (line 158)
- Usage Example (line 183)

---

## BlockClient

```c
ValkeyModuleBlockedClient *ValkeyModule_BlockClient(
    ValkeyModuleCtx *ctx,
    ValkeyModuleCmdFunc reply_callback,
    ValkeyModuleCmdFunc timeout_callback,
    void (*free_privdata)(ValkeyModuleCtx *, void *),
    long long timeout_ms);
```

Blocks the current client and returns a handle used later to unblock it. Pass `timeout_ms` as 0 for no timeout.

**Callback roles:**

| Callback | When Called | Purpose |
|----------|------------|---------|
| `reply_callback` | After `ValkeyModule_UnblockClient()` | Send the reply to the client |
| `timeout_callback` | When timeout expires or `CLIENT UNBLOCK` is issued | Send an error or timeout reply |
| `free_privdata` | After reply or timeout callback completes | Free the private data |

**Returns NULL in these cases (no block occurs):**

| Condition | errno |
|-----------|-------|
| Client already blocked or not a normal client | `ENOTSUP` |
| Temporary or new-client context | `EINVAL` |

**Cases where BlockClient returns a handle but does not actually block:**

- Client is inside a Lua script - an error reply is sent automatically
- Client is inside a MULTI transaction - an error reply is sent automatically
- Called from a reply callback context - an error reply is sent automatically

If the Lua/MULTI case originates from a keyspace notification callback, `NULL` is returned (errno `EINVAL`) instead of a handle with an error reply.

A module that registers a `timeout_callback` also supports `CLIENT UNBLOCK` from the admin, which triggers the timeout callback.

## UnblockClient

```c
int ValkeyModule_UnblockClient(ValkeyModuleBlockedClient *bc,
                               void *privdata);
```

Unblocks a client previously blocked with `ValkeyModule_BlockClient`. The `privdata` is passed to the reply callback. This function is thread-safe and can be called from any thread.

**Return values:**

| Return | Condition |
|--------|-----------|
| `VALKEYMODULE_OK` | Client successfully queued for unblocking |
| `VALKEYMODULE_ERR` (`EINVAL`) | `bc` is NULL |
| `VALKEYMODULE_ERR` (`ENOTSUP`) | Blocked on keys but no timeout callback registered |

`ValkeyModule_UnblockClient` must be called for every blocked client, even if the client was killed, timed out, or disconnected. Failing to do so causes memory leaks.

## AbortBlock

```c
int ValkeyModule_AbortBlock(ValkeyModuleBlockedClient *bc);
```

Unblocks the client without firing any callback (no reply, no timeout, no disconnect). The client is silently released.

## Disconnect Handling

```c
void ValkeyModule_SetDisconnectCallback(ValkeyModuleBlockedClient *bc,
                                        ValkeyModuleDisconnectFunc callback);
```

Registers a callback that fires when a blocked client disconnects before the module calls `UnblockClient`. Use this to clean up module state so that `UnblockClient` can be called safely.

**Constraints:**

- Do not call Reply functions in the disconnect callback - the client is gone.
- The disconnect callback is NOT called for timeout disconnections. The timeout callback handles that case instead.
- After `UnblockClient` or `AbortBlock` is called, the disconnect callback is cleared and will not fire.

```c
int ValkeyModule_BlockedClientDisconnected(ValkeyModuleCtx *ctx);
```

Returns non-zero when called from inside the `free_privdata` callback if the client disconnected while blocked. Useful for distinguishing between normal unblock and abnormal disconnection when cleaning up private data.

## Introspection APIs

```c
int ValkeyModule_IsBlockedReplyRequest(ValkeyModuleCtx *ctx);
```

Returns non-zero if the current command execution is the reply callback of a blocked client. Useful when the same function serves as both the command handler and the reply callback.

```c
int ValkeyModule_IsBlockedTimeoutRequest(ValkeyModuleCtx *ctx);
```

Returns non-zero if the current command execution is the timeout callback of a blocked client.

```c
ValkeyModuleBlockedClient *ValkeyModule_GetBlockedClientHandle(ValkeyModuleCtx *ctx);
```

Returns the `ValkeyModuleBlockedClient` handle associated with the current reply or timeout callback context. Useful when the module stores handles externally and needs to match them for cleanup.

## Time Measurement

By default, time spent in the blocked state is not counted toward the command's total duration in latency statistics. To include background processing time:

```c
int ValkeyModule_BlockedClientMeasureTimeStart(ValkeyModuleBlockedClient *bc);
int ValkeyModule_BlockedClientMeasureTimeEnd(ValkeyModuleBlockedClient *bc);
```

`MeasureTimeStart` marks the beginning of a measurement interval. `MeasureTimeEnd` marks the end and accumulates the elapsed time. You can call these multiple times to measure non-contiguous intervals.

`MeasureTimeEnd` returns `VALKEYMODULE_ERR` if `MeasureTimeStart` was not called first.

**Thread safety:** These functions are not thread-safe. If called from both a module thread and the main thread simultaneously, protect them with a module-owned lock rather than the GIL.

## Private Data Access

```c
void *ValkeyModule_GetBlockedClientPrivateData(ValkeyModuleCtx *ctx);
```

Retrieves the private data inside reply, timeout, or free_privdata callbacks. For `BlockClient`, this is the `privdata` passed to `UnblockClient`. For `BlockClientOnKeys`, this is the `privdata` passed at block time.

```c
void *ValkeyModule_BlockClientGetPrivateData(ValkeyModuleBlockedClient *bc);
void ValkeyModule_BlockClientSetPrivateData(ValkeyModuleBlockedClient *bc,
                                            void *private_data);
```

Direct getter/setter for the blocked client's private data outside of callback contexts.

## Blocking Lifecycle Diagram

```
Command handler
  |
  v
BlockClient() --> returns ValkeyModuleBlockedClient *bc
  |
  +--- spawn thread / async work
  |
  |    (thread completes)
  |    |
  |    v
  |    UnblockClient(bc, result)
  |    |
  v    v
reply_callback(ctx, argv, argc)  <-- privdata = result
  |
  v
free_privdata(ctx, privdata)
  |
  v
Client receives reply, unblocked
```

## Usage Example

```c
void *backgroundWork(void *arg) {
    ValkeyModuleBlockedClient *bc = arg;
    ValkeyModule_BlockedClientMeasureTimeStart(bc);

    char *result = doExpensiveComputation();

    ValkeyModule_BlockedClientMeasureTimeEnd(bc);
    ValkeyModule_UnblockClient(bc, result);
    return NULL;
}

int replyCallback(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    char *result = ValkeyModule_GetBlockedClientPrivateData(ctx);
    ValkeyModule_ReplyWithCString(ctx, result);
    return VALKEYMODULE_OK;
}

int timeoutCallback(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    ValkeyModule_ReplyWithError(ctx, "ERR timeout");
    return VALKEYMODULE_OK;
}

void freePrivdata(ValkeyModuleCtx *ctx, void *privdata) {
    free(privdata);
}

int MyCommand(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    ValkeyModuleBlockedClient *bc = ValkeyModule_BlockClient(
        ctx, replyCallback, timeoutCallback, freePrivdata, 5000);
    if (!bc) return ValkeyModule_ReplyWithError(ctx, "ERR cannot block");

    pthread_t tid;
    pthread_create(&tid, NULL, backgroundWork, bc);
    pthread_detach(tid);
    return VALKEYMODULE_OK;
}
```
