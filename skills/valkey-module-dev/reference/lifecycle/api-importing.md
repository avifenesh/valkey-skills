# API Importing - ExportSharedAPI, GetSharedAPI, and Cross-Module Communication

Use when sharing functions between modules, implementing inter-module dependencies, or building modular architectures where one module provides APIs consumed by others.

Source: `src/module.c` (lines 100-108, 11062-11175)

## Contents

- Overview (line 20)
- ExportSharedAPI (line 35)
- GetSharedAPI (line 75)
- Dependency Tracking (line 100)
- Lazy Resolution Pattern (line 113)
- Unload Behavior (line 147)
- Complete Example (line 157)
- See Also (line 220)

---

## Overview

The shared API system lets modules export function pointers by name and other modules import them at runtime. This enables a plugin-of-plugins architecture where, for example, a core module provides utility functions consumed by extension modules.

The internal representation is stored in `server.sharedapi`, a dictionary mapping API name strings to `ValkeyModuleSharedAPI` structs:

```c
struct ValkeyModuleSharedAPI {
    void *func;
    ValkeyModule *module;
};
```

Source: `src/module.c` (lines 100-108)

## ExportSharedAPI

```c
int ValkeyModule_ExportSharedAPI(ValkeyModuleCtx *ctx,
                                const char *apiname,
                                void *func);
```

Registers a function pointer under the given name for other modules to discover.

| Parameter | Description |
|-----------|-------------|
| `ctx` | Module context |
| `apiname` | String literal with static lifetime - the server stores the pointer directly |
| `func` | Function pointer to export |

Returns `VALKEYMODULE_OK` if the name was registered, or `VALKEYMODULE_ERR` if the name is already taken by another module.

The `apiname` argument must be a string literal or have static lifetime. The server does not copy the string - it stores the pointer as-is and assumes it remains valid for the module's lifetime.

```c
/* In provider module */
int MySharedFunction(int x, int y) {
    return x + y;
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx,
                        ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "provider", 1,
                          VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    if (ValkeyModule_ExportSharedAPI(ctx, "provider.add",
                                    MySharedFunction) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    return VALKEYMODULE_OK;
}
```

## GetSharedAPI

```c
void *ValkeyModule_GetSharedAPI(ValkeyModuleCtx *ctx,
                               const char *apiname);
```

Looks up an exported API by name. Returns the function pointer if found, or NULL if the API is not available.

| Parameter | Description |
|-----------|-------------|
| `ctx` | Module context of the calling (consumer) module |
| `apiname` | Name of the API to look up |

The caller must cast the returned `void *` to the correct function pointer type. This is a private contract between the provider and consumer modules - the server does not perform type checking.

When a module successfully calls `GetSharedAPI`, the server records the dependency:

- The provider's `usedby` list gains a reference to the consumer
- The consumer's `using` list gains a reference to the provider

This dependency tracking prevents the provider from being unloaded while consumers are still active.

Source: `src/module.c` (lines 11122-11131)

## Dependency Tracking

The `ValkeyModule` struct has two lists for tracking API dependencies:

```c
list *usedby;  /* Modules using our shared APIs */
list *using;   /* Modules whose shared APIs we use */
```

When `GetSharedAPI` succeeds, the server adds cross-references between the consumer and provider modules. These references are deduplicated - calling `GetSharedAPI` multiple times for APIs from the same provider module only creates one entry.

This tracking has a direct impact on unloading: if a provider module's `usedby` list is non-empty, `MODULE UNLOAD` returns the error "the module exports APIs used by other modules. Please unload them first and try again."

## Lazy Resolution Pattern

Because modules can be loaded in any order, the recommended pattern is lazy resolution - attempt to resolve APIs at command execution time rather than at load time:

```c
/* In consumer module */
typedef int (*AddFunc)(int, int);
static AddFunc myAddFunc = NULL;

static int resolveAPIs(ValkeyModuleCtx *ctx) {
    static int resolved = 0;
    if (resolved) return 1;

    myAddFunc = (AddFunc)ValkeyModule_GetSharedAPI(ctx, "provider.add");
    if (myAddFunc == NULL) return 0;

    resolved = 1;
    return 1;
}

int MyCommand(ValkeyModuleCtx *ctx,
              ValkeyModuleString **argv, int argc) {
    if (!resolveAPIs(ctx)) {
        return ValkeyModule_ReplyWithError(ctx,
            "ERR required module 'provider' is not loaded");
    }

    int result = myAddFunc(3, 4);
    return ValkeyModule_ReplyWithLongLong(ctx, result);
}
```

This pattern handles the case where the provider module is loaded after the consumer. Each command invocation checks once and caches the result.

## Unload Behavior

When a module is unloaded, two cleanup functions run:

`moduleUnregisterSharedAPI(module)` - removes all APIs exported by the module from `server.sharedapi`. Returns the count of unregistered APIs. Source: `src/module.c` (lines 11139-11154).

`moduleUnregisterUsedAPI(module)` - removes the module from the `usedby` list of every provider module whose APIs it was consuming. Returns the count of provider modules. Source: `src/module.c` (lines 11160-11175).

Important: the server does not notify consumer modules when a provider is unloaded. If a consumer cached a function pointer from `GetSharedAPI`, that pointer becomes dangling after the provider unloads. The dependency tracking prevents this scenario by blocking the provider's unload, but if dependencies are forcibly broken, the consumer should handle NULL checks.

## Complete Example

Provider module (`provider.c`):

```c
#include "valkeymodule.h"

/* Shared function */
long long MyCounter_Increment(long long *counter) {
    return ++(*counter);
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx,
                        ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "provider", 1,
                          VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    if (ValkeyModule_ExportSharedAPI(ctx, "provider.counter_incr",
                                    MyCounter_Increment) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    return VALKEYMODULE_OK;
}
```

Consumer module (`consumer.c`):

```c
#include "valkeymodule.h"

typedef long long (*IncrFunc)(long long *);
static IncrFunc counterIncr = NULL;
static long long myCounter = 0;

int IncrCommand(ValkeyModuleCtx *ctx,
                ValkeyModuleString **argv, int argc) {
    if (!counterIncr) {
        counterIncr = (IncrFunc)ValkeyModule_GetSharedAPI(
            ctx, "provider.counter_incr");
        if (!counterIncr) {
            return ValkeyModule_ReplyWithError(ctx,
                "ERR provider module not loaded");
        }
    }
    long long val = counterIncr(&myCounter);
    return ValkeyModule_ReplyWithLongLong(ctx, val);
}

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx,
                        ValkeyModuleString **argv, int argc) {
    if (ValkeyModule_Init(ctx, "consumer", 1,
                          VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    if (ValkeyModule_CreateCommand(ctx, "consumer.incr",
            IncrCommand, "fast", 0, 0, 0) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    return VALKEYMODULE_OK;
}
```

## See Also

- [module-loading.md](module-loading.md) - Module load order and unload constraints
- [context.md](context.md) - ValkeyModuleCtx needed for GetSharedAPI
- [memory.md](memory.md) - Allocation for shared data structures across modules
- [../commands/registration.md](../commands/registration.md) - Creating commands that use shared APIs
- [../events/server-events.md](../events/server-events.md) - MODULE_CHANGE event to detect provider load/unload
- [../testing.md](../testing.md) - Testing multi-module dependencies
