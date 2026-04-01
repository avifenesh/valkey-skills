# Event Loop - EventLoopAdd, EventLoopDel, EventLoopAddOneShot, Yield

Use when monitoring file descriptors (sockets, pipes) for read/write readiness, scheduling one-shot callbacks from background threads, or yielding the CPU during long-running module commands to let the server process events.

Source: `src/module.c` (lines 9790-9984, 2502-2587), `src/valkeymodule.h`

## Contents

- EventLoopAdd (line 19)
- EventLoopDel (line 63)
- EventLoopAddOneShot (line 86)
- Yield (line 114)
- Yield Flags (line 142)
- Usage Example - fd Monitoring (line 154)
- Usage Example - Thread Communication (line 195)

---

## EventLoopAdd

```c
int ValkeyModule_EventLoopAdd(int fd,
                              int mask,
                              ValkeyModuleEventLoopFunc func,
                              void *user_data);
```

Registers a file descriptor with the server's event loop for read and/or write readiness monitoring. This is the module equivalent of `aeCreateFileEvent`.

| Parameter | Description |
|-----------|-------------|
| `fd` | File descriptor (socket, pipe, etc.) |
| `mask` | `VALKEYMODULE_EVENTLOOP_READABLE`, `VALKEYMODULE_EVENTLOOP_WRITABLE`, or both OR'd together |
| `func` | Callback invoked when the fd is ready |
| `user_data` | Passed to the callback |

**Mask constants:**

| Constant | Value | Description |
|----------|-------|-------------|
| `VALKEYMODULE_EVENTLOOP_READABLE` | 1 | Monitor for read readiness |
| `VALKEYMODULE_EVENTLOOP_WRITABLE` | 2 | Monitor for write readiness |

**Return values and errors:**

| Return | errno | Condition |
|--------|-------|-----------|
| `VALKEYMODULE_OK` | 0 | Success |
| `VALKEYMODULE_ERR` | `ERANGE` | `fd` is negative or >= the event loop set size |
| `VALKEYMODULE_ERR` | `EINVAL` | `func` is NULL or `mask` is invalid |
| `VALKEYMODULE_ERR` | other | Internal event loop error |

**Callback signature:**

```c
typedef void (*ValkeyModuleEventLoopFunc)(int fd, void *user_data, int mask);
```

The callback receives the fd, the user data, and the mask indicating which condition triggered (readable, writable, or both).

You can register both readable and writable callbacks for the same fd by calling `EventLoopAdd` twice with different masks. Each call can specify a different callback function.

## EventLoopDel

```c
int ValkeyModule_EventLoopDel(int fd, int mask);
```

Removes a file descriptor event from the event loop.

| Parameter | Description |
|-----------|-------------|
| `fd` | File descriptor to remove |
| `mask` | Which events to remove (`READABLE`, `WRITABLE`, or both) |

**Return values and errors:**

| Return | errno | Condition |
|--------|-------|-----------|
| `VALKEYMODULE_OK` | 0 | Success |
| `VALKEYMODULE_ERR` | `ERANGE` | `fd` is negative or >= the event loop set size |
| `VALKEYMODULE_ERR` | `EINVAL` | `mask` is invalid |

When all events are removed for an fd (no readable or writable handler remains), the internal tracking structure for that fd is freed automatically.

## EventLoopAddOneShot

```c
int ValkeyModule_EventLoopAddOneShot(ValkeyModuleEventLoopOneShotFunc func,
                                     void *user_data);
```

Schedules a callback to execute once on the server's main thread during the next event loop iteration. This is the primary mechanism for background threads to safely invoke module APIs that must run on the main thread.

**Callback signature:**

```c
typedef void (*ValkeyModuleEventLoopOneShotFunc)(void *user_data);
```

**Thread safety:** This function is thread-safe. It uses a mutex-protected list and writes to the server's module pipe to wake the event loop.

**Return values:**

| Return | errno | Condition |
|--------|-------|-----------|
| `VALKEYMODULE_OK` | 0 | Success |
| `VALKEYMODULE_ERR` | `EINVAL` | `func` is NULL |

One-shot callbacks can register additional one-shot callbacks from within themselves. The mutex is released before each callback executes, so newly added callbacks are appended to the same list and processed in the same batch.

The pipe write that wakes the event loop is best-effort - if the pipe is full (non-blocking), the write may fail silently. This is safe because the event loop will process pending one-shots on its next natural iteration.

## Yield

```c
void ValkeyModule_Yield(ValkeyModuleCtx *ctx, int flags, const char *busy_reply);
```

Allows the server to process background tasks and optionally client commands during a long-running module command. Call this periodically from within a command that takes a long time.

| Parameter | Description |
|-----------|-------------|
| `ctx` | Module context |
| `flags` | `VALKEYMODULE_YIELD_FLAG_NONE` or `VALKEYMODULE_YIELD_FLAG_CLIENTS` |
| `busy_reply` | Optional custom string for the `-BUSY` error, or NULL for default |

**How it works:**

1. The module calls `Yield` periodically during its long operation.
2. The server processes pending events (timers, fd callbacks, one-shots).
3. With `YIELD_FLAG_CLIENTS`, after the `busy-reply-threshold` elapses, the server begins accepting commands marked with the `allow-busy` flag while rejecting others with `-BUSY`.

**Context support:**

- Works in command handler contexts
- Works in thread-safe contexts (while holding the GIL)
- Works during loading (in `rdb_load` callbacks) - rejects commands with `-LOADING`

**Nested call protection:** Recursive calls to `Yield` are ignored via an internal nesting counter.

## Yield Flags

| Flag | Value | Description |
|------|-------|-------------|
| `VALKEYMODULE_YIELD_FLAG_NONE` | `1<<0` | Process background tasks only, no client commands |
| `VALKEYMODULE_YIELD_FLAG_CLIENTS` | `1<<1` | Also process client commands (with `-BUSY` rejection after threshold) |

When yielding from a thread-safe context (not the main thread), the behavior depends on whether the main thread is attempting to acquire the GIL:

- If the main thread is acquiring, `Yield` releases the GIL, calls `sched_yield()`, and re-acquires it, allowing the main thread to process events.
- If the main thread is not acquiring, `Yield` writes to the module pipe to wake it and returns immediately without blocking.

## Usage Example - fd Monitoring

```c
static int notification_fd = -1;

void onReadable(int fd, void *user_data, int mask) {
    char buf[256];
    int n = read(fd, buf, sizeof(buf) - 1);
    if (n > 0) {
        buf[n] = '\0';
        /* Process incoming data from external service */
        processNotification(buf);
    }
}

int StartMonitoring_Command(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    notification_fd = connectToExternalService();
    if (notification_fd < 0)
        return ValkeyModule_ReplyWithError(ctx, "ERR connect failed");

    if (ValkeyModule_EventLoopAdd(notification_fd,
                                  VALKEYMODULE_EVENTLOOP_READABLE,
                                  onReadable, NULL) != VALKEYMODULE_OK) {
        close(notification_fd);
        return ValkeyModule_ReplyWithError(ctx, "ERR event loop registration failed");
    }

    return ValkeyModule_ReplyWithSimpleString(ctx, "OK");
}

int StopMonitoring_Command(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (notification_fd >= 0) {
        ValkeyModule_EventLoopDel(notification_fd,
            VALKEYMODULE_EVENTLOOP_READABLE | VALKEYMODULE_EVENTLOOP_WRITABLE);
        close(notification_fd);
        notification_fd = -1;
    }
    return ValkeyModule_ReplyWithSimpleString(ctx, "OK");
}
```

## Usage Example - Thread Communication

```c
typedef struct {
    ValkeyModuleBlockedClient *bc;
    char *result;
} ThreadResult;

void deliverResult(void *user_data) {
    ThreadResult *tr = user_data;
    /* Now on main thread - safe to unblock */
    ValkeyModule_UnblockClient(tr->bc, tr->result);
    free(tr);
}

void *workerThread(void *arg) {
    ThreadResult *tr = arg;
    tr->result = doHeavyWork();

    /* Schedule delivery on main thread */
    ValkeyModule_EventLoopAddOneShot(deliverResult, tr);
    return NULL;
}
```
