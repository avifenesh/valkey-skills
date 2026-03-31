# Module API Overview

Use when building a Valkey module from scratch, understanding the module lifecycle, or looking up the core API conventions for command registration, context handling, and error codes.

Source: `src/valkeymodule.h`, `src/module.c`, `src/module.h`

## Contents

- Module Lifecycle (line 23)
- Initialization: ValkeyModule_Init (line 63)
- Command Registration (line 80)
- The Context Object: ValkeyModuleCtx (line 142)
- Return Values and Error Handling (line 168)
- Memory Management (line 188)
- API Versioning (line 217)
- Backward Compatibility with Redis Modules (line 240)
- Minimal Complete Module Example (line 248)
- Reply Helpers (line 298)
- See Also (line 321)

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

### Subcommands

```c
ValkeyModuleCommand *parent = ValkeyModule_GetCommand(ctx, "mymodule.cmd");
ValkeyModule_CreateSubcommand(parent, "sub", SubCmdFunc, "readonly", 1, 1, 1);
```

### Command metadata

Use `ValkeyModule_SetCommandInfo` for rich command documentation (summary, complexity, history, key specs, argument definitions). Use `ValkeyModule_SetCommandACLCategories` to assign ACL categories.

---

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

## Return Values and Error Handling

All API functions use two status codes:

```c
#define VALKEYMODULE_OK  0
#define VALKEYMODULE_ERR 1
```

Errors to clients are sent via reply functions, not C return values:

```c
ValkeyModule_ReplyWithError(ctx, "ERR something went wrong");
ValkeyModule_ReplyWithErrorFormat(ctx, "ERR key %s not found", keyname);
```

The `VALKEYMODULE_ERRORMSG_WRONGTYPE` constant provides the standard WRONGTYPE error message.

---

## Memory Management

### Auto-memory mode

```c
ValkeyModule_AutoMemory(ctx);
```

When enabled, strings and keys opened during the command are automatically freed when the command returns. Without it, the module must call `ValkeyModule_FreeString` and `ValkeyModule_CloseKey` manually.

### Pool allocator

```c
void *ptr = ValkeyModule_PoolAlloc(ctx, bytes);
```

Fast bump allocator for ephemeral allocations - automatically freed when the callback returns. Minimum block size is 8 KB; allocations are pointer-aligned.

### Module allocator

For persistent allocations, use the tracked allocator:
- `ValkeyModule_Alloc`, `ValkeyModule_Calloc`, `ValkeyModule_Realloc`
- `ValkeyModule_Free`, `ValkeyModule_Strdup`
- `ValkeyModule_TryAlloc`, `ValkeyModule_TryCalloc`, `ValkeyModule_TryRealloc` (return NULL on failure instead of aborting)

These route through the server's `zmalloc` so memory is tracked in INFO output.

---

## API Versioning

The API version is declared at init:

```c
#define VALKEYMODULE_APIVER_1 1
```

The `ValkeyModuleTypeMethods` struct has its own version:

```c
#define VALKEYMODULE_TYPE_METHOD_VERSION 5
```

This allows backward-compatible additions to the type methods struct (v2 added aux_load/save, v3 added free_effort/unlink/copy/defrag, v4 added the "2" variants with `ValkeyModuleKeyOptCtx`, v5 added `aux_save2`).

Runtime version checks:
- `ValkeyModule_GetServerVersion()` - Server version
- `ValkeyModule_GetTypeMethodVersion()` - Current type method version
- `RMAPI_FUNC_SUPPORTED(func)` - Check if a specific API function is available

---

## Backward Compatibility with Redis Modules

The `redismodule.h` header maps all `REDISMODULE_*` constants and `RedisModule_*` functions to their `VALKEYMODULE_*`/`ValkeyModule_*` equivalents. This is a snapshot of the Redis 7.2.4 interface. Existing Redis modules compile without source changes by including `redismodule.h` instead of `valkeymodule.h`.

Terminology changes: `master` -> `primary`, `slave` -> `replica`.

---

## Minimal Complete Module Example

```c
#include "valkeymodule.h"
#include <string.h>

int HelloCommand(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (argc != 2) return ValkeyModule_WrongArity(ctx);

    ValkeyModule_AutoMemory(ctx);

    size_t len;
    const char *name = ValkeyModule_StringPtrLen(argv[1], &len);

    ValkeyModuleString *reply = ValkeyModule_CreateStringPrintf(ctx, "Hello, %s!", name);
    ValkeyModule_ReplyWithString(ctx, reply);

    return VALKEYMODULE_OK;
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "helloworld", 1, VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    if (ValkeyModule_CreateCommand(ctx, "hello.greet", HelloCommand,
            "readonly fast", 0, 0, 0) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    return VALKEYMODULE_OK;
}
```

Build with:
```bash
gcc -shared -fPIC -o helloworld.so helloworld.c -I /path/to/valkey/src
```

Load with:
```
MODULE LOAD /path/to/helloworld.so
```

Test:
```
> hello.greet World
"Hello, World!"
```

---

## Reply Helpers

| Function | Reply type |
|----------|-----------|
| `ReplyWithLongLong` | Integer |
| `ReplyWithDouble` | Double |
| `ReplyWithSimpleString` | Status string |
| `ReplyWithStringBuffer` | Bulk string (binary-safe) |
| `ReplyWithCString` | Bulk string (null-terminated) |
| `ReplyWithString` | Bulk string (ValkeyModuleString) |
| `ReplyWithError` | Error |
| `ReplyWithNull` | Null |
| `ReplyWithBool` | Boolean (RESP3) |
| `ReplyWithArray` | Array header |
| `ReplyWithMap` | Map header (RESP3) |
| `ReplyWithSet` | Set header (RESP3) |
| `ReplyWithBigNumber` | Big number (RESP3) |
| `ReplyWithVerbatimString` | Verbatim string (RESP3) |

For dynamic-length arrays, pass `VALKEYMODULE_POSTPONED_LEN` to `ReplyWithArray` and call `ReplySetArrayLength` when the count is known.

---

## See Also

- [Custom Types and Advanced Commands](../modules/types-and-commands.md) - RDB persistence for custom data types, the key access API, and blocking command patterns.
- [Rust SDK for Valkey Modules](../modules/rust-sdk.md) - Safe Rust bindings over this C API via the `valkey-module` crate.
- [Scripting Engine Architecture](../scripting/scripting-engine.md) - Modules can implement scripting engines by registering via `ValkeyModule_RegisterScriptingEngine`. The engine ABI and callback interface are documented there.
- [ACL Subsystem](../security/acl.md) - Module-registered commands are subject to ACL checks. Use `ValkeyModule_SetCommandACLCategories` to assign ACL categories and the `A` flag in `ValkeyModule_Call` to enforce ACL on internal calls.
- [Keyspace Notifications](../pubsub/notifications.md) - Modules can subscribe to keyspace events via `ValkeyModule_SubscribeToKeyspaceEvents`, bypassing the `notify-keyspace-events` config.
- [Building Valkey](../build/building.md) - Build with `BUILD_TLS=module` for TLS module support. The `BUILD_LUA` flag controls the Lua scripting engine module. Module `.so` files are built with `-shared -fPIC` and loaded via `MODULE LOAD` or `loadmodule` in the config file.
