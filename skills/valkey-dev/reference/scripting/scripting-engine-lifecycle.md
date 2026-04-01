# Scripting Engine Lifecycle

Use when registering or unregistering a scripting engine module, understanding callback wrappers, async environment reset, the interactive debugger infrastructure, or adding a new scripting language to Valkey.

Source files: `src/scripting_engine.c`, `src/scripting_engine.h`, `src/valkeymodule.h`

## Contents

- Engine Registration (line 18)
- Module Context Cache (line 41)
- Engine Unregistration (line 53)
- Engine Callback Wrappers (line 67)
- Async Environment Reset (line 89)
- Interactive Debugger (line 102)
- Adding a New Scripting Engine (line 138)
- Engine Iterator (line 172)
- Memory Reporting (line 180)
- See Also (line 190)

---

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

## Module Context Cache

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

---

## See Also

- [scripting-engine-architecture](scripting-engine-architecture.md) - data structures, ABI versions, method table
- [eval](eval.md) - EVAL/EVALSHA Lua integration
- [functions](functions.md) - FUNCTION LOAD/CALL
