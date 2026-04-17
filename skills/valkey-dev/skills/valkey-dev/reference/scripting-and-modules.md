# Scripting and Modules

Scripting (EVAL / FUNCTION) is now a subsystem *of* the module framework - the built-in Lua engine registers through the module scripting-engine ABI. Agent working on either one usually needs both.

## Scripting dispatch (`src/eval.c`, `src/functions.c`, `src/script.c`)

EVAL/EVALSHA semantics, the LRU-bounded script cache (500 entries), shebang flags (`no-writes`, `allow-oom`, `allow-stale`, `no-cluster`, `allow-cross-slot-keys`), and Functions (FUNCTION LOAD/CALL/DELETE/LIST/STATS/DUMP/RESTORE + `#!lua name=mylib` + `RDB_OPCODE_FUNCTION2` persistence + effects-based replication) - all baseline Redis 7.0+.

Valkey-specific: both paths delegate to the pluggable scripting engine. `src/eval.c` and `src/functions.c` are thin wrappers; VMs live in `src/modules/lua/` (Lua) or wherever other engines register.

## Scripting engine ABI (`src/scripting_engine.c`, `src/scripting_engine.h`)

Valkey-only. Defines an engine ABI so modules can add scripting languages. The built-in Lua engine registers through this interface (`src/modules/lua/engine_lua.c`) - it's not special-cased.

### Core types

- `scriptingEngine`: engine name, module reference, method table, opaque engine context, 3-slot cached module contexts for fast reuse.
- `engineManager`: singleton dict (case-insensitive) + total memory overhead for all engines.
- `compiledFunction`: engine's compiled artifact - name, opaque compiled code, description, flags, ABI version.

### ABI versions

`VALKEYMODULE_SCRIPTING_ENGINE_ABI_VERSION = 4UL` (in `valkeymodule.h`). Engine-declared version must be ≤ server's or registration fails.

| Version | Added |
|---------|-------|
| 1 | Initial - `compile_code`, `free_function`, `call_function`, `get_function_memory_overhead` |
| 2 | Binary-safe `compile_code` |
| 3 | `reset_env` with subsystem type |
| 4 | Debugger callbacks (`debugger_*`) |

### Subsystems

Engines serve two contexts:

- `VMSE_EVAL` - ad-hoc EVAL/EVALSHA scripts
- `VMSE_FUNCTION` - FUNCTION-loaded named libraries

`reset_env` takes the subsystem so engines can tear down state correctly per context.

### Register a new engine

From module `OnLoad`:

```c
ValkeyModule_RegisterScriptingEngine(ctx, "myengine", engine_ctx, &methods);
```

Server copies the method table version-aware (only methods up to your declared `.version` are read), caches module contexts for fast dispatch, queries memory overhead.

**Minimum methods**:

- `compile_code(code, subsystem, ...)` - returns `compiledFunction **`: one element for EVAL, N elements for FUNCTION LOAD (library with multiple functions).
- `free_function`, `call_function(func, ctx, keys, argv)`, `get_function_memory_overhead`.
- `reset_env(subsystem)` - must handle both `VMSE_EVAL` and `VMSE_FUNCTION`, including async teardown. Minimum ABI 3.
- `debugger_*` for step-debug support. ABI 4.

Shebang `#!<engine-name>` (first line) selects the engine via case-insensitive lookup against `engineManager`.

### Unregister

Removes all loaded libraries, drains any `BIO_LAZY_FREE` work referencing engine state, then frees the engine slot. **Don't unregister with live `FCALL` in flight** - no synchronization for that path.

### Debugger

Engine-agnostic framework. Engine exports debug commands via `debugger_enable`; server owns client I/O. Supports a forked (async) session so a blocking debugger doesn't stall the event loop.

## Module lifecycle (`src/module.c`)

Standard `.so` + `ValkeyModule_OnLoad` + `ValkeyModule_Init` + `ValkeyModule_CreateCommand` / `ValkeyModule_CreateSubcommand`. Same shape as Redis - only naming differs.

Grep hazard:

- Header: `src/valkeymodule.h`. Compatibility shim `src/redismodule.h` re-exports `RedisModule_*` names.
- Symbols: `ValkeyModule_*`. Modules built against `redismodule.h` continue to work - shim maps `RedisModule_*` → `ValkeyModule_*` via macros.
- Legacy entry point `RedisModule_OnLoad` is still accepted.
- `redismodule.h` is a **pinned snapshot of Redis 7.2.4**. Modules using APIs added after that must include `valkeymodule.h` directly.

## Custom data types

`ValkeyModule_CreateDataType(ctx, name, encver, &methods)` with a 9-character name and `encver ∈ [0, 1023]`. Current `ValkeyModuleTypeMethods` version is **5** - include `.version = VALKEYMODULE_TYPE_METHOD_VERSION` at the top of the struct literal or the create call fails.

Callbacks agents often miss:

- `.mem_usage2` receives `ValkeyModuleKeyOptCtx *` and `size_t sample_size` - lets it respect `MEMORY USAGE SAMPLES` and query per-key context.
- `.aux_save2` is the newer companion to `.aux_save`: when the module has no aux data, v2 lets RDB skip the aux marker entirely (smaller files when nothing to save).
- `.defrag` is called per allocation inside your type during active defrag - return `NULL` if you don't support relocation.
- `.aux_save` / `.aux_load` run once per RDB (not per key) for module-global state. `aux_save_triggers` selects when to fire.

Base API (RDB Save/Load primitives, AOF rewrite hook, `free`, `copy`, `unlink`) is unchanged from Redis with the rename.

## Key API & blocking

`ValkeyModule_OpenKey` (flags: READ, WRITE, NOTOUCH, NONOTIFY, NOSTATS, NOEXPIRE, NOEFFECTS), `ValkeyModule_BlockClient`, `ValkeyModule_BlockClientOnKeys`, `ValkeyModule_GetThreadSafeContext` behave as in Redis.

One Valkey-specific interaction: blocking commands during `CLUSTER FAILOVER IN_PROGRESS` are `blockPostponeClient`-ed (see `networking.md` on `-REDIRECT`). Your `BlockClient` handlers don't need to special-case this; the server handles resume, but client wakeups happen late.

## Rust SDK

Crate: `valkey-module` (crates.io). Repo: `valkey-io/valkeymodule-rs`.

- Build as `crate-type = ["cdylib"]` to produce a `.so` loadable by `MODULE LOAD`.
- Declarative `valkey_module!` macro wires up `OnLoad` and command registration.
- `Context` is the API surface; `ValkeyResult` / `ValkeyError` bubble to the server as replies.
- Custom data types: `ValkeyType::new()` with `unsafe extern "C"` callbacks for RDB save/load.
- Blocking: `ctx.block_client()` + `std::thread::spawn` (safe bindings own the GIL release).
