# Scripting Engine Architecture

Use when investigating the pluggable scripting engine framework, the engine ABI versioning scheme, key data structures (scriptingEngine, engineManager, compiledFunction), or the engine method table.

Source files: `src/scripting_engine.c`, `src/scripting_engine.h`, `src/valkeymodule.h`

## Contents

- Overview (line 19)
- Subsystem Types (line 25)
- Key Data Structures (line 39)
- Engine Methods (ABI) (line 94)
- Backward Compatibility (line 149)
- See Also (line 156)

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

## Backward Compatibility

`scriptingEngineInitializeEngineMethods()` handles older modules: if `methods->version < ABI_VERSION_4`, only the V3 fields are copied. Call wrappers check the version before invoking V4 callbacks and fall back gracefully. For example, `scriptingEngineCallResetEnvFunc()` calls `reset_eval_env_v2` for versions < 3 (EVAL only), and `reset_env` for version >= 3.

---

## See Also

- [scripting-engine-lifecycle](scripting-engine-lifecycle.md) - registration, unregistration, callback wrappers, debugger, adding new engines
- [eval](eval.md) - EVAL/EVALSHA Lua integration
- [functions](functions.md) - FUNCTION LOAD/CALL
