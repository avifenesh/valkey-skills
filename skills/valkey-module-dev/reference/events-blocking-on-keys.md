# Blocking on Keys - BlockClientOnKeys, Ready Callbacks, SignalKeyAsReady

Use when implementing commands that block a client until one or more keys receive new data (like BLPOP or BZPOPMAX), or when building custom blocking data structures that unblock clients when keys become ready.

Source: `src/module.c` (lines 8560-8598, 8386-8401, 8655-8671, 8891-8893), `src/valkeymodule.h`

## Contents

- BlockClientOnKeys (line 20)
- BlockClientOnKeysWithFlags (line 53)
- Ready Callback Pattern (line 75)
- SignalKeyAsReady (line 112)
- GetBlockedClientReadyKey (line 125)
- Key Readiness Flow (line 133)
- Differences from BlockClient (line 161)
- Usage Example (line 174)

---

## BlockClientOnKeys

```c
ValkeyModuleBlockedClient *ValkeyModule_BlockClientOnKeys(
    ValkeyModuleCtx *ctx,
    ValkeyModuleCmdFunc reply_callback,
    ValkeyModuleCmdFunc timeout_callback,
    void (*free_privdata)(ValkeyModuleCtx *, void *),
    long long timeout_ms,
    ValkeyModuleString **keys,
    int numkeys,
    void *privdata);
```

Blocks the current client until one of the specified keys becomes "ready" (receives new data). The server automatically watches these keys and calls the `reply_callback` when any of them is signaled.

**How keys become ready:**

1. Built-in type operations - if you block on a list key, an RPUSH to that key signals readiness automatically. This works for lists, sorted sets, streams, and other types that have native blocking operations.
2. Explicit signaling - call `ValkeyModule_SignalKeyAsReady()` from any command that modifies your custom data type.

**Callback roles:**

| Callback | When Called | Purpose |
|----------|------------|---------|
| `reply_callback` | Each time a watched key becomes ready | Check if the client can be served; return `VALKEYMODULE_OK` to unblock or `VALKEYMODULE_ERR` to keep waiting |
| `timeout_callback` | When timeout expires | Send timeout error reply |
| `free_privdata` | After final unblock | Free private data |

**Private data:** Unlike `BlockClient`, here `privdata` is passed at block time (not at unblock time). This is because unblocking is automatic - the server triggers it when a key becomes ready.

**Error conditions:** Returns NULL if the client is already blocked (`errno=ENOTSUP`) or is a temporary/new client (`errno=EINVAL`). Inside Lua or MULTI, a handle is returned but the client is not actually blocked - an error reply is sent instead.

## BlockClientOnKeysWithFlags

```c
ValkeyModuleBlockedClient *ValkeyModule_BlockClientOnKeysWithFlags(
    ValkeyModuleCtx *ctx,
    ValkeyModuleCmdFunc reply_callback,
    ValkeyModuleCmdFunc timeout_callback,
    void (*free_privdata)(ValkeyModuleCtx *, void *),
    long long timeout_ms,
    ValkeyModuleString **keys,
    int numkeys,
    void *privdata,
    int flags);
```

Same as `BlockClientOnKeys` but accepts additional flags:

| Flag | Value | Description |
|------|-------|-------------|
| `VALKEYMODULE_BLOCK_UNBLOCK_DEFAULT` | 0 | Default behavior, same as `BlockClientOnKeys` |
| `VALKEYMODULE_BLOCK_UNBLOCK_DELETED` | (flag) | Also wake the client when a watched key is deleted. Useful for commands that require the key to exist (like XREADGROUP). |

## Ready Callback Pattern

The reply callback for key-blocked clients behaves differently from the one in `BlockClient`. It is called every time any watched key is signaled as ready, not just once:

```c
int readyCallback(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    /* Which key became ready? */
    ValkeyModuleString *readyKey = ValkeyModule_GetBlockedClientReadyKey(ctx);

    /* Try to serve the client */
    ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, readyKey, VALKEYMODULE_READ);
    if (key == NULL)
        return VALKEYMODULE_ERR; /* Key gone, keep waiting */

    /* Check if the key has enough data */
    size_t len = ValkeyModule_ValueLength(key);
    if (len < 1) {
        ValkeyModule_CloseKey(key);
        return VALKEYMODULE_ERR; /* Not enough data, keep waiting */
    }

    /* Serve the client */
    ValkeyModule_ReplyWithLongLong(ctx, (long long)len);
    ValkeyModule_CloseKey(key);
    return VALKEYMODULE_OK; /* Client unblocked */
}
```

**Return value semantics:**

| Return | Effect |
|--------|--------|
| `VALKEYMODULE_OK` | Client is served and unblocked |
| `VALKEYMODULE_ERR` | Client remains blocked, will retry on next signal |

The callback can also access the original command arguments through `argv` and `argc`, and the private data via `ValkeyModule_GetBlockedClientPrivateData(ctx)`.

## SignalKeyAsReady

```c
void ValkeyModule_SignalKeyAsReady(ValkeyModuleCtx *ctx,
                                   ValkeyModuleString *key);
```

Signals that a key has new data available. All clients blocked on this key via `BlockClientOnKeys` will have their reply callback invoked.

Call this from any command that adds data to your custom data type. For built-in types (list, sorted set, stream), the server signals automatically - you only need this for module-defined types or custom unblocking conditions.

The signal is associated with the database of the current context's client.

## GetBlockedClientReadyKey

```c
ValkeyModuleString *ValkeyModule_GetBlockedClientReadyKey(ValkeyModuleCtx *ctx);
```

Returns the name of the key that triggered the ready callback. Only valid inside the reply callback of a client blocked with `BlockClientOnKeys`. Returns NULL in other contexts.

## Key Readiness Flow

```
Client sends: MYBLOCKPOP mykey 0
  |
  v
Command handler calls BlockClientOnKeys(ctx, readyCb, timeoutCb, ...)
  |
  v
Client is blocked, watching "mykey"
  |
  ...time passes...
  |
Another client sends: MYPUSH mykey value1
  |
  v
MYPUSH handler calls SignalKeyAsReady(ctx, "mykey")
  |
  v
Server calls readyCb for each client blocked on "mykey"
  |
  +-- readyCb returns VALKEYMODULE_OK --> client unblocked, reply sent
  |
  +-- readyCb returns VALKEYMODULE_ERR --> client stays blocked
```

Multiple clients can block on the same key. When the key is signaled, their ready callbacks are called in order (FIFO). If the first client's callback consumes all the data, subsequent clients' callbacks return `VALKEYMODULE_ERR` and remain blocked.

## Differences from BlockClient

| Aspect | `BlockClient` | `BlockClientOnKeys` |
|--------|--------------|---------------------|
| Unblock trigger | Explicit `UnblockClient()` call | Key becomes ready |
| Private data set | At `UnblockClient()` time | At `BlockClientOnKeys()` time |
| Reply callback called | Once after unblock | Potentially multiple times (each key signal) |
| Reply callback return | Ignored | `OK` = unblock, `ERR` = keep waiting |
| Thread usage | Typically thread-spawned | Server-driven, no threads needed |
| `UnblockClient` effect | Triggers reply callback | Triggers timeout callback (treated as timeout) |

Calling `ValkeyModule_UnblockClient` on a key-blocked client is possible but unusual. It triggers the timeout callback, not the reply callback.

## Usage Example

```c
int MyBlockPop_Command(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 3) return ValkeyModule_WrongArity(ctx);

    /* Try to serve immediately */
    ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, argv[1], VALKEYMODULE_READ);
    if (key && ValkeyModule_ValueLength(key) > 0) {
        /* Data available - serve immediately */
        ValkeyModule_ReplyWithLongLong(ctx, (long long)ValkeyModule_ValueLength(key));
        ValkeyModule_CloseKey(key);
        return VALKEYMODULE_OK;
    }
    if (key) ValkeyModule_CloseKey(key);

    /* No data - block until the key gets data */
    long long timeout;
    ValkeyModule_StringToLongLong(argv[2], &timeout);

    ValkeyModule_BlockClientOnKeys(ctx, readyCallback, timeoutCallback,
                                   freePrivdata, timeout, &argv[1], 1, NULL);
    return VALKEYMODULE_OK;
}
```
