# Context - ValkeyModuleCtx and Context Flags

Use when querying server state from a module command, checking replication role, detecting OOM conditions, or understanding what the context object provides.

Source: `src/module.c` (lines 161-204, 4093-4174), `src/valkeymodule.h` (lines 167-236)

## Contents

- ValkeyModuleCtx Structure (line 19)
- Internal Context Flags (line 58)
- GetContextFlags (line 79)
- Context Flag Constants (line 91)
- GetContextFlagsAll (line 142)
- Practical Patterns (line 161)
- See Also (line 191)

---

## ValkeyModuleCtx Structure

The context is the central object passed to every module callback. It tracks the calling client, auto-memory queue, pool allocator, and reply state.

```c
struct ValkeyModuleCtx {
    void *getapifuncptr;            /* Must be the first field */
    struct ValkeyModule *module;    /* Module reference */
    client *client;                 /* Client calling the command */
    struct ValkeyModuleBlockedClient *blocked_client;
    struct AutoMemEntry *amqueue;   /* Auto memory queue */
    int amqueue_len;                /* Total slots in amqueue */
    int amqueue_used;               /* Used slots in amqueue */
    int flags;                      /* VALKEYMODULE_CTX_... flags */
    void **postponed_arrays;        /* For ReplySetArrayLength() */
    int postponed_arrays_count;
    void *blocked_privdata;         /* Privdata set when unblocking */
    ValkeyModuleString *blocked_ready_key;
    getKeysResult *keys_result;     /* For key position requests */
    struct ValkeyModulePoolAllocBlock *pa_head;
    long long next_yield_time;
    const struct ValkeyModuleUser *user;
};
```

Source: `src/module.c` (lines 161-187)

Key fields for module developers:

| Field | Purpose |
|-------|---------|
| `module` | Back-reference to the owning ValkeyModule |
| `client` | The client connection that triggered the command |
| `flags` | Internal context state flags (not the same as GetContextFlags) |
| `pa_head` | Head of pool allocator block chain |
| `amqueue` | Auto-memory tracking queue |

The context is stack-allocated inside the server dispatch path. Module developers receive it as a pointer parameter and must not store it beyond the callback's lifetime.

## Internal Context Flags

These internal flags (set in `ctx->flags`) control the context's behavior. They are distinct from the public `VALKEYMODULE_CTX_FLAGS_*` constants returned by `GetContextFlags`:

| Flag | Value | Purpose |
|------|-------|---------|
| `VALKEYMODULE_CTX_AUTO_MEMORY` | `1 << 0` | Auto-memory management enabled |
| `VALKEYMODULE_CTX_KEYS_POS_REQUEST` | `1 << 1` | GetKeys callback invocation |
| `VALKEYMODULE_CTX_BLOCKED_REPLY` | `1 << 2` | Processing blocked client reply |
| `VALKEYMODULE_CTX_BLOCKED_TIMEOUT` | `1 << 3` | Processing blocked client timeout |
| `VALKEYMODULE_CTX_THREAD_SAFE` | `1 << 4` | Thread-safe context |
| `VALKEYMODULE_CTX_BLOCKED_DISCONNECTED` | `1 << 5` | Blocked client disconnected |
| `VALKEYMODULE_CTX_TEMP_CLIENT` | `1 << 6` | Return client to pool on destroy |
| `VALKEYMODULE_CTX_NEW_CLIENT` | `1 << 7` | Free client on destroy |
| `VALKEYMODULE_CTX_CHANNELS_POS_REQUEST` | `1 << 8` | GetChannels callback invocation |
| `VALKEYMODULE_CTX_COMMAND` | `1 << 9` | Serving a command from call() or AOF |
| `VALKEYMODULE_CTX_KEYSPACE_NOTIFICATION` | `1 << 10` | Keyspace notification event |
| `VALKEYMODULE_CTX_SCRIPT_EXECUTION` | `1 << 11` | Scripting engine execution |

These are defined in `src/module.c` (lines 190-204) and are internal to the server - modules do not set them directly.

## GetContextFlags

`ValkeyModule_GetContextFlags(ctx)` returns a bitmask describing the current server and client state. This is the primary API for modules to inspect runtime conditions:

```c
int ValkeyModule_GetContextFlags(ValkeyModuleCtx *ctx);
```

The implementation (lines 4093-4174) checks the client, server, replication, persistence, memory, and cluster state, combining relevant flags into a single return value.

The `ctx` parameter may be NULL for some flags that only reflect server-wide state (cluster, loading, persistence, replication role). Client-specific flags require a valid context.

## Context Flag Constants

These public constants are defined in `src/valkeymodule.h` (lines 167-236):

### Client State

| Flag | Bit | Description |
|------|-----|-------------|
| `VALKEYMODULE_CTX_FLAGS_LUA` | `1 << 0` | Running inside a Lua script |
| `VALKEYMODULE_CTX_FLAGS_MULTI` | `1 << 1` | Inside a MULTI/EXEC transaction |
| `VALKEYMODULE_CTX_FLAGS_REPLICATED` | `1 << 12` | Command received over replication link |
| `VALKEYMODULE_CTX_FLAGS_DENY_BLOCKING` | `1 << 21` | Client does not allow blocking |
| `VALKEYMODULE_CTX_FLAGS_RESP3` | `1 << 22` | Client uses RESP3 protocol |
| `VALKEYMODULE_CTX_FLAGS_MULTI_DIRTY` | `1 << 19` | Next EXEC will fail (dirty CAS) |
| `VALKEYMODULE_CTX_FLAGS_SLOT_IMPORT_CLIENT` | `1 << 25` | Slot import client |
| `VALKEYMODULE_CTX_FLAGS_SLOT_EXPORT_CLIENT` | `1 << 26` | Slot export client |

### Replication Role

| Flag | Bit | Description |
|------|-----|-------------|
| `VALKEYMODULE_CTX_FLAGS_PRIMARY` | `1 << 2` | Instance is primary |
| `VALKEYMODULE_CTX_FLAGS_REPLICA` | `1 << 3` | Instance is replica |
| `VALKEYMODULE_CTX_FLAGS_READONLY` | `1 << 4` | Instance is read-only |
| `VALKEYMODULE_CTX_FLAGS_REPLICA_IS_STALE` | `1 << 14` | No link with primary |
| `VALKEYMODULE_CTX_FLAGS_REPLICA_IS_CONNECTING` | `1 << 15` | Connecting to primary |
| `VALKEYMODULE_CTX_FLAGS_REPLICA_IS_TRANSFERRING` | `1 << 16` | Receiving RDB from primary |
| `VALKEYMODULE_CTX_FLAGS_REPLICA_IS_ONLINE` | `1 << 17` | Receiving updates from primary |

### Server State

| Flag | Bit | Description |
|------|-----|-------------|
| `VALKEYMODULE_CTX_FLAGS_CLUSTER` | `1 << 5` | Cluster mode enabled |
| `VALKEYMODULE_CTX_FLAGS_AOF` | `1 << 6` | AOF enabled |
| `VALKEYMODULE_CTX_FLAGS_RDB` | `1 << 7` | RDB save configured |
| `VALKEYMODULE_CTX_FLAGS_LOADING` | `1 << 13` | Loading from AOF or RDB |
| `VALKEYMODULE_CTX_FLAGS_ASYNC_LOADING` | `1 << 23` | Async loading for diskless replication |
| `VALKEYMODULE_CTX_FLAGS_SERVER_STARTUP` | `1 << 24` | Server is starting up |
| `VALKEYMODULE_CTX_FLAGS_ACTIVE_CHILD` | `1 << 18` | Background child process active |
| `VALKEYMODULE_CTX_FLAGS_IS_CHILD` | `1 << 20` | Running inside background child |

### Memory

| Flag | Bit | Description |
|------|-----|-------------|
| `VALKEYMODULE_CTX_FLAGS_MAXMEMORY` | `1 << 8` | maxmemory is set |
| `VALKEYMODULE_CTX_FLAGS_EVICT` | `1 << 9` | Eviction policy may delete keys |
| `VALKEYMODULE_CTX_FLAGS_OOM` | `1 << 10` | Out of memory |
| `VALKEYMODULE_CTX_FLAGS_OOM_WARNING` | `1 << 11` | Less than 25% memory available |

## GetContextFlagsAll

To check if a specific flag is supported by the server version at runtime:

```c
int ValkeyModule_GetContextFlagsAll(void);
```

Returns a bitmask with all supported context flags set. Use bitwise AND to check for specific flag support:

```c
int supported = ValkeyModule_GetContextFlagsAll();
if (supported & VALKEYMODULE_CTX_FLAGS_ASYNC_LOADING) {
    /* Flag is supported in this server version */
}
```

The value equals `_VALKEYMODULE_CTX_FLAGS_NEXT - 1`, which is updated whenever new flags are added.

## Practical Patterns

Check if the module should accept writes:

```c
int flags = ValkeyModule_GetContextFlags(ctx);
if (flags & VALKEYMODULE_CTX_FLAGS_REPLICA &&
    flags & VALKEYMODULE_CTX_FLAGS_READONLY) {
    return ValkeyModule_ReplyWithError(ctx, "READONLY");
}
```

Adapt behavior during loading:

```c
int flags = ValkeyModule_GetContextFlags(ctx);
if (flags & VALKEYMODULE_CTX_FLAGS_LOADING) {
    /* Skip side effects during AOF/RDB loading */
}
```

Check OOM before allocating:

```c
int flags = ValkeyModule_GetContextFlags(ctx);
if (flags & VALKEYMODULE_CTX_FLAGS_OOM) {
    return ValkeyModule_ReplyWithError(ctx, "OOM");
}
```
