# Threading - Thread-Safe Contexts and the Global Interpreter Lock

Use when running module logic in background threads, accessing Valkey data or APIs from outside the main event loop, or building long-lived detached contexts for logging and monitoring.

Source: `src/module.c` (lines 8911-9051), `src/valkeymodule.h` (lines 1954-1959)

## Contents

- [Overview](#overview)
- [GetThreadSafeContext](#getthreadsafecontext)
- [GetDetachedThreadSafeContext](#getdetachedthreadsafecontext)
- [FreeThreadSafeContext](#freethreadsafecontext)
- [ThreadSafeContextLock](#threadsafecontextlock)
- [ThreadSafeContextTryLock](#threadsafecontexttrylock)
- [ThreadSafeContextUnlock](#threadsafecontextunlock)
- [GIL Semantics](#gil-semantics)
- [Pattern: Background Thread with Locked API Calls](#pattern-background-thread-with-locked-api-calls)
- [Pattern: Detached Context for Global Logging](#pattern-detached-context-for-global-logging)
- [Context Comparison Table](#context-comparison-table)

---

## Overview

Valkey is single-threaded - the main event loop processes all commands sequentially. Modules that offload work to background threads cannot call most ValkeyModule_* APIs directly because server data structures are not thread-safe.

Thread-safe contexts provide a context object usable from background threads. The module must acquire the Global Interpreter Lock (GIL) - a `pthread_mutex_t` (`src/module.c` line 325) - before calling any non-reply API through that context. Two flavors exist:

1. **Blocked-client context** - tied to a specific `ValkeyModuleBlockedClient`, allows `ValkeyModule_Reply*` calls without locking
2. **Detached context** - not tied to any client, used for fire-and-forget operations like logging, data writes, or periodic maintenance

---

## GetThreadSafeContext

```c
ValkeyModuleCtx *ValkeyModule_GetThreadSafeContext(ValkeyModuleBlockedClient *bc);
```

Returns a thread-safe context usable from any thread. Behavior depends on the `bc` argument:

- **bc != NULL** - Context is bound to the blocked client. The `ValkeyModule_Reply*` family of functions can be called without locking to accumulate a reply that is delivered when the client is unblocked. The context inherits the client's selected database and RESP protocol version.
- **bc == NULL** - Creates a detached context with a new internal client object. The context has no module identity attached. Prefer `GetDetachedThreadSafeContext` instead, which retains the module ID for logging.

When `bc` is provided, the context reuses the pre-allocated `thread_safe_ctx_client` from the blocked client to avoid creating a new client object. When `bc` is NULL, a new client is always allocated because the internal client pool is not synchronized for cross-thread access.

```c
void *backgroundWork(void *arg) {
    ValkeyModuleBlockedClient *bc = arg;
    ValkeyModuleCtx *ctx = ValkeyModule_GetThreadSafeContext(bc);

    ValkeyModule_ReplyWithSimpleString(ctx, "OK"); /* No locking needed */

    ValkeyModule_FreeThreadSafeContext(ctx);
    ValkeyModule_UnblockClient(bc, NULL);
    return NULL;
}
```

---

## GetDetachedThreadSafeContext

```c
ValkeyModuleCtx *ValkeyModule_GetDetachedThreadSafeContext(ValkeyModuleCtx *ctx);
```

Creates a thread-safe context that is not associated with any blocked client but retains the calling module's identity. The `ctx` argument is the module context from which the module pointer is copied - typically the context received in `OnLoad`.

This is the preferred way to create long-lived global contexts for logging or periodic background operations. The retained module ID means `ValkeyModule_Log` calls through this context correctly identify the module in log output.

Internally, this always creates a new client object (flags include both `VALKEYMODULE_CTX_THREAD_SAFE` and `VALKEYMODULE_CTX_NEW_CLIENT`).

```c
/* Create once during OnLoad, store globally */
static ValkeyModuleCtx *bgCtx = NULL;

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    /* ... Init, command registration ... */
    bgCtx = ValkeyModule_GetDetachedThreadSafeContext(ctx);
    return VALKEYMODULE_OK;
}
```

---

## FreeThreadSafeContext

```c
void ValkeyModule_FreeThreadSafeContext(ValkeyModuleCtx *ctx);
```

Releases a thread-safe context and its associated internal client object. Must be called when the context is no longer needed. For blocked-client contexts, call this before `ValkeyModule_UnblockClient`. For detached contexts held globally, free them during module unload.

```c
/* During module unload or cleanup */
if (bgCtx) {
    ValkeyModule_FreeThreadSafeContext(bgCtx);
    bgCtx = NULL;
}
```

---

## ThreadSafeContextLock

```c
void ValkeyModule_ThreadSafeContextLock(ValkeyModuleCtx *ctx);
```

Acquires the server's GIL. This call blocks until the lock is available. While held, the background thread can safely call ValkeyModule_* APIs that read or modify server data (e.g., `ValkeyModule_Call`, `ValkeyModule_OpenKey`, `ValkeyModule_Log`).

The `ctx` parameter is currently unused - the GIL is a process-global mutex, not per-context - but must be passed for API consistency. After acquiring the lock, the server's execution nesting level is incremented to defer command propagation until unlock.

**Not needed for `ValkeyModule_Reply*` calls** when the context was created with a non-NULL `ValkeyModuleBlockedClient`. Reply functions on blocked clients use their own buffering that is thread-safe by design.

---

## ThreadSafeContextTryLock

```c
int ValkeyModule_ThreadSafeContextTryLock(ValkeyModuleCtx *ctx);
```

Non-blocking variant of `ThreadSafeContextLock`. Attempts to acquire the GIL without waiting.

Returns:
- `VALKEYMODULE_OK` - lock acquired successfully, proceed with API calls
- `VALKEYMODULE_ERR` - lock not acquired, `errno` is set (typically `EBUSY`)

This is useful for background threads that have other work to do and should not stall waiting for the main thread. The thread can retry later or skip the Valkey operation for this iteration.

```c
if (ValkeyModule_ThreadSafeContextTryLock(ctx) == VALKEYMODULE_OK) {
    ValkeyModule_Log(ctx, "notice", "background check completed");
    ValkeyModule_ThreadSafeContextUnlock(ctx);
} else {
    /* Server is busy - skip this cycle, try again later */
}
```

---

## ThreadSafeContextUnlock

```c
void ValkeyModule_ThreadSafeContextUnlock(ValkeyModuleCtx *ctx);
```

Releases the GIL. Before releasing, the server's execution nesting level is restored and any pending command propagation (replication, AOF) is flushed. Always pair with a preceding `ThreadSafeContextLock` or successful `ThreadSafeContextTryLock`. Unlocking without holding the lock is undefined behavior.

---

## GIL Semantics

The Global Interpreter Lock (`moduleGIL`) is a single `pthread_mutex_t` that serializes all module background thread access to Valkey internals. Key points:

**What requires the GIL:**
- `ValkeyModule_Call` - executing any Valkey command
- `ValkeyModule_OpenKey`, key read/write operations
- `ValkeyModule_Log` and other server-state queries
- `ValkeyModule_Replicate`, `ValkeyModule_ReplicateVerbatim`
- Any API that reads or modifies server data structures

**What does not require the GIL:**
- `ValkeyModule_Reply*` calls on a context created with a blocked client
- `ValkeyModule_UnblockClient` - this is thread-safe by design
- `ValkeyModule_BlockedClientMeasureTimeStart/End`
- Pure computation in the background thread (no Valkey API calls)

**How the main thread participates:** The main event loop releases the GIL in `beforeSleep()` and re-acquires it before processing the next cycle. This gives background threads a window to acquire the lock between event loop iterations.

**Performance implications:** Minimize time holding the GIL. Do expensive computation outside the lock, acquire it only for the brief moment needed to write results back to Valkey. Never perform blocking I/O while holding the GIL.

---

## Pattern: Background Thread with Locked API Calls

The most common pattern: a command blocks the client, spawns a thread for heavy work, and the thread writes results back to Valkey before unblocking.

```c
typedef struct {
    ValkeyModuleBlockedClient *bc;
    ValkeyModuleString *key;
    char *input;
} BgTaskCtx;

void *bgThread(void *arg) {
    BgTaskCtx *task = arg;
    ValkeyModuleCtx *ctx = ValkeyModule_GetThreadSafeContext(task->bc);

    /* Phase 1: Heavy computation - no GIL needed */
    char *result = expensiveComputation(task->input);

    /* Phase 2: Write result to Valkey - GIL required */
    ValkeyModule_ThreadSafeContextLock(ctx);
    ValkeyModuleKey *key = ValkeyModule_OpenKey(ctx, task->key,
                                                VALKEYMODULE_WRITE);
    ValkeyModule_StringSet(key, ValkeyModule_CreateString(ctx, result, strlen(result)));
    ValkeyModule_CloseKey(key);
    ValkeyModule_ThreadSafeContextUnlock(ctx);

    /* Phase 3: Reply to client - no GIL needed for Reply* with bc */
    ValkeyModule_ReplyWithSimpleString(ctx, "OK");

    /* Cleanup */
    ValkeyModule_FreeThreadSafeContext(ctx);
    ValkeyModule_UnblockClient(task->bc, NULL);
    free(result);
    free(task->input);
    free(task);
    return NULL;
}

int ComputeAndStore_Cmd(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 3) return ValkeyModule_WrongArity(ctx);

    ValkeyModuleBlockedClient *bc = ValkeyModule_BlockClient(
        ctx, NULL, NULL, NULL, 30000);
    if (!bc) return ValkeyModule_ReplyWithError(ctx, "ERR cannot block");

    size_t len;
    const char *input = ValkeyModule_StringPtrLen(argv[2], &len);

    BgTaskCtx *task = malloc(sizeof(*task));
    task->bc = bc;
    task->key = argv[1];
    ValkeyModule_RetainString(ctx, task->key);
    task->input = strndup(input, len);

    pthread_t tid;
    pthread_create(&tid, NULL, bgThread, task);
    pthread_detach(tid);
    return VALKEYMODULE_OK;
}
```

---

## Pattern: Detached Context for Global Logging

```c
static ValkeyModuleCtx *monitorCtx = NULL;
static volatile int running = 1;

void *monitorThread(void *arg) {
    while (running) {
        sleep(10);

        if (ValkeyModule_ThreadSafeContextTryLock(monitorCtx) == VALKEYMODULE_OK) {
            ValkeyModuleCallReply *reply = ValkeyModule_Call(
                monitorCtx, "DBSIZE", "");
            if (reply) {
                long long size = ValkeyModule_CallReplyInteger(reply);
                ValkeyModule_Log(monitorCtx, "verbose",
                    "periodic check: dbsize=%lld", size);
                ValkeyModule_FreeCallReply(reply);
            }
            ValkeyModule_ThreadSafeContextUnlock(monitorCtx);
        }
    }
    return NULL;
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "monitor", 1, VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    monitorCtx = ValkeyModule_GetDetachedThreadSafeContext(ctx);

    pthread_t tid;
    pthread_create(&tid, NULL, monitorThread, NULL);
    pthread_detach(tid);
    return VALKEYMODULE_OK;
}
```

---

## Context Comparison Table

| Property | Command context | Blocked-client thread safe | Detached thread safe |
|----------|----------------|---------------------------|---------------------|
| Created by | Server (per command) | `GetThreadSafeContext(bc)` | `GetDetachedThreadSafeContext(ctx)` |
| Usable from threads | No | Yes | Yes |
| Reply* without GIL | N/A (main thread) | Yes | No (no client) |
| Module ID in logs | Yes | Only if bc has module | Yes |
| Typical lifetime | Single command | One background task | Module lifetime |
| Must free | No (auto) | Yes | Yes |
| GIL for data APIs | Not needed (main thread) | Required | Required |

## See Also

- [fork.md](fork.md) - Fork API for background child processes (alternative to threads)
- [scan.md](scan.md) - Thread-safe scanning with GIL lock/unlock interleaving
- [replication.md](replication.md) - Thread-safe context replication behavior
- [../lifecycle/context.md](../lifecycle/context.md) - Context flags and `GetContextFlags`
- [../events/blocking-clients.md](../events/blocking-clients.md) - BlockClient/UnblockClient and blocked client lifecycle
- [../events/eventloop.md](../events/eventloop.md) - EventLoopAddOneShot for scheduling from background threads
