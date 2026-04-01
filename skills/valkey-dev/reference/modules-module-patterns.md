# Module Patterns and Utilities

Use when looking up module error handling conventions, memory management (auto-memory, pool allocator, tracked allocator), API versioning, backward compatibility with Redis modules, reply helpers, or a complete module example.

Source: `src/valkeymodule.h`, `src/module.c`

## Contents

- Return Values and Error Handling (line 17)
- Memory Management (line 36)
- API Versioning (line 66)
- Backward Compatibility with Redis Modules (line 89)
- Minimal Complete Module Example (line 97)
- Reply Helpers (line 147)

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

- [module-lifecycle](module-lifecycle.md) - module load/unload, command registration, context object
- [custom-types](custom-types.md) - custom data types, RDB callbacks
- [key-api-and-blocking](key-api-and-blocking.md) - key access API, blocking commands
