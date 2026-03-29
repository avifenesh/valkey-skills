# Scripting Engine Architecture

Use when investigating the pluggable scripting engine framework, engine registration/unregistration, how the Lua engine integrates as a module, the engine ABI versioning scheme, or the interactive debugger infrastructure.

Source files: `src/scripting_engine.c`, `src/scripting_engine.h`, `src/valkeymodule.h`

---

## Overview

Valkey's scripting system is built on a pluggable engine architecture. Instead of hardcoding Lua, the server defines an `engineMethods` interface that any Valkey module can implement. The Lua engine is itself a module that registers through this interface. The engine manager coordinates registration, lookup, and lifecycle of all engines.

This design means new scripting languages (JavaScript, Python, etc.) can be added as modules without modifying the server core.

## Subsystem Types

Engines serve two distinct subsystems, identified by `ValkeyModuleScriptingEngineSubsystemType`:

```c
typedef enum ValkeyModuleScriptingEngineSubsystemType {
    VMSE_EVAL,     /* Ad-hoc EVAL/EVALSHA scripts */
    VMSE_FUNCTION, /* FUNCTION LOAD/FCALL libraries */
    VMSE_ALL       /* Both subsystems (used for memory queries) */
} ValkeyModuleScriptingEngineSubsystemType;
```

Engines maintain separate runtime environments for EVAL and FUNCTION scripts. The `VMSE_ALL` type is used only for memory info aggregation.

## Key Data Structures

### scriptingEngine

Internal representation of a registered engine:

```c
typedef struct scriptingEngine {
    sds name;                                                 /* Engine name (e.g., "lua") */
    ValkeyModule *module;                                     /* Module that implements this engine */
    scriptingEngineImpl impl;                                 /* Callbacks and engine-specific context */
    ValkeyModuleCtx *module_ctx_cache[MODULE_CTX_CACHE_SIZE]; /* 3-element context cache */
} scriptingEngine;
```

### scriptingEngineImpl

Bundles the engine's opaque context with its method table:

```c
typedef struct scriptingEngineImpl {
    engineCtx *ctx;        /* Engine-specific context (opaque to server) */
    engineMethods methods; /* Callback function table */
} scriptingEngineImpl;
```

### engineManager

Singleton that tracks all registered engines:

```c
typedef struct engineManager {
    dict *engines;                /* Engine name (sds) -> scriptingEngine* */
    size_t total_memory_overhead; /* Sum of all engine memory overhead */
} engineManager;
```

The dictionary uses case-insensitive hashing.

### compiledFunction

The engine-produced artifact representing a compiled function:

```c
typedef struct ValkeyModuleScriptingEngineCompiledFunction {
    uint64_t version;         /* Structure version for ABI compat */
    ValkeyModuleString *name; /* Function name */
    void *function;           /* Opaque compiled code, engine-specific */
    ValkeyModuleString *desc; /* Optional description */
    uint64_t f_flags;         /* Per-function flags */
} ValkeyModuleScriptingEngineCompiledFunctionV1;
```

For EVAL, the engine returns exactly one compiled function. For FUNCTION LOAD, it returns as many as the library registers.

## Engine Methods (ABI)

The callback interface has evolved through 4 ABI versions:

| Version | Change |
|---------|--------|
| 1 | Initial: `compile_code_v1` (null-terminated code) |
| 2 | `compile_code` with explicit `code_len` for binary safety |
| 3 | `reset_eval_env_v2` renamed to `reset_env` with subsystem type parameter |
| 4 | Added debugger callbacks: `debugger_enable`, `debugger_disable`, `debugger_start`, `debugger_end` |

Current version constant: `VALKEYMODULE_SCRIPTING_ENGINE_ABI_VERSION` = 4.

### V3 Method Table (base callbacks)

```c
compile_code(module_ctx, engine_ctx, type, code, code_len, timeout,
             out_num_compiled_functions, err)
    -> compiledFunction** or NULL

free_function(module_ctx, engine_ctx, type, compiled_func)
    -> void

call_function(module_ctx, engine_ctx, server_ctx, compiled_function,
              type, keys, nkeys, args, nargs)
    -> void

get_function_memory_overhead(module_ctx, compiled_function)
    -> size_t

reset_env(module_ctx, engine_ctx, type, async)
    -> callableLazyEnvReset* or NULL

get_memory_info(module_ctx, engine_ctx, type)
    -> engineMemoryInfo
```

### V4 Additions (debugger support)

```c
debugger_enable(module_ctx, engine_ctx, type, out_commands, out_commands_len)
    -> debuggerEnableRet

debugger_disable(module_ctx, engine_ctx, type)
    -> void

debugger_start(module_ctx, engine_ctx, type, source)
    -> void

debugger_end(module_ctx, engine_ctx, type)
    -> void
```

### Backward Compatibility

`scriptingEngineInitializeEngineMethods()` handles older modules: if `methods->version < ABI_VERSION_4`, only the V3 fields are copied. Call wrappers check the version before invoking V4 callbacks and fall back gracefully. For example, `scriptingEngineCallResetEnvFunc()` calls `reset_eval_env_v2` for versions < 3 (EVAL only), and `reset_env` for version >= 3.

## Engine Registration

```c
int scriptingEngineManagerRegister(const char *engine_name,
                                   ValkeyModule *engine_module,
                                   engineCtx *engine_ctx,
                                   engineMethods *engine_methods);
```

Called by modules during load (via `ValkeyModule_RegisterScriptingEngine`). The function:

1. Rejects duplicate engine names.
2. Allocates a `scriptingEngine` struct.
3. Copies the method table with version-aware initialization.
4. Allocates 3 `ValkeyModuleCtx` objects for the module context cache.
5. Queries initial memory overhead and adds it to the global total.
6. Adds the engine to the `engineMgr.engines` dictionary.

### Module Context Cache

Three cached module contexts avoid repeated allocation during hot paths:

```c
enum moduleCtxCacheIndex {
    COMMON_MODULE_CTX_INDEX = 0,        /* Script compilation and execution */
    GET_MEMORY_MODULE_CTX_INDEX = 1,    /* Periodic memory info queries (server cron) */
    FREE_FUNCTION_MODULE_CTX_INDEX = 2, /* Async function freeing (background thread) */
    MODULE_CTX_CACHE_SIZE = 3
};
```

Each engine call wraps the module context setup/teardown via `engineSetupModuleCtx()` and `engineTeardownModuleCtx()`.

## Engine Unregistration

```c
int scriptingEngineManagerUnregister(const char *engine_name);
```

Called when a scripting engine module unloads:

1. Unlinks the engine from the dictionary.
2. Calls `functionsRemoveLibFromEngine()` to remove all libraries compiled by this engine.
3. Adjusts the global memory overhead.
4. Drains the `BIO_LAZY_FREE` worker to ensure no pending async operations reference the engine - this requires releasing and reacquiring the GIL.
5. Frees the engine struct, name, and module contexts.

## Engine Callback Wrappers

Each wrapper in `scripting_engine.c` follows the same pattern:

1. Set up the module context from cache.
2. Call the engine's method, selecting the correct ABI version variant if needed.
3. Tear down the module context.
4. For `scriptingEngineCallFreeFunction`, acquire the module GIL if called from an async thread.

Key wrappers:

```c
compiledFunction **scriptingEngineCallCompileCode(engine, type, code, code_len,
                                                   timeout, out_num, err);
void scriptingEngineCallFreeFunction(engine, type, compiled_func);
void scriptingEngineCallFunction(engine, server_ctx, caller, compiled_function,
                                 type, keys, nkeys, args, nargs);
size_t scriptingEngineCallGetFunctionMemoryOverhead(engine, compiled_function);
callableLazyEnvReset *scriptingEngineCallResetEnvFunc(engine, type, async);
engineMemoryInfo scriptingEngineCallGetMemoryInfo(engine, type);
```

## Async Environment Reset

When `SCRIPT FLUSH ASYNC` or `FUNCTION FLUSH ASYNC` is called, the engine's `reset_env` callback returns a `callableLazyEnvReset` struct:

```c
typedef struct ValkeyModuleScriptingEngineCallableLazyEnvReset {
    void *context;
    void (*engineLazyEnvResetCallback)(void *context);
} ValkeyModuleScriptingEngineCallableLazyEnvReset;
```

The server collects these callbacks and executes them later in a background thread, allowing the flush to return quickly while the heavy cleanup happens asynchronously.

## Interactive Debugger

The debugger is a server-side facility for step-debugging scripts. It is engine-agnostic - the engine exports debugger commands, and the server handles I/O with the debugging client.

### debugState

Global singleton managing debug sessions:

```c
typedef struct debugState {
    scriptingEngine *engine;         /* Active debugging engine */
    const debuggerCommand *commands; /* Engine-exported command array */
    size_t commands_len;             /* Command count */
    connection *conn;                /* Debugging client's connection */
    int active;                      /* Currently in a debug session? */
    int forked;                      /* Fork-based (async) session? */
    list *logs;                      /* Messages queued for the client */
    list *traces;                    /* Command traces since last stop */
    list *children;                  /* PIDs of forked debug sessions */
    sds cbuf;                        /* Client command buffer */
    size_t maxlen;                   /* Max reply/dump length (default 256) */
    int maxlen_hint_sent;            /* Already suggested "set maxlen"? */
} debugState;
```

### Session Lifecycle

1. **Enable**: `scriptingEngineDebuggerEnable()` calls the engine's `debugger_enable` callback. If the engine returns `VMSE_DEBUG_NOT_SUPPORTED`, debugging is rejected.

2. **Start**: `scriptingEngineDebuggerStartSession()` either forks (async mode) or runs synchronously. The forked child ignores SIGTERM/SIGINT, closes listeners, and handles the debug session. The parent tracks child PIDs and frees the client.

3. **Execute**: EVAL runs normally but the engine's debugger hooks fire at breakpoints. Logs are queued in `ds.logs` and flushed via `scriptingEngineDebuggerFlushLogs()` as RESP multi-bulk simple strings.

4. **End**: `scriptingEngineDebuggerEndSession()` emits `<endsession>`, flushes logs, and restores the connection. Forked sessions call `exitFromChild(0)`.

## Adding a New Scripting Engine

To add a new language engine as a Valkey module:

1. Implement the `engineMethods` callback table (at minimum V3, ideally V4 for debugger support).
2. Set `methods.version = VALKEYMODULE_SCRIPTING_ENGINE_ABI_VERSION`.
3. In the module's `OnLoad`, call `ValkeyModule_RegisterScriptingEngine(ctx, "engine_name", engine_ctx, &methods)`.
4. The `compile_code` callback must return `compiledFunction**` arrays - one element for EVAL, multiple for FUNCTION LOAD.
5. The `call_function` callback receives a `serverRuntimeCtx` (which is the `scriptRunCtx`) for interacting with the server during execution.
6. Implement `reset_env` to handle both `VMSE_EVAL` and `VMSE_FUNCTION` subsystems, with async support via `callableLazyEnvReset`.
7. In `OnUnload`, call `ValkeyModule_UnregisterScriptingEngine(ctx, "engine_name")`.

The engine's name appears in shebang lines: `#!engine_name` for EVAL scripts and `#!engine_name name=libname` for function libraries.

Minimal skeleton:

```c
int MyEngine_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    ValkeyModule_Init(ctx, "myengine", 1, VALKEYMODULE_APIVER_1);

    ValkeyModuleScriptingEngineCtx *engine = ValkeyModule_CreateScriptingEngine(
        ctx,
        "MYENG",           /* engine name */
        my_compile_code,   /* compileFn */
        my_call_function,  /* callFn */
        my_get_used_mem,   /* getUsedMemFn */
        my_get_mem_overhead, /* getEngineMemOverheadFn */
        my_free_function   /* freeFn */
    );
    return VALKEYMODULE_OK;
}
```

## Engine Iterator

```c
void scriptingEngineManagerForEachEngine(engineIterCallback callback, void *context);
```

Used internally for bulk operations: resetting all engines on flush, collecting memory stats, initializing per-engine function stats. The callback receives each `scriptingEngine*` and a user-provided context pointer.

## Memory Reporting

```c
size_t scriptingEngineManagerGetTotalMemoryOverhead(void);
size_t scriptingEngineManagerGetNumEngines(void);
size_t scriptingEngineManagerGetMemoryUsage(void);
```

`GetTotalMemoryOverhead` tracks the sum of all engines' `engine_memory_overhead` plus the engine struct and name allocations. `GetMemoryUsage` returns the dictionary overhead plus the manager struct size.

## See Also

- [EVAL Subsystem](../scripting/eval.md) - Ad-hoc script execution that delegates to the engine layer via `VMSE_EVAL`.
- [Functions Subsystem](../scripting/functions.md) - Library-based scripting that delegates to the engine layer via `VMSE_FUNCTION`.
- [Module API Overview](../modules/api-overview.md) - Scripting engines are implemented as Valkey modules. A module registers an engine during `OnLoad` via `ValkeyModule_RegisterScriptingEngine` and unregisters during `OnUnload`.
- [ACL Subsystem](../security/acl.md) - Module-registered commands (including those from scripting engine modules) are subject to ACL permission checks and can be assigned to ACL categories.
