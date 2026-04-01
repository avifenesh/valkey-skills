# Module Options - SetModuleOptions Flags and Behavior

Use when configuring module capabilities like IO error handling, diskless replication awareness, implicit signal control, nested notifications, command validation, or atomic slot migration.

Source: `src/module.c` (lines 2589-2643), `src/valkeymodule.h` (lines 320-348)

## Contents

- SetModuleOptions (line 22)
- Option Flags (line 39)
- HANDLE_IO_ERRORS (line 53)
- NO_IMPLICIT_SIGNAL_MODIFIED (line 84)
- HANDLE_REPL_ASYNC_LOAD (line 110)
- ALLOW_NESTED_KEYSPACE_NOTIFICATIONS (line 126)
- SKIP_COMMAND_VALIDATION (line 149)
- HANDLE_ATOMIC_SLOT_MIGRATION (line 159)
- GetModuleOptionsAll (line 169)
- See Also (line 188)

---

## SetModuleOptions

```c
void ValkeyModule_SetModuleOptions(ValkeyModuleCtx *ctx, int options);
```

Sets capability flags for the module. Call during `ValkeyModule_OnLoad` after `ValkeyModule_Init`. The `options` parameter is a bitmask of `VALKEYMODULE_OPTIONS_*` and `VALKEYMODULE_OPTION_*` flags.

This function directly assigns `ctx->module->options = options`, so each call replaces the previous value rather than merging. Combine flags with bitwise OR:

```c
ValkeyModule_SetModuleOptions(ctx,
    VALKEYMODULE_OPTIONS_HANDLE_IO_ERRORS |
    VALKEYMODULE_OPTIONS_HANDLE_REPL_ASYNC_LOAD);
```

## Option Flags

All flags are defined in `src/valkeymodule.h` (lines 320-348):

| Flag | Value | Purpose |
|------|-------|---------|
| `VALKEYMODULE_OPTIONS_HANDLE_IO_ERRORS` | `1 << 0` | Module handles RDB read errors |
| `VALKEYMODULE_OPTION_NO_IMPLICIT_SIGNAL_MODIFIED` | `1 << 1` | Disable auto key-modified signaling |
| `VALKEYMODULE_OPTIONS_HANDLE_REPL_ASYNC_LOAD` | `1 << 2` | Module handles diskless async replication |
| `VALKEYMODULE_OPTIONS_ALLOW_NESTED_KEYSPACE_NOTIFICATIONS` | `1 << 3` | Allow nested keyspace notifications |
| `VALKEYMODULE_OPTIONS_SKIP_COMMAND_VALIDATION` | `1 << 4` | Skip command validation in Replicate/EmitAOF |
| `VALKEYMODULE_OPTIONS_HANDLE_ATOMIC_SLOT_MIGRATION` | `1 << 5` | Module supports atomic slot migration |

The sentinel `_VALKEYMODULE_OPTIONS_FLAGS_NEXT` is `1 << 6`.

## HANDLE_IO_ERRORS

```c
#define VALKEYMODULE_OPTIONS_HANDLE_IO_ERRORS (1 << 0)
```

Enables `repl-diskless-load` to work with module data types. Without this flag, the server process terminates if a read error occurs during RDB loading.

When set, the module must:

1. Call `ValkeyModule_IsIOError(io)` after each read operation in `rdb_load`
2. Handle the error case by propagating it upward (return early)
3. Be able to release any partially populated value and its allocations

```c
void *MyType_RdbLoad(ValkeyModuleIO *io, int encver) {
    MyObj *obj = ValkeyModule_Alloc(sizeof(*obj));
    obj->value = ValkeyModule_LoadSigned(io);
    if (ValkeyModule_IsIOError(io)) {
        ValkeyModule_Free(obj);
        return NULL;
    }
    obj->name = ValkeyModule_LoadString(io);
    if (ValkeyModule_IsIOError(io)) {
        ValkeyModule_Free(obj);
        return NULL;
    }
    return obj;
}
```

## NO_IMPLICIT_SIGNAL_MODIFIED

```c
#define VALKEYMODULE_OPTION_NO_IMPLICIT_SIGNAL_MODIFIED (1 << 1)
```

By default, when a key opened for writing is closed via `ValkeyModule_CloseKey()`, the server automatically calls `signalModifiedKey()` which invalidates WATCH and client-side caching for that key.

Setting this flag disables the automatic signal. The module must then manually call `ValkeyModule_SignalModifiedKey()` when a key is actually modified from the user's perspective:

```c
int ValkeyModule_SignalModifiedKey(ValkeyModuleCtx *ctx,
                                  ValkeyModuleString *keyname);
```

This is implemented via the macro (from `src/module.c` line 423):

```c
#define SHOULD_SIGNAL_MODIFIED_KEYS(ctx) \
    ((ctx)->module ? \
     !((ctx)->module->options & \
       VALKEYMODULE_OPTION_NO_IMPLICIT_SIGNAL_MODIFIED) : 1)
```

Use this option when your module opens keys for writing but does not always modify them, or when you need precise control over when WATCH invalidation occurs.

## HANDLE_REPL_ASYNC_LOAD

```c
#define VALKEYMODULE_OPTIONS_HANDLE_REPL_ASYNC_LOAD (1 << 2)
```

Indicates the module is aware of diskless async replication (`repl-diskless-load=swapdb`). In this mode, the server can serve read requests during replication instead of blocking all clients with LOADING status.

When this flag is set, the module acknowledges that:

- Its data may be temporarily unavailable during async loading
- It should check `VALKEYMODULE_CTX_FLAGS_ASYNC_LOADING` via `GetContextFlags` to detect this state
- Commands should behave appropriately during the transition period

Without this flag, the server may not enable `repl-diskless-load=swapdb` if modules with data types are loaded.

## ALLOW_NESTED_KEYSPACE_NOTIFICATIONS

```c
#define VALKEYMODULE_OPTIONS_ALLOW_NESTED_KEYSPACE_NOTIFICATIONS (1 << 3)
```

By default, the server does not fire keyspace notifications that originate inside a keyspace notification callback. This prevents infinite recursion.

Setting this flag allows the module to receive nested notifications. The module is responsible for preventing infinite recursion - for example, by tracking recursion depth or only subscribing to specific event types that cannot trigger themselves.

```c
static int notification_depth = 0;

int MyNotificationHandler(ValkeyModuleCtx *ctx, int type,
                          const char *event, ValkeyModuleString *key) {
    if (notification_depth > 0) return VALKEYMODULE_OK;
    notification_depth++;
    /* handle notification, may trigger more notifications */
    notification_depth--;
    return VALKEYMODULE_OK;
}
```

## SKIP_COMMAND_VALIDATION

```c
#define VALKEYMODULE_OPTIONS_SKIP_COMMAND_VALIDATION (1 << 4)
```

When set, the module can skip command validation checks for `ValkeyModule_Replicate()` and `ValkeyModule_EmitAOF()`. This reduces overhead in high-throughput scenarios where the commands being replicated are already pre-validated or are trusted custom command logic.

Bypassing validation means the module is responsible for ensuring replicated commands are well-formed.

## HANDLE_ATOMIC_SLOT_MIGRATION

```c
#define VALKEYMODULE_OPTIONS_HANDLE_ATOMIC_SLOT_MIGRATION (1 << 5)
```

Indicates the module can handle atomic slot migration via `CLUSTER MIGRATESLOTS`. Without this flag, `CLUSTER MIGRATESLOTS` returns an error when modules are loaded, and the older `CLUSTER SETSLOTS` based migration must be used instead.

Modules should set this flag if they understand that keys may be loaded during migration but before slot ownership is transferred. During migration, the module can check `VALKEYMODULE_CTX_FLAGS_SLOT_IMPORT_CLIENT` and `VALKEYMODULE_CTX_FLAGS_SLOT_EXPORT_CLIENT` via `GetContextFlags` to detect migration-related contexts.

## GetModuleOptionsAll

Check which option flags are supported by the running server version:

```c
int ValkeyModule_GetModuleOptionsAll(void);
```

Returns a bitmask with all supported option flags set. Value equals `_VALKEYMODULE_OPTIONS_FLAGS_NEXT - 1`.

```c
int supported = ValkeyModule_GetModuleOptionsAll();
if (supported & VALKEYMODULE_OPTIONS_HANDLE_ATOMIC_SLOT_MIGRATION) {
    /* This server version supports atomic slot migration */
    options |= VALKEYMODULE_OPTIONS_HANDLE_ATOMIC_SLOT_MIGRATION;
}
ValkeyModule_SetModuleOptions(ctx, options);
```
