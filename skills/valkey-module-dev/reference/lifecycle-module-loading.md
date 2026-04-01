# Module Loading - OnLoad, Initialization, and MODULE Commands

Use when creating a new module, understanding how the server discovers and loads modules, implementing ValkeyModule_OnLoad, or using MODULE LOAD/UNLOAD/LIST commands.

Source: `src/module.c` (lines 12821-13096), `src/valkeymodule.h` (lines 2213-2312)

## Contents

- Entry Point (line 21)
- ValkeyModule_Init (line 45)
- ValkeyModule Struct (line 67)
- MODULE LOAD (line 98)
- MODULE LOADEX (line 108)
- Unloading (line 118)
- MODULE LIST (line 140)
- Minimal Example (line 155)

---

## Entry Point

The server loads a module as a shared library via `dlopen()`. It searches for the entry point by name, trying `ValkeyModule_OnLoad` first, then the legacy `RedisModule_OnLoad`:

```c
int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx,
                        ValkeyModuleString **argv,
                        int argc);
```

The server calls this function with a context, module arguments from the config or command, and the argument count. Return `VALKEYMODULE_OK` on success or `VALKEYMODULE_ERR` to abort loading.

The dlopen flags include `RTLD_NOW | RTLD_LOCAL`, plus `RTLD_DEEPBIND` on glibc-based systems and FreeBSD (excluding sanitizer builds) to isolate module symbols.

Before calling `OnLoad`, the server verifies that the module file has execute permissions (`S_IXUSR | S_IXGRP | S_IXOTH`). Modules without execute permissions are rejected.

Optional unload hook - return `VALKEYMODULE_ERR` to prevent unloading:

```c
int ValkeyModule_OnUnload(ValkeyModuleCtx *ctx);
```

The legacy name `RedisModule_OnUnload` is also accepted.

## ValkeyModule_Init

Every `OnLoad` must call `ValkeyModule_Init` as its first action. This is a static function defined in `valkeymodule.h` that resolves all API function pointers:

```c
static int ValkeyModule_Init(ValkeyModuleCtx *ctx,
                             const char *name,
                             int ver,
                             int apiver);
```

| Parameter | Description |
|-----------|-------------|
| `ctx` | The context received in OnLoad |
| `name` | Module name - must be unique across all loaded modules |
| `ver` | Module version - your own versioning scheme (progressive integer) |
| `apiver` | Must be `VALKEYMODULE_APIVER_1` (value: 1) |

`ValkeyModule_Init` works by extracting the `GetApi` function pointer from the first field of the context struct. It then calls `VALKEYMODULE_GET_API` for every API function (Alloc, Free, CreateCommand, OpenKey, etc.), resolving each into a global function pointer the module can call.

If the module name is already in use, `ValkeyModule_Init` returns `VALKEYMODULE_ERR` and the module fails to load.

## ValkeyModule Struct

After `ValkeyModule_Init` succeeds, the server allocates the internal `ValkeyModule` struct:

```c
typedef struct ValkeyModule {
    void *handle;        /* dlopen() handle */
    char *name;          /* Module name (SDS) */
    int ver;             /* Module version */
    int apiver;          /* API version */
    list *types;         /* Registered data types */
    list *usedby;        /* Modules using our shared APIs */
    list *using;         /* Modules whose shared APIs we use */
    list *filters;       /* Registered command filters */
    list *module_configs; /* Registered configurations */
    int configs_initialized;
    int in_call;         /* VM_Call() nesting level */
    int in_hook;         /* Hook callback nesting (0 or 1) */
    int options;         /* Module options bitmask */
    int blocked_clients; /* Count of blocked clients */
    ValkeyModuleInfoFunc info_cb;
    ValkeyModuleDefragFunc defrag_cb;
    struct moduleLoadQueueEntry *loadmod;
    int num_commands_with_acl_categories;
    int onload;          /* 1 during OnLoad, 0 after */
    size_t num_acl_categories_added;
} ValkeyModule;
```

Source: `src/module.h` (lines 99-120)

## MODULE LOAD

```
MODULE LOAD <path> [<arg> ...]
```

Loads a module from the specified shared library path. Additional arguments are passed to `ValkeyModule_OnLoad` as `argv`/`argc`. The server calls `moduleLoad()` internally, which performs the full sequence: permission check, dlopen, symbol lookup, OnLoad call, and registration.

At startup, modules listed in the config file via `loadmodule` are queued and loaded during server initialization through the same code path.

## MODULE LOADEX

```
MODULE LOADEX <path> [CONFIG name value ...] [ARGS ...]
```

Extended load command that supports passing module configuration parameters. The CONFIG pairs are parsed and placed in `server.module_configs_queue` before calling `OnLoad`. The module must call `ValkeyModule_LoadConfigs()` inside `OnLoad` to apply them.

If the module registers configurations but fails to call `ValkeyModule_LoadConfigs`, the server unloads the module with an error: "Module Configurations were not set, likely a missing LoadConfigs call."

## Unloading

`MODULE UNLOAD <name>` triggers `moduleUnloadInternal()`. The server blocks unloading if any of these conditions hold:

| Condition | Error Message |
|-----------|---------------|
| Module exports data types | "the module exports one or more module-side data types, can't unload" |
| Other modules use its shared APIs | "the module exports APIs used by other modules. Please unload them first and try again" |
| Module has blocked clients | "the module has blocked clients. Please wait for them to be unblocked and try again" |
| Module holds active timers | "the module holds timer that is not fired. Please stop the timer or wait until it fires." |
| ACL rules reference module commands | "one or more ACL users reference commands from this module. Remove those ACL rules before unloading" |

If none of these conditions apply, the server calls `ValkeyModule_OnUnload` (if exported). If `OnUnload` returns `VALKEYMODULE_ERR`, unloading is canceled.

On successful unload, the server:

1. Calls `moduleUnregisterCleanup()` - removes commands, notifications, shared APIs (both exported and consumed), filters, configs, auth callbacks, authenticated clients cleanup, and server event subscriptions
2. Calls `dlclose()` on the module handle
3. Fires `VALKEYMODULE_EVENT_MODULE_CHANGE` with `VALKEYMODULE_SUBEVENT_MODULE_UNLOADED`
4. Removes the module from the global `modules` dictionary
5. Frees the `ValkeyModule` struct

## MODULE LIST

```
MODULE LIST
```

Returns an array of loaded modules. Each entry is a map with four fields:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Module name |
| `ver` | integer | Module version |
| `path` | string | File path the module was loaded from |
| `args` | array | Arguments passed at load time |

## Minimal Example

```c
#include "valkeymodule.h"

int HelloCommand(ValkeyModuleCtx *ctx,
                 ValkeyModuleString **argv, int argc) {
    ValkeyModule_ReplyWithSimpleString(ctx, "Hello, World!");
    return VALKEYMODULE_OK;
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx,
                        ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "helloworld", 1,
                          VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    if (ValkeyModule_CreateCommand(ctx, "hello.world",
            HelloCommand, "fast", 0, 0, 0) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    return VALKEYMODULE_OK;
}
```
