# Scripting Engine Lifecycle

Use when registering/unregistering a scripting engine module, adding a new scripting language, or understanding the interactive debugger.

Valkey-specific subsystem. See [scripting-engine-architecture.md](scripting-scripting-engine-architecture.md) for data structures and ABI.

## Registration

`ValkeyModule_RegisterScriptingEngine()` during module load. Copies method table (version-aware), creates cached module contexts, queries memory overhead. Unregistration removes all libraries, drains `BIO_LAZY_FREE`, frees engine.

## Adding a New Engine

Implement `engineMethods` (V3 minimum, V4 for debugger). In `OnLoad`, call `ValkeyModule_RegisterScriptingEngine(ctx, "name", engine_ctx, &methods)`. `compile_code` returns `compiledFunction**` - one for EVAL, multiple for FUNCTION LOAD. Implement `reset_env` for both EVAL and FUNCTION subsystems with async support. Engine name in shebangs: `#!engine_name`.

## Debugger

Engine-agnostic step-debugging. Engine exports commands via `debugger_enable`. Server handles I/O. Supports forked (async) sessions.

Source: `src/scripting_engine.c`, `src/scripting_engine.h`
