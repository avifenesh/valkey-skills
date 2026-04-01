# Scripting Engine API - Custom Language Runtimes

Use when implementing a custom scripting language for Valkey, registering a new scripting engine, or adding debugger support to a module-based scripting engine.

Source: `src/module.c` (lines 13803-13931), `src/valkeymodule.h` (lines 870-1302)

## Contents

- [Overview](#overview)
- [Registering a Scripting Engine](#registering-a-scripting-engine)
- [Callbacks Structure](#callbacks-structure)
- [Compiled Function Object](#compiled-function-object)
- [Script Flags](#script-flags)
- [Execution State](#execution-state)
- [Debugger Support](#debugger-support)
- [Unregistering](#unregistering)
- [Full Registration Example](#full-registration-example)

---

## Overview

The Scripting Engine API lets modules register entirely new scripting languages with Valkey. Once registered, scripts written in your language work with `EVAL`, `FUNCTION LOAD`, and `FCALL` - the same commands used for Lua. The engine name matches the shebang in script headers (e.g., `#!HELLO` for an engine named "HELLO").

A module must implement callbacks for compiling, executing, and freeing functions, plus memory reporting and environment reset. Current ABI version is 4:

```c
#define VALKEYMODULE_SCRIPTING_ENGINE_ABI_VERSION 4UL
```

---

## Registering a Scripting Engine

```c
int ValkeyModule_RegisterScriptingEngine(
    ValkeyModuleCtx *module_ctx,
    const char *engine_name,
    ValkeyModuleScriptingEngineCtx *engine_ctx,
    ValkeyModuleScriptingEngineMethods *engine_methods);
```

| Parameter | Description |
|-----------|-------------|
| `module_ctx` | Module context from `OnLoad` |
| `engine_name` | Name matched against shebang (e.g., `"HELLO"`) |
| `engine_ctx` | Opaque pointer to engine-specific state |
| `engine_methods` | Struct of callback function pointers |

Returns `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` if the ABI version exceeds what the server supports or registration fails.

The server validates the `version` field in the methods struct:

```c
if (engine_methods->version > VALKEYMODULE_SCRIPTING_ENGINE_ABI_VERSION) {
    /* Rejected - engine is newer than server */
    return VALKEYMODULE_ERR;
}
```

---

## Callbacks Structure

The methods struct has evolved through ABI versions. V4 (current) extends V3 with debugger callbacks:

```c
typedef struct ValkeyModuleScriptingEngineMethodsV4 {
    uint64_t version;

    /* V3 fields (expanded from VALKEYMODULE_SCRIPTING_ENGINE_METHODS_STRUCT_FIELDS_V3) */
    struct {
        union {
            ValkeyModuleScriptingEngineCompileCodeFuncV1 compile_code_v1;
            ValkeyModuleScriptingEngineCompileCodeFunc compile_code;
        };
        ValkeyModuleScriptingEngineFreeFunctionFunc free_function;
        ValkeyModuleScriptingEngineCallFunctionFunc call_function;
        ValkeyModuleScriptingEngineGetFunctionMemoryOverheadFunc get_function_memory_overhead;
        union {
            ValkeyModuleScriptingEngineResetEvalFuncV2 reset_eval_env_v2;
            ValkeyModuleScriptingEngineResetEnvFunc reset_env;
        };
        ValkeyModuleScriptingEngineGetMemoryInfoFunc get_memory_info;
    };

    /* V4 additions */
    ValkeyModuleScriptingEngineDebuggerEnableFunc debugger_enable;
    ValkeyModuleScriptingEngineDebuggerDisableFunc debugger_disable;
    ValkeyModuleScriptingEngineDebuggerStartFunc debugger_start;
    ValkeyModuleScriptingEngineDebuggerEndFunc debugger_end;
} ValkeyModuleScriptingEngineMethodsV4;

#define ValkeyModuleScriptingEngineMethods ValkeyModuleScriptingEngineMethodsV4
```

The `compile_code` and `reset_env` fields are unions with their older ABI counterparts. When initializing, use the current name for ABI version 3+.

### Required callbacks (all versions)

| Callback | Signature | Purpose |
|----------|-----------|---------|
| `compile_code` | `(ctx, engine_ctx, type, code, code_len, timeout, out_count, err) -> CompiledFunction**` | Compile source into function objects |
| `free_function` | `(ctx, engine_ctx, type, compiled_function) -> void` | Free a compiled function |
| `call_function` | `(ctx, engine_ctx, server_ctx, compiled_function, type, keys, nkeys, args, nargs) -> void` | Execute a compiled function |
| `get_function_memory_overhead` | `(ctx, compiled_function) -> size_t` | Report per-function memory overhead |
| `reset_env` | `(ctx, engine_ctx, type, async) -> CallableLazyEnvReset*` | Reset EVAL or FUNCTION environment |
| `get_memory_info` | `(ctx, engine_ctx, type) -> MemoryInfo` | Report engine memory usage |

The `type` parameter uses `ValkeyModuleScriptingEngineSubsystemType`:

```c
typedef enum {
    VMSE_EVAL,      /* EVAL / SCRIPT LOAD */
    VMSE_FUNCTION,  /* FUNCTION LOAD */
    VMSE_ALL        /* Both subsystems */
} ValkeyModuleScriptingEngineSubsystemType;
```

---

## Compiled Function Object

Each compiled function is represented by:

```c
typedef struct ValkeyModuleScriptingEngineCompiledFunction {
    uint64_t version;         /* VALKEYMODULE_SCRIPTING_ENGINE_ABI_COMPILED_FUNCTION_VERSION */
    ValkeyModuleString *name; /* Function name */
    void *function;           /* Opaque compiled code object */
    ValkeyModuleString *desc; /* Function description */
    uint64_t f_flags;         /* Function flags */
} ValkeyModuleScriptingEngineCompiledFunctionV1;
```

The `compile_code` callback returns an array of these. For `EVAL`/`SCRIPT LOAD`, the array contains one function. For `FUNCTION LOAD`, it contains as many functions as the script registers.

### Memory info struct

```c
typedef struct ValkeyModuleScriptingEngineMemoryInfo {
    uint64_t version;
    size_t used_memory;            /* Runtime memory */
    size_t engine_memory_overhead; /* Data structure overhead */
} ValkeyModuleScriptingEngineMemoryInfoV1;
```

---

## Script Flags

Functions can declare behavioral flags via `f_flags`:

| Flag | Value | Meaning |
|------|-------|---------|
| `VMSE_SCRIPT_FLAG_NO_WRITES` | `1ULL << 0` | Read-only function |
| `VMSE_SCRIPT_FLAG_ALLOW_OOM` | `1ULL << 1` | Allow execution during OOM |
| `VMSE_SCRIPT_FLAG_ALLOW_STALE` | `1ULL << 2` | Allow on stale replicas |
| `VMSE_SCRIPT_FLAG_NO_CLUSTER` | `1ULL << 3` | Not cluster-compatible |
| `VMSE_SCRIPT_FLAG_EVAL_COMPAT_MODE` | `1ULL << 4` | Backwards-compatible EVAL (no shebang) |
| `VMSE_SCRIPT_FLAG_ALLOW_CROSS_SLOT` | `1ULL << 5` | Allow cross-slot operations |

---

## Execution State

During function execution, check if the script has been killed:

```c
ValkeyModuleScriptingEngineExecutionState ValkeyModule_GetFunctionExecutionState(
    ValkeyModuleScriptingEngineServerRuntimeCtx *server_ctx);
```

Returns `VMSE_STATE_EXECUTING` (continue) or `VMSE_STATE_KILLED` (stop immediately - killed by `SCRIPT KILL` or `FUNCTION KILL`). Call this periodically from long-running scripts.

---

## Debugger Support

ABI version 4 added interactive debugging. Four callbacks are added to the methods struct:

| Callback | When called |
|----------|-------------|
| `debugger_enable` | `SCRIPT DEBUG YES/SYNC` - enable debugging mode |
| `debugger_disable` | `SCRIPT DEBUG NO` - disable debugging mode |
| `debugger_start` | Just before executing a function with debug enabled |
| `debugger_end` | Just after executing a function with debug enabled |

The `debugger_enable` callback returns a `ValkeyModuleScriptingEngineDebuggerEnableRet`:

```c
typedef enum {
    VMSE_DEBUG_NOT_SUPPORTED,  /* Engine does not support debugging */
    VMSE_DEBUG_ENABLED,        /* Debugging successfully enabled */
    VMSE_DEBUG_ENABLE_FAIL,    /* Failed to enable debugging */
} ValkeyModuleScriptingEngineDebuggerEnableRet;
```

### Debugger commands

```c
typedef struct ValkeyModuleScriptingEngineDebuggerCommand {
    uint64_t version;
    const char *name;
    const size_t prefix_len;    /* Short-name prefix length */
    const ValkeyModuleScriptingEngineDebuggerCommandParam *params;
    size_t params_len;
    const char *desc;
    int invisible;              /* Hidden from help */
    ValkeyModuleScriptingEngineDebuggerCommandHandlerFunc handler;
    void *context;
} ValkeyModuleScriptingEngineDebuggerCommandV1;
```

### Debugger logging functions

```c
/* Buffer a message for the client (optionally truncated) */
void ValkeyModule_ScriptingEngineDebuggerLog(ValkeyModuleString *msg, int truncate);

/* Log a RESP reply as human-readable text */
void ValkeyModule_ScriptingEngineDebuggerLogRespReply(ValkeyModuleCallReply *reply);
void ValkeyModule_ScriptingEngineDebuggerLogRespReplyStr(const char *reply);

/* Flush all buffered messages to the client */
void ValkeyModule_ScriptingEngineDebuggerFlushLogs(void);

/* Process debugger commands from the client (blocking) */
void ValkeyModule_ScriptingEngineDebuggerProcessCommands(
    int *client_disconnected, ValkeyModuleString **err);
```

---

## Unregistering

Call from `OnUnload` to cleanly remove the engine:

```c
int ValkeyModule_UnregisterScriptingEngine(ValkeyModuleCtx *ctx, const char *engine_name);
```

Returns `VALKEYMODULE_OK` on success, `VALKEYMODULE_ERR` if the engine name is not found.

---

## Full Registration Example

From `tests/modules/helloscripting.c` - a minimal stack-based language (V4 ABI path shown):

```c
static HelloLangCtx *hello_ctx;

int ValkeyModule_OnLoad(ValkeyModuleCtx *ctx, ValkeyModuleString **argv, int argc) {
    VALKEYMODULE_NOT_USED(argv);
    VALKEYMODULE_NOT_USED(argc);
    if (ValkeyModule_Init(ctx, "helloengine", 1, VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR)
        return VALKEYMODULE_ERR;

    hello_ctx = ValkeyModule_Alloc(sizeof(HelloLangCtx));

    ValkeyModuleScriptingEngineMethodsV4 methods = {
        .version = VALKEYMODULE_SCRIPTING_ENGINE_ABI_VERSION,
        .compile_code    = createHelloLangEngine,
        .free_function   = engineFreeFunction,
        .call_function   = callHelloLangFunction,
        .get_function_memory_overhead = engineFunctionMemoryOverhead,
        .reset_env       = helloResetEnv,
        .get_memory_info = engineGetMemoryInfo,
        .debugger_enable  = helloDebuggerEnable,
        .debugger_disable = helloDebuggerDisable,
        .debugger_start   = helloDebuggerStart,
        .debugger_end     = helloDebuggerEnd,
    };

    ValkeyModule_RegisterScriptingEngine(ctx, "HELLO", hello_ctx,
        (ValkeyModuleScriptingEngineMethods *)&methods);
    return VALKEYMODULE_OK;
}

int ValkeyModule_OnUnload(ValkeyModuleCtx *ctx) {
    if (ValkeyModule_UnregisterScriptingEngine(ctx, "HELLO") != VALKEYMODULE_OK) {
        ValkeyModule_Log(ctx, "error", "Failed to unregister engine");
        return VALKEYMODULE_ERR;
    }
    ValkeyModule_Free(hello_ctx);
    hello_ctx = NULL;
    return VALKEYMODULE_OK;
}
```

## See Also

- [lifecycle/module-loading.md](lifecycle/module-loading.md) - OnLoad/OnUnload lifecycle
- [lifecycle/memory.md](lifecycle/memory.md) - Module memory allocation
- [commands/registration.md](commands/registration.md) - Command registration (alternative to scripting)
- [advanced/module-configs.md](advanced/module-configs.md) - Module configuration
- [testing.md](testing.md) - Test framework for module test harnesses
