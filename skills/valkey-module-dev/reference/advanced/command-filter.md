# Command Filter API - Intercept and Modify Commands

Use when building modules that intercept, inspect, or modify commands before execution - including command rewriting, argument injection, or transparent command routing.

Source: `src/module.c` (lines 11200-11453), `src/valkeymodule.h`

## Contents

- [Overview](#overview)
- [RegisterCommandFilter](#registercommandfilter)
- [UnregisterCommandFilter](#unregistercommandfilter)
- [Inspecting Arguments](#inspecting-arguments)
- [Modifying Arguments](#modifying-arguments)
- [Filter Flags](#filter-flags)
- [Patterns and Examples](#patterns-and-examples)

---

## Overview

Command filters execute before the server processes any command. This includes:

1. Direct client invocations
2. `ValkeyModule_Call()` from any module
3. Lua `server.call()`
4. Replicated commands from a primary

Filters run in a limited context - standard module APIs like `ValkeyModule_Call()`, `ValkeyModule_OpenKey()`, and `ValkeyModule_Reply*()` are not available within a filter callback. Filters must be efficient since they affect every command.

If multiple filters are registered (by the same or different modules), they execute in registration order.

## RegisterCommandFilter

```c
ValkeyModuleCommandFilter *ValkeyModule_RegisterCommandFilter(
    ValkeyModuleCtx *ctx,
    ValkeyModuleCommandFilterFunc callback,
    int flags);
```

Registers a filter callback. The callback signature:

```c
void my_filter(ValkeyModuleCommandFilterCtx *fctx);
```

The returned `ValkeyModuleCommandFilter` pointer is used to unregister the filter later.

```c
ValkeyModuleCommandFilter *filter;

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    /* ... init ... */
    filter = ValkeyModule_RegisterCommandFilter(ctx, my_filter,
                 VALKEYMODULE_CMDFILTER_NOSELF);
    return VALKEYMODULE_OK;
}
```

## UnregisterCommandFilter

```c
int ValkeyModule_UnregisterCommandFilter(ValkeyModuleCtx *ctx,
                                         ValkeyModuleCommandFilter *filter);
```

Removes a previously registered filter. A module can only unregister its own filters. Returns `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` if the filter does not belong to the calling module or was not found.

## Inspecting Arguments

```c
int ValkeyModule_CommandFilterArgsCount(ValkeyModuleCommandFilterCtx *fctx);
```

Returns the total argument count including the command name at position 0.

```c
ValkeyModuleString *ValkeyModule_CommandFilterArgGet(
    ValkeyModuleCommandFilterCtx *fctx, int pos);
```

Returns the argument at `pos` (0 = command name). Returns NULL if `pos` is out of range.

```c
unsigned long long ValkeyModule_CommandFilterGetClientId(
    ValkeyModuleCommandFilterCtx *fctx);
```

Returns the client ID of the client that issued the filtered command.

```c
void my_filter(ValkeyModuleCommandFilterCtx *fctx) {
    int argc = ValkeyModule_CommandFilterArgsCount(fctx);
    ValkeyModuleString *cmd = ValkeyModule_CommandFilterArgGet(fctx, 0);
    const char *cmdname = ValkeyModule_StringPtrLen(cmd, NULL);

    if (strcasecmp(cmdname, "SET") == 0 && argc >= 2) {
        ValkeyModuleString *key = ValkeyModule_CommandFilterArgGet(fctx, 1);
        /* Inspect the key being SET */
    }
}
```

## Modifying Arguments

```c
int ValkeyModule_CommandFilterArgInsert(ValkeyModuleCommandFilterCtx *fctx,
                                       int pos,
                                       ValkeyModuleString *arg);
```

Insert a new argument at position `pos`, shifting existing arguments. Returns `VALKEYMODULE_OK` or `VALKEYMODULE_ERR` if pos is out of range.

```c
int ValkeyModule_CommandFilterArgReplace(ValkeyModuleCommandFilterCtx *fctx,
                                        int pos,
                                        ValkeyModuleString *arg);
```

Replace the argument at position `pos`. The old argument is freed. Returns `VALKEYMODULE_OK` or `VALKEYMODULE_ERR` if pos is out of range.

```c
int ValkeyModule_CommandFilterArgDelete(ValkeyModuleCommandFilterCtx *fctx,
                                       int pos);
```

Delete the argument at position `pos`, shifting remaining arguments. The deleted argument is freed. Returns `VALKEYMODULE_OK` or `VALKEYMODULE_ERR` if pos is out of range.

Important: strings passed to `ArgInsert` and `ArgReplace` may be retained by the server after the filter returns. They must not be auto-memory managed, must not be freed by the module, and must not be used elsewhere after the call.

## Filter Flags

| Flag | Value | Description |
|------|-------|-------------|
| `VALKEYMODULE_CMDFILTER_NOSELF` | `(1 << 0)` | Skip this filter for calls originating from the registering module's own `ValkeyModule_Call()` |

The `NOSELF` flag prevents infinite recursion when a module's filter rewrites commands and the module itself calls commands. It applies to all execution flows originating from the module's command context or associated blocking command context. Detached thread-safe contexts are not covered by this flag.

## Patterns and Examples

**Command rewriting** - redirect SET to a module command for specific key patterns:

```c
void set_interceptor(ValkeyModuleCommandFilterCtx *fctx) {
    ValkeyModuleString *cmd = ValkeyModule_CommandFilterArgGet(fctx, 0);
    const char *name = ValkeyModule_StringPtrLen(cmd, NULL);

    if (strcasecmp(name, "SET") != 0) return;
    if (ValkeyModule_CommandFilterArgsCount(fctx) < 2) return;

    ValkeyModuleString *key = ValkeyModule_CommandFilterArgGet(fctx, 1);
    size_t klen;
    const char *kstr = ValkeyModule_StringPtrLen(key, &klen);

    /* Intercept keys with "tracked:" prefix */
    if (klen > 8 && strncmp(kstr, "tracked:", 8) == 0) {
        ValkeyModuleString *newcmd =
            ValkeyModule_CreateString(NULL, "MYMOD.SET", 9);
        ValkeyModule_CommandFilterArgReplace(fctx, 0, newcmd);
    }
}
```

**Argument injection** - add a default TTL to SET commands missing one:

```c
void ttl_enforcer(ValkeyModuleCommandFilterCtx *fctx) {
    ValkeyModuleString *cmd = ValkeyModule_CommandFilterArgGet(fctx, 0);
    const char *name = ValkeyModule_StringPtrLen(cmd, NULL);

    if (strcasecmp(name, "SET") != 0) return;
    int argc = ValkeyModule_CommandFilterArgsCount(fctx);

    /* If SET key value (no extra args), add EX 3600 */
    if (argc == 3) {
        ValkeyModuleString *ex = ValkeyModule_CreateString(NULL, "EX", 2);
        ValkeyModuleString *ttl = ValkeyModule_CreateString(NULL, "3600", 4);
        ValkeyModule_CommandFilterArgInsert(fctx, 3, ex);
        ValkeyModule_CommandFilterArgInsert(fctx, 4, ttl);
    }
}
```

**Audit logging** - use `CommandFilterGetClientId` to track which client issued a command without modifying it.
