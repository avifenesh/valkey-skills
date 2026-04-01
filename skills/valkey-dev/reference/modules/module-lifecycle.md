# Module Lifecycle and Command Registration

Use when building a Valkey module from scratch, understanding the module load/unload lifecycle, registering commands with flags and subcommands, or working with the ValkeyModuleCtx context object.

Source: `src/valkeymodule.h`, `src/module.c`, `src/module.h`

## Contents

- Module Lifecycle (line 18)
- Initialization: ValkeyModule_Init (line 58)
- Command Registration (line 75)
- Subcommands (line 124)
- Command Metadata (line 132)
- The Context Object: ValkeyModuleCtx (line 137)
- See Also (line 163)

---

## Module Lifecycle

A Valkey module is a shared library (`.so`) loaded via `dlopen`. The server looks for exactly one of two entry points:

```c
int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc);
```

Or the legacy name `RedisModule_OnLoad` for backward compatibility with Redis modules. The first match wins; the legacy name emits a notice-level log.

An optional unload hook lets the module clean up:

```c
int ValkeyModule_OnUnload(ValkeyModuleCtx *ctx);
```

Return `VALKEYMODULE_ERR` from `OnUnload` to prevent the module from being unloaded.

### Loading modules

```bash
# In valkey.conf
loadmodule /path/to/mymodule.so [arg1] [arg2]

# At runtime (requires enable-module-command yes)
MODULE LOAD /path/to/mymodule.so [arg1] [arg2]
MODULE LIST
MODULE UNLOAD mymodule
```

### What happens inside moduleLoad

1. `dlopen` with `RTLD_NOW | RTLD_LOCAL` (plus `RTLD_DEEPBIND` on Linux/FreeBSD outside sanitizer builds).
2. `dlsym` for `ValkeyModule_OnLoad` or `RedisModule_OnLoad`.
3. A temporary `ValkeyModuleCtx` is created and passed to the OnLoad function.
4. If OnLoad returns `VALKEYMODULE_ERR`, the module is cleaned up and `dlclose` is called.
5. On success, the module is registered in the global `modules` dict keyed by module name.

---

## Initialization: ValkeyModule_Init

Every OnLoad must call `ValkeyModule_Init` before any other API:

```c
static int ValkeyModule_Init(ValkeyModuleCtx *ctx, const char *name, int ver, int apiver);
```

Parameters:
- `name` - Module name. Must be unique across all loaded modules.
- `ver` - Module version (progressive integer, module's own scheme).
- `apiver` - API version requested. Use `VALKEYMODULE_APIVER_1`.

This function populates all API function pointers via `VALKEYMODULE_GET_API` macros. If the module name is already taken, it returns `VALKEYMODULE_ERR`.

---

## Command Registration

```c
int ValkeyModule_CreateCommand(
    ValkeyModuleCtx *ctx,
    const char *name,              // e.g. "mymodule.set"
    ValkeyModuleCmdFunc cmdfunc,   // Command handler
    const char *strflags,          // Space-separated flags
    int firstkey,                  // 1-based index of first key arg (0 = no keys)
    int lastkey,                   // 1-based index of last key arg (-1 = last arg)
    int keystep                    // Step between key args (0 = no keys)
);
```

Must be called from within `ValkeyModule_OnLoad`. Returns `VALKEYMODULE_ERR` if the command name is busy, invalid, or if called outside OnLoad.

### Command handler signature

```c
int MyCommand(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc);
```

Always returns `VALKEYMODULE_OK`. Errors are communicated via reply functions, not return values.

### Command flags

Pass as a space-separated string. Key flags from the source:

| Flag | Meaning |
|------|---------|
| `"write"` | May modify the dataset |
| `"readonly"` | Returns data but never writes |
| `"admin"` | Administrative command |
| `"deny-oom"` | Deny during out-of-memory |
| `"deny-script"` | Cannot be called from Lua scripts |
| `"allow-loading"` | Allow while server is loading data |
| `"pubsub"` | Publishes on Pub/Sub channels |
| `"fast"` | Time complexity at most O(log N) |
| `"getkeys-api"` | Module implements getkeys interface |
| `"no-cluster"` | Not designed for cluster mode |
| `"no-auth"` | Can run without authentication |
| `"may-replicate"` | May generate replication traffic |
| `"no-mandatory-keys"` | All keys are optional |
| `"blocking"` | May block the client |
| `"allow-busy"` | Permit while server is blocked by script/module |
| `"allow-stale"` | Allowed on replicas with stale data |
| `"no-monitor"` | Exclude from MONITOR output |
| `"no-commandlog"` | Exclude from command log |

## Subcommands

```c
ValkeyModuleCommand *parent = ValkeyModule_GetCommand(ctx, "mymodule.cmd");
ValkeyModule_CreateSubcommand(parent, "sub", SubCmdFunc, "readonly", 1, 1, 1);
```

## Command Metadata

Use `ValkeyModule_SetCommandInfo` for rich command documentation (summary, complexity, history, key specs, argument definitions). Use `ValkeyModule_SetCommandACLCategories` to assign ACL categories.

## The Context Object: ValkeyModuleCtx

Every API call receives a `ValkeyModuleCtx *ctx`. It holds:

- Reference to the calling module
- The client connection executing the command
- Auto-memory tracking queue
- Postponed reply arrays
- Pool allocator state
- Blocked client handle (for thread-safe contexts)

Key context flags (query with `ValkeyModule_GetContextFlags`):

| Flag | Meaning |
|------|---------|
| `VALKEYMODULE_CTX_FLAGS_LUA` | Running inside Lua script |
| `VALKEYMODULE_CTX_FLAGS_MULTI` | Inside a MULTI transaction |
| `VALKEYMODULE_CTX_FLAGS_PRIMARY` | Instance is a primary |
| `VALKEYMODULE_CTX_FLAGS_REPLICA` | Instance is a replica |
| `VALKEYMODULE_CTX_FLAGS_CLUSTER` | Cluster mode is enabled |
| `VALKEYMODULE_CTX_FLAGS_OOM` | Server is out of memory |
| `VALKEYMODULE_CTX_FLAGS_LOADING` | Server is loading data |
| `VALKEYMODULE_CTX_FLAGS_RESP3` | Client uses RESP3 protocol |

---

## See Also

- [module-patterns](module-patterns.md) - error handling, memory management, versioning, complete example, reply helpers
- [custom-types](custom-types.md) - custom data types, RDB callbacks
- [key-api-and-blocking](key-api-and-blocking.md) - key access API, blocking commands
