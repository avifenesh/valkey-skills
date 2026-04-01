# Fork API - Background Processing from Modules

Use when a module needs to perform heavy computation or I/O in a background child process without blocking the main event loop or freezing client traffic.

Source: `src/module.c` (lines 11735-11825), `src/valkeymodule.h` (lines 2040-2043), `tests/modules/fork.c`

## Contents

- [ValkeyModule_Fork](#valkeymodule_fork)
- [ValkeyModule_SendChildHeartbeat](#valkeymodule_sendchildheartbeat)
- [ValkeyModule_ExitFromChild](#valkeymodule_exitfromchild)
- [ValkeyModule_KillForkChild](#valkeymodule_killforkchild)
- [Done Handler Callback](#done-handler-callback)
- [Fork Exclusivity - BGSAVE and BGREWRITEAOF](#fork-exclusivity---bgsave-and-bgrewriteaof)
- [Feature Detection](#feature-detection)
- [Complete Pattern](#complete-pattern)
- [Error Conditions](#error-conditions)

---

## ValkeyModule_Fork

```c
int ValkeyModule_Fork(ValkeyModuleForkDoneHandler cb, void *user_data);
```

Creates a background child process with a frozen copy-on-write snapshot of the server's memory. The child can perform arbitrary work without affecting client traffic - no threads, no GIL locking.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `cb` | `ValkeyModuleForkDoneHandler` | Callback invoked on the parent when the child exits normally (not when killed) |
| `user_data` | `void *` | Opaque pointer passed through to the done handler |

**Return values:**

| Value | Meaning |
|-------|---------|
| `> 0` | Parent process - value is the child's PID |
| `0` | Child process |
| `-1` | Fork failed (another child is active, or system error) |

The return value follows the standard `fork()` convention. The parent receives the child PID for later use with `ValkeyModule_KillForkChild`. The child receives 0 and should do its work, then call `ValkeyModule_ExitFromChild`.

```c
int pid = ValkeyModule_Fork(my_done_handler, my_data);
if (pid < 0) {
    /* Fork failed - another child process may be active */
    ValkeyModule_ReplyWithError(ctx, "ERR fork failed");
    return VALKEYMODULE_OK;
} else if (pid > 0) {
    /* Parent - store PID, reply to client */
    saved_child_pid = pid;
    ValkeyModule_ReplyWithLongLong(ctx, pid);
    return VALKEYMODULE_OK;
}

/* Child - do background work here */
do_expensive_computation();
ValkeyModule_ExitFromChild(0);
/* unreachable */
```

Internally, `ValkeyModule_Fork` calls `serverFork(CHILD_TYPE_MODULE)`, which checks `hasActiveChildProcess()` before proceeding. If any child process is already running (RDB save, AOF rewrite, another module fork, or slot migration), the fork is rejected with `-1` and `errno` is set to `EALREADY`.

## ValkeyModule_SendChildHeartbeat

```c
void ValkeyModule_SendChildHeartbeat(double progress);
```

Call periodically from the child process to report progress and copy-on-write memory usage to the parent. The parent exposes this information through the `INFO` command.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `progress` | `double` | Progress value between 0.0 and 1.0, or -1.0 when progress is not available |

The heartbeat sends `CHILD_INFO_TYPE_CURRENT_INFO` to the parent through the child info pipe. The parent uses this to update `stat_module_progress` and COW memory stats visible in `INFO persistence`.

```c
/* In the child process - report progress during a long operation */
for (int i = 0; i < total_items; i++) {
    process_item(i);
    if (i % 1000 == 0) {
        ValkeyModule_SendChildHeartbeat((double)i / total_items);
    }
}
ValkeyModule_SendChildHeartbeat(1.0);
```

Call this at reasonable intervals - every few thousand iterations or every few seconds. Calling too frequently adds overhead; calling too rarely means stale progress in `INFO`.

## ValkeyModule_ExitFromChild

```c
int ValkeyModule_ExitFromChild(int retcode);
```

Terminates the child process cleanly. Must be called from the child (where `ValkeyModule_Fork` returned 0). Before exiting, it sends final copy-on-write memory statistics (`CHILD_INFO_TYPE_MODULE_COW_SIZE`) to the parent.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `retcode` | `int` | Exit code delivered to the parent's done handler |

Returns `VALKEYMODULE_OK` (though the process exits before the caller sees it).

The `retcode` value is passed to the done handler's `exitcode` parameter. Use 0 for success and non-zero values for application-specific error conditions.

```c
/* Child process - exit with success */
ValkeyModule_ExitFromChild(0);
/* Code after this line is unreachable */
```

Do not call `exit()` directly from a forked module child. `ValkeyModule_ExitFromChild` calls `exitFromChild()`, which handles cleanup and ensures COW stats are reported before the process terminates.

## ValkeyModule_KillForkChild

```c
int ValkeyModule_KillForkChild(int child_pid);
```

Kills the forked child process from the parent. The child receives `SIGUSR1`. The parent blocks until the child has exited (`waitpid`).

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `child_pid` | `int` | The PID returned by `ValkeyModule_Fork` |

**Return values:**

| Value | Meaning |
|-------|---------|
| `VALKEYMODULE_OK` | Child was killed successfully |
| `VALKEYMODULE_ERR` | No active module child, or PID does not match |

The PID parameter must match the currently active module child. If the server's active child type is not `CHILD_TYPE_MODULE` or the PID does not match `server.child_pid`, the call returns `VALKEYMODULE_ERR` without doing anything.

When the child is killed (rather than exiting on its own), the done handler callback is not invoked. The parent calls `resetChildState()` and clears the done handler internally.

```c
if (ValkeyModule_KillForkChild(saved_child_pid) == VALKEYMODULE_OK) {
    saved_child_pid = -1;
    /* Child terminated - done handler will NOT be called */
} else {
    /* No active child or PID mismatch */
}
```

## Done Handler Callback

```c
typedef void (*ValkeyModuleForkDoneHandler)(int exitcode, int bysignal, void *user_data);
```

Executed on the parent process when the child exits normally (via `ValkeyModule_ExitFromChild`). Not called when the child is killed via `ValkeyModule_KillForkChild`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `exitcode` | `int` | The `retcode` passed to `ValkeyModule_ExitFromChild` |
| `bysignal` | `int` | Non-zero if the child was terminated by a signal |
| `user_data` | `void *` | The pointer originally passed to `ValkeyModule_Fork` |

```c
void my_done_handler(int exitcode, int bysignal, void *user_data) {
    MyModuleState *state = (MyModuleState *)user_data;
    state->child_pid = -1;
    if (bysignal) {
        serverLog(LL_WARNING, "Child killed by signal");
    } else if (exitcode == 0) {
        serverLog(LL_NOTICE, "Background work completed successfully");
    } else {
        serverLog(LL_WARNING, "Child exited with error: %d", exitcode);
    }
}
```

## Fork Exclusivity - BGSAVE and BGREWRITEAOF

Valkey allows only one concurrent fork at a time. Module forks, RDB saves (`BGSAVE`), AOF rewrites (`BGREWRITEAOF`), and slot migrations are all mutually exclusive child types. The exclusivity check is in `serverFork()`:

```c
/* From src/server.c */
int isMutuallyExclusiveChildType(int type) {
    return type == CHILD_TYPE_RDB ||
           type == CHILD_TYPE_AOF ||
           type == CHILD_TYPE_MODULE ||
           type == CHILD_TYPE_SLOT_MIGRATION;
}
```

If `hasActiveChildProcess()` returns true when a module calls `ValkeyModule_Fork`, the fork fails with `-1`. This means:

- A module fork blocks `BGSAVE` and `BGREWRITEAOF` for its duration
- A running `BGSAVE` or `BGREWRITEAOF` blocks module forks
- Two modules cannot fork concurrently

Design long-running module forks carefully. If the module fork runs for minutes, RDB and AOF persistence are delayed for that entire period. For very long operations, consider breaking the work into shorter fork sessions or using threads instead.

## Feature Detection

The fork API may not be available in all builds. Use `RMAPI_FUNC_SUPPORTED` before calling:

```c
if (!RMAPI_FUNC_SUPPORTED(ValkeyModule_Fork)) {
    ValkeyModule_ReplyWithError(ctx,
        "ERR fork API not supported in this version");
    return VALKEYMODULE_OK;
}
```

## Complete Pattern

A module that forks, does work in the child with heartbeat reporting, and handles completion in the parent:

```c
#include "valkeymodule.h"
#include <unistd.h>

static int child_pid = -1;
static int last_exit_code = -1;

void on_fork_done(int exitcode, int bysignal, void *user_data) {
    child_pid = -1;
    last_exit_code = exitcode;
    (void)bysignal;
    (void)user_data;
}

int MyForkCmd(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 2) return ValkeyModule_WrongArity(ctx);

    if (!RMAPI_FUNC_SUPPORTED(ValkeyModule_Fork)) {
        return ValkeyModule_ReplyWithError(ctx, "ERR fork not supported");
    }

    last_exit_code = -1;
    int pid = ValkeyModule_Fork(on_fork_done, NULL);

    if (pid < 0) {
        return ValkeyModule_ReplyWithError(ctx, "ERR fork failed");
    } else if (pid > 0) {
        /* Parent - save PID and reply */
        child_pid = pid;
        return ValkeyModule_ReplyWithLongLong(ctx, pid);
    }

    /* Child process */
    ValkeyModule_Log(ctx, "notice", "child started");
    int total = 10000;
    for (int i = 0; i < total; i++) {
        /* ... do work ... */
        if (i % 500 == 0) {
            ValkeyModule_SendChildHeartbeat((double)i / total);
        }
    }
    ValkeyModule_SendChildHeartbeat(1.0);
    ValkeyModule_Log(ctx, "notice", "child done");
    ValkeyModule_ExitFromChild(0);
    return 0; /* unreachable */
}

int MyKillCmd(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (child_pid == -1) {
        return ValkeyModule_ReplyWithError(ctx, "ERR no active child");
    }
    if (ValkeyModule_KillForkChild(child_pid) != VALKEYMODULE_OK) {
        return ValkeyModule_ReplyWithError(ctx, "ERR kill failed");
    }
    child_pid = -1;
    return ValkeyModule_ReplyWithSimpleString(ctx, "OK");
}
```

## Error Conditions

| Condition | Behavior |
|-----------|----------|
| Another child process is active (BGSAVE, BGREWRITEAOF, module fork, slot migration) | `ValkeyModule_Fork` returns -1, `errno` set to `EALREADY` |
| System `fork()` fails (out of memory, process limit) | `ValkeyModule_Fork` returns -1, `errno` set by OS |
| `KillForkChild` called with wrong PID | Returns `VALKEYMODULE_ERR`, no action taken |
| `KillForkChild` called when no module child is active | Returns `VALKEYMODULE_ERR`, no action taken |
| Child calls `exit()` instead of `ExitFromChild` | COW stats not reported, done handler still fires but stats are incomplete |
| `SendChildHeartbeat` called from parent | Sends incorrect data through the info pipe - call only from the child |

## See Also

- [threading.md](threading.md) - Thread-based background processing (alternative to fork)
- [info-callbacks.md](info-callbacks.md) - Fork heartbeat progress visible in INFO persistence
- [../events/server-events.md](../events/server-events.md) - Server event subscriptions for monitoring fork lifecycle
- [../data-types/rdb-callbacks.md](../data-types/rdb-callbacks.md) - RDB persistence callbacks that also use the fork mechanism
