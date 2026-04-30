# Scripting and Modules

Scripting (EVAL / FUNCTION) is a subsystem *of* the module framework - the built-in Lua engine registers through the module scripting-engine ABI. Files: `src/eval.c`, `src/functions.c`, `src/script.c`, `src/scripting_engine.{c,h}`, `src/module.c`, `src/modules/lua/**`, `src/valkeymodule.h`, `src/redismodule.h`, `deps/lua/**` (read-only).

## Scripting dispatch (`src/eval.c`, `src/functions.c`, `src/script.c`)

EVAL/EVALSHA with LRU-bounded script cache (500 entries), shebang flags (`no-writes`, `allow-oom`, `allow-stale`, `no-cluster`, `allow-cross-slot-keys`), and Functions (`FUNCTION LOAD/CALL/DELETE/LIST/STATS/DUMP/RESTORE` + `#!lua name=mylib` + `RDB_OPCODE_FUNCTION2` + effects-based replication) are baseline Redis 7.0+. Valkey-specific: both paths delegate to the pluggable scripting engine; `src/eval.c` and `src/functions.c` are thin wrappers.

- "Script" = EVAL; "library" = FUNCTION. Error strings enforce the split. `This Redis command is not allowed from script` is asserted by tests and external tooling - do not rebrand.
- Nested EVAL / FCALL is unsupported. `curr_run_ctx` is a single global, not a stack.
- EVAL reads flags from the shebang header (`#!lua flags=...`); FUNCTION LOAD reads flags per-function via `server.register_function`. Do not unify the two paths.
- `evalExtractShebangFlags` keeps the `#!` prefix intact while parsing. Trimming the two bytes up front breaks the empty-engine case and trips `-Walloc-size-larger-than`.
- Scripts accessing non-local keys in cluster mode abort with `ERR Script attempted to access a non local key in a cluster node script` before the inner command runs - the offending command never reaches the command dispatcher.
- Lua count-hook gate: `busy_reply_threshold > 0 && !debug_enabled`. `<= 0` disables the interrupt entirely. `lua-time-limit` is an alias.
- `VALKEYMODULE_ARGV_SCRIPT_MODE` (`S` flag to `VM_Call`) and `VALKEYMODULE_CTX_SCRIPT_EXECUTION` are distinct and not interchangeable.
- ACL log labels Lua scripts as `"lua"` and any other engine as `"script"`. The engine name is NOT stored in the ACL log record - preserves backward compat for legacy log-scrapers.
- `VALKEY_VERSION_NUM` exposed to Lua / module API uses a two-digit patch encoding; pre-releases reuse patch 240+ (e.g. `8.0.240 == 0x800f0`). Version-gating code assuming single-digit patch mis-compares.

## Scripting engine ABI (`src/scripting_engine.c`, `src/scripting_engine.h`)

Valkey-only. Engines register via `ValkeyModule_RegisterScriptingEngine(ctx, "name", engine_ctx, &methods)` from module `OnLoad`. Shebang `#!<engine-name>` selects via case-insensitive lookup against the `engineManager` dict. Engines serve two subsystems: `VMSE_EVAL` (ad-hoc EVAL/EVALSHA) and `VMSE_FUNCTION` (FUNCTION-loaded named libraries); `reset_env` takes the subsystem so engines can tear down state correctly per context.

Current ABI: `VALKEYMODULE_SCRIPTING_ENGINE_ABI_VERSION = 4UL`. Engine-declared version must be `<=` server's or registration fails. V1: `compile_code` / `free_function` / `call_function` / `get_function_memory_overhead`. V2: binary-safe `compile_code`. V3: `reset_env` with subsystem. V4: `debugger_*` callbacks.

- Module-API struct changes bump `VALKEYMODULE_*_ABI_VERSION`. Keep V1; add V2 that embeds V1. Read new fields only after `methods.version >= N` check. Never mutate a published struct in place - binary compat breaks every loaded `.so`.
- Enum values are frozen across versions. Insert-in-middle breaks ABI. Append only. The trailing `_VALKEYMODULE_SUBEVENT_..._NEXT` sentinel is required on server-event subevents.
- Scripting-engine callback signature changes are an ABI break (e.g. `reset_eval_env` -> `reset_env` with subsystem param was V2 -> V3).
- Free-callback signatures must match the registry's exact C signature - `void fn(engineCtx *, compiledFunction *)` for `engineLibraryFree`, not a generic `void (*)(void *)`. Mismatched signatures pass the compiler and crash at dispatch.
- ABI compatibility is tested in both directions. Old-server / new-module must ignore new callbacks; new-server / old-module must not crash on `SCRIPT DEBUG` against an engine that did not declare ABI 4.
- Script-engine unregister drains `BIO_LAZY_FREE` before freeing the slot. The engine-name `sds` is freed AFTER `bioDrainWorker` returns - outstanding BIO jobs may still reference it.
- `engineSetupModuleCtx(engine, NULL)` runs even on the built-in Lua path. Every callback must tolerate a NULL module pointer.
- `VALKEYMODULE_*` is reserved for `valkeymodule.h`. Internal constants under `scripting_engine.c` rename to `MODULE_*` (e.g. `MODULE_CTX_THREAD_SAFE`). Do not share prefixes.

## Module lifecycle (`src/module.c`)

Standard `.so` + `ValkeyModule_OnLoad` + `ValkeyModule_Init` + `ValkeyModule_CreateCommand` / `CreateSubcommand`. Header `src/valkeymodule.h`; compat shim `src/redismodule.h` re-exports `RedisModule_*` names via macros; legacy `RedisModule_OnLoad` entry point still accepted.

- `redismodule.h` is a pinned snapshot of Redis 7.2.4. Modules using post-7.2.4 APIs must include `valkeymodule.h` directly. Valkey-only APIs are new functions - never overload an existing name.
- Modules compiled with newer `valkeymodule.h` constants (e.g. `VALKEYMODULE_CLIENTINFO_FLAG_PRIMARY` added in 9.1) must call `ValkeyModule_GetServerVersion` at runtime before relying on them against older servers.
- Module unload cross-thread join before `dlclose`. `blocked_clients == 0` is not an unload barrier - spawned threads must `pthread_join` in `OnUnload`. `drainIOThreadsQueue()` + `bioDrainWorker(BIO_LAZY_FREE)` precede the actual unregister.
- Module command gating (`NO_MULTI`, slot routing, ACL categories) lives in `src/commands/*.json`, not runtime checks inside the handler.
- Modules cannot register new connection *types* (TCP / TLS / unix / RDMA). The connection-type layer is compile-time in `src/connection.h`; modules may provide an alternative *implementation* of an existing type, not a new one.
- Module loading uses `RTLD_NOW|RTLD_LOCAL|RTLD_DEEPBIND`. `RTLD_DEEPBIND` is incompatible with ASan (gate with `!defined(__SANITIZE_ADDRESS__)`) and is Linux / FreeBSD only; Illumos / Solaris / OpenBSD fall back.
- Module-API docs are extracted from `src/module.c` comments, not from the header (`utils/generate-module-api-doc.rb`). Comment-only changes on `VM_*`-prefixed doc comments are a docs PR.

## Custom data types

`ValkeyModule_CreateDataType(ctx, name, encver, &methods)` with 9-character name, `encver ∈ [0, 1023]`. Current `ValkeyModuleTypeMethods` version is **5**.

- `.version = VALKEYMODULE_TYPE_METHOD_VERSION` at the top of the struct literal is required or `CreateDataType` fails.
- `.defrag` returns `NULL` when relocation is unsupported - not a no-op, not the same pointer. Called per allocation during active defrag.
- `.aux_save2` / `.aux_save` fire once per RDB, not per key. V2 lets RDB skip the aux marker entirely when the module has no aux data. `aux_save_triggers` selects when.
- `.mem_usage2` receives `ValkeyModuleKeyOptCtx *` and `size_t sample_size` - respects `MEMORY USAGE SAMPLES`.
- `notifyKeyspaceEvent` + `signalModifiedKey` run BEFORE `addReply*` in command handlers. Ordering was normalized across `t_hash` / `t_zset` / `t_list` / `t_string` - do not regress.

## Key API, blocking, and threading

`ValkeyModule_OpenKey` flags: READ, WRITE, NOTOUCH, NONOTIFY, NOSTATS, NOEXPIRE, NOEFFECTS. Blocking during `CLUSTER FAILOVER IN_PROGRESS` is `blockPostponeClient`-ed; server handles resume, client wakeups happen late.

- `current_client` vs `executing_client` split. `ctx->client` may be a fake / tmp client (module timer, cron, Lua caller, another module). APIs needing the real originating client use `server.current_client`; APIs needing the call-site client use `server.executing_client`. `mustObeyClient`-style checks target `current_client`.
- Module timers / cron run with `current_client == NULL`. `VM_Call` from those paths must null-guard any `current_client` dereference.
- Blocking from inside Lua / MULTI / replica-stream is rejected synchronously. `deny_blocking` is set; `ValkeyModule_BlockClient` returns `NULL` and sets `errno` (`EINVAL` invalid ctx, `ENOTSUP` unsupported context). Keyspace-notification callbacks are the legitimate exception.
- `ValkeyModule_Call` from a worker thread requires `ThreadSafeContextLock` / `Unlock`. Command execution is not thread-safe.
- `VM_Call` reply-type semantics stay backward compatible. Simple strings like `+PONG` are downgraded to bulk strings by default so existing modules and Lua scripts calling command-proxies do not change behaviour.
- Module-originated cross-slot replications are a hard error via `VM_Replicate` during atomic slot migration.
- `VALKEYMODULE_OPTIONS_SKIP_COMMAND_VALIDATION` is an optimization flag, not a sandbox escape - does NOT bypass server-mandated checks (slot ownership, cluster state).

## Lua engine (`src/modules/lua/`, `deps/lua/`)

- Lua is vendored under `deps/lua`; engine lives at `src/modules/lua/`. Do not modify `deps/lua`. Makefile edits go in `src/modules/lua/Makefile` and `src/Makefile`, never `deps/lua/Makefile`.
- Lua VM is single-threaded. `FUNCTION FLUSH ASYNC` + `FUNCTION LOAD` race requires the BIO worker to own its own `lua_State` (for `lua_close`) while main creates fresh. Sharing crashes. The fix shipped as a pair; cherry-picking one half leaves the crash reachable.
- Lua GC must be controlled during script execution - either `LUA_GCCOLLECT` (slight latency) or `LUA_GCSTOP`. Both address the Lua-GC CVE class.
- `luaFunction.function_ref` (from `luaL_ref`) is the only portable handle to the stored Lua function. Never cache raw `lua_State` pointers; the `lua_State *lua` field is only valid in EVAL context.
- `BUILD_LUA=yes` statically links; `=module` produces `libvalkeylua.so`. `-flto` / `-flto=auto` / `-ffat-lto-objects` are stripped from the Lua build because static archive + `--whole-archive` makes LTO architecturally ineffective.
- `ProcessingEventsWhileBlocked=true` during long Lua / long module commands. `processEventsWhileBlocked` still runs fast active expiration and basic I/O - the server is not fully quiet during a busy script.

## Rust SDK

Crate `valkey-module` (crates.io), repo `valkey-io/valkeymodule-rs`. Build as `crate-type = ["cdylib"]` to produce a `.so` loadable by `MODULE LOAD`. Declarative `valkey_module!` macro wires `OnLoad` and command registration. `Context` is the API surface; `ValkeyResult` / `ValkeyError` bubble as replies. Custom data types via `ValkeyType::new()` with `unsafe extern "C"` callbacks. Blocking: `ctx.block_client()` + `std::thread::spawn`. All C-ABI invariants above apply transparently.
