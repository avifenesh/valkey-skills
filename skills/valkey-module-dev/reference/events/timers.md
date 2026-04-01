# Timers - CreateTimer, StopTimer, GetTimerInfo

Use when scheduling periodic or one-shot callbacks with millisecond precision, implementing background maintenance tasks, retry logic, or deferred operations without blocking clients.

Source: `src/module.c` (lines 9599-9787), `src/valkeymodule.h`

## Contents

- Architecture (line 20)
- CreateTimer (line 31)
- Timer Callback Signature (line 53)
- StopTimer (line 66)
- GetTimerInfo (line 98)
- Repeating Timers (line 118)
- Timer Accuracy (line 144)
- Usage Example (line 155)

---

## Architecture

Module timers are "green timers" - the server maintains a single event loop timer that drives a radix tree of all registered module timers sorted by expiration time. This design supports millions of concurrent timers with minimal overhead.

Key properties:

- Timers are stored in a radix tree keyed by expiration timestamp (microsecond precision).
- The event loop re-arms its single timer to the next expiration after processing expired timers.
- When no module timers exist, the event loop timer is unregistered entirely - zero overhead when unused.
- Timer callbacks run on the main thread, not in a separate thread.

## CreateTimer

```c
ValkeyModuleTimerID ValkeyModule_CreateTimer(ValkeyModuleCtx *ctx,
                                             mstime_t period,
                                             ValkeyModuleTimerProc callback,
                                             void *data);
```

Creates a timer that fires after `period` milliseconds. Returns a `ValkeyModuleTimerID` (a `uint64_t`) that can be used with `StopTimer` and `GetTimerInfo`.

| Parameter | Description |
|-----------|-------------|
| `ctx` | Module context |
| `period` | Delay in milliseconds before the callback fires |
| `callback` | Function to call when the timer expires |
| `data` | Private data passed to the callback |

The timer ID is internally the network-byte-order encoding of the expiration timestamp. If two timers would have the same expiration, the second is shifted by 1 microsecond to ensure uniqueness.

The timer callback receives a temporary client context with the database selected to match the original context's database at timer creation time.

## Timer Callback Signature

```c
typedef void (*ValkeyModuleTimerProc)(ValkeyModuleCtx *ctx, void *data);
```

| Parameter | Description |
|-----------|-------------|
| `ctx` | Temporary module context - can call most module APIs |
| `data` | The private data pointer passed to `CreateTimer` |

The callback runs synchronously on the main server thread. Long-running callbacks block the event loop and delay command processing. For heavy work, spawn a thread from the callback.

## StopTimer

```c
int ValkeyModule_StopTimer(ValkeyModuleCtx *ctx,
                           ValkeyModuleTimerID id,
                           void **data);
```

Cancels a pending timer before it fires.

| Parameter | Description |
|-----------|-------------|
| `ctx` | Module context |
| `id` | Timer ID returned by `CreateTimer` |
| `data` | Output - receives the private data pointer, or pass NULL |

**Return values:**

| Return | Condition |
|--------|-----------|
| `VALKEYMODULE_OK` | Timer found, belonged to this module, and was stopped |
| `VALKEYMODULE_ERR` | Timer not found or belongs to a different module |

The `data` output parameter lets you reclaim the private data for cleanup:

```c
void *mydata;
if (ValkeyModule_StopTimer(ctx, timer_id, &mydata) == VALKEYMODULE_OK) {
    free(mydata);
}
```

## GetTimerInfo

```c
int ValkeyModule_GetTimerInfo(ValkeyModuleCtx *ctx,
                              ValkeyModuleTimerID id,
                              uint64_t *remaining,
                              void **data);
```

Queries a timer's remaining time and private data without stopping it.

| Parameter | Description |
|-----------|-------------|
| `ctx` | Module context |
| `id` | Timer ID returned by `CreateTimer` |
| `remaining` | Output - milliseconds until the timer fires, or pass NULL |
| `data` | Output - the private data pointer, or pass NULL |

Returns `VALKEYMODULE_ERR` if the timer does not exist or belongs to a different module.

## Repeating Timers

Module timers are one-shot. To create a repeating timer, re-register from inside the callback. The placement of the `CreateTimer` call affects the interval behavior:

```c
void heartbeat(ValkeyModuleCtx *ctx, void *data) {
    /* Re-register FIRST: fires every 1000ms regardless of callback duration */
    ValkeyModule_CreateTimer(ctx, 1000, heartbeat, data);

    doPeriodicWork();
}
```

vs.

```c
void heartbeat(ValkeyModuleCtx *ctx, void *data) {
    doPeriodicWork();

    /* Re-register LAST: 1000ms gap between end of one call and start of next */
    ValkeyModule_CreateTimer(ctx, 1000, heartbeat, data);
}
```

If the callback execution time is negligible, both approaches are equivalent. For callbacks that take measurable time, choose based on whether you want a fixed interval or a fixed gap.

## Timer Accuracy

Module timers use a dedicated `ae` time event rather than the `serverCron` periodic hook. The event loop schedules the next wakeup to match the earliest expiring module timer, so timers are not gated by the `hz` config:

- The time event callback uses `ustime()` (microsecond clock) to check expirations.
- After processing all expired timers, the event loop re-arms the time event to the next expiration - so a 5ms timer gets a 5ms wakeup, not the 100ms `serverCron` cycle.
- A timer with a very short period (e.g. 1ms) will fire on the next event loop iteration after expiration, which may be delayed by command processing or other event handlers.
- Under heavy load, timer callbacks may be delayed by the event loop backlog.

All expired timers are processed in a batch when the event loop timer fires. If multiple timers expire at the same time, they execute sequentially in expiration order.

## Usage Example

```c
static ValkeyModuleTimerID cleanup_timer = 0;

void cleanupCallback(ValkeyModuleCtx *ctx, void *data) {
    long *counter = data;
    (*counter)++;

    ValkeyModule_Log(ctx, "verbose", "Cleanup run #%ld", *counter);

    /* Re-register for next run */
    cleanup_timer = ValkeyModule_CreateTimer(ctx, 60000, cleanupCallback, data);
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "mymodule", 1, VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    long *counter = ValkeyModule_Alloc(sizeof(long));
    *counter = 0;
    cleanup_timer = ValkeyModule_CreateTimer(ctx, 60000, cleanupCallback, counter);
    return VALKEYMODULE_OK;
}

int ValkeyModule_OnUnload(ValkeyModuleCtx *ctx) {
    void *data;
    if (ValkeyModule_StopTimer(ctx, cleanup_timer, &data) == VALKEYMODULE_OK) {
        ValkeyModule_Free(data);
    }
    return VALKEYMODULE_OK;
}
```
