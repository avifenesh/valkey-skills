# Module overview

Use when reasoning about module loading, the `ValkeySearch` singleton, thread pools, VMSDK abstraction, or startup sequence.

Source: `src/module_loader.cc`, `src/valkey_search.{h,cc}`, `src/version.h`, `vmsdk/src/module.h`.

## Module identity

```cpp
// src/version.h
constexpr auto kModuleVersion        = vmsdk::ValkeyVersion(1, 2, 0);
constexpr auto kMinimumServerVersion = vmsdk::ValkeyVersion(9, 0, 1);
#define MODULE_RELEASE_STAGE "rc2"   // "dev" on unstable, "rcN", then "ga"
```

Module registers as `"search"` with ACL category `@search`. Three RDB metadata versions:

| Version | Release | Change |
|---------|---------|--------|
| `kRelease10` | 1.0 | Initial |
| `kRelease11` | 1.1 | Cluster mode with non-zero DB numbers |
| `kRelease12` | 1.2 | Full-text search |

## `VALKEY_MODULE` macro

Generates `ValkeyModule_OnLoad` / `ValkeyModule_OnUnload` C entry points in `vmsdk/src/module.h`. Flow:

1. `vmsdk::verifyLoadedOnlyOnce()`
2. `vmsdk::TrackCurrentAsMainThread()`
3. `vmsdk::module::OnLoad()` - `ValkeyModule_Init`, ACL category, command registration
4. User `on_load` callback
5. `vmsdk::module::OnLoadDone()` - finalize

`src/module_loader.cc` wires the options struct (name, version, commands, info, on_load, on_unload). The `on_load` initializes `KeyspaceEventManager` and `ValkeySearch` singletons and calls `ValkeySearch::Instance().OnLoad(...)`.

`ACLPermissionFormatter` strips the `@` prefix from category names for Valkey's module ACL registration.

## `ValkeySearch` singleton

Stored via `absl::NoDestructor<std::unique_ptr<ValkeySearch>>` in `valkey_search.cc`. Holds:

- Reader / writer / utility `vmsdk::ThreadPool` instances
- Detached `ValkeyModuleCtx` (`ctx_`) for background ops, lifetime = module
- Optional `coordinator::Server` + `coordinator::ClientPool` (cluster mode)
- `ClusterMap` refreshed on server cron
- `AtForkPrepare()` / `AfterForkParent()` for thread pool suspension
- `Info()` delegates to `vmsdk::info_field::DoSections()`
- `GetHNSWBlockSize()` / `SetHNSWBlockSize()` - HNSW vector block allocation

## `OnLoad()` sequence

1. `ValkeyModule_GetDetachedThreadSafeContext(ctx)` for `ctx_`.
2. `RegisterModuleType(ctx)` - RDB aux load/save callbacks.
3. `ModuleConfigManager::Instance().Init(ctx)` - register configs.
4. `ValkeyModule_LoadConfigs(ctx)`.
5. `LoadAndParseArgv()` - applies module args. Sanity: reader and writer thread counts must both be enabled or both disabled.
6. `Startup(ctx)` - creates thread pools, `SchemaManager`, optional coordinator.
7. Module options: `HANDLE_IO_ERRORS`, `HANDLE_REPL_ASYNC_LOAD`, `NO_IMPLICIT_SIGNAL_MODIFIED`.
8. JSON module detection for JSON index support.
9. `VectorExternalizer::Instance().Init(ctx_)`.
10. `vmsdk::info_field::Validate(ctx)`.

`OnUnload()` frees `ctx_` and destroys the reader thread pool.

## Thread pools

Three `vmsdk::ThreadPool` instances, all created in `Startup()`:

| Pool | Name prefix | Default | Config | Purpose |
|------|-------------|---------|--------|---------|
| Reader | `read-worker-` | CPU cores | `reader-threads` | FT.SEARCH / FT.AGGREGATE |
| Writer | `write-worker-` | CPU cores | `writer-threads` | Mutation processing (add/modify/remove) |
| Utility | `utility-worker-` | 1 | `utility-threads` | Background cleanup, low-priority tasks |

CPU defaults via `vmsdk::GetPhysicalCPUCoresCount()`. Max 1024/pool. Runtime-resizable via config modify callbacks calling `pool->Resize()`.

- `SupportParallelQueries()` = reader pool has >=1 thread. Zero reader+writer threads = single-threaded mode (main thread executes everything).
- `ScheduleUtilityTask()` - sync fallback if no utility pool.
- `ScheduleSearchResultCleanup()` - gated by `search-result-background-cleanup` config.

## VMSDK layer (`vmsdk/`)

C++ framework over raw `ValkeyModule_*` C API. Never call `ValkeyModule_*` directly.

| Component | File | Purpose |
|-----------|------|---------|
| Module bootstrap | `vmsdk/src/module.h` | `VALKEY_MODULE` macro, command/ACL registration |
| Thread pool | `vmsdk/src/thread_pool.h` | Workers, suspend/resume, priority |
| Config | `vmsdk/src/module_config.h` | Type-safe Number/Boolean/Enum/String configs |
| Managed pointers | `vmsdk/src/managed_pointers.h` | RAII for ValkeyModule objects |
| Command parser | `vmsdk/src/command_parser.h` | Arg iteration |
| Blocked client | `vmsdk/src/blocked_client.h` | Async client blocking for mutation visibility |
| Info fields | `vmsdk/src/info.h` | Declarative INFO section registration |
| Time-sliced mutex | `vmsdk/src/time_sliced_mrmw_mutex.h` | Multi-reader / multi-writer primitive |
| Cluster map | `vmsdk/src/cluster_map.h` | Slot -> node mapping |
| CPU monitor | `vmsdk/src/thread_group_cpu_monitor.h` | Per-group CPU tracking |
| Logging | `vmsdk/src/log.h` | `VMSDK_LOG` with rate limiting |

`vmsdk::CreateCommand<Func>` wraps handlers to return `absl::Status` instead of C int, with auto error-reply formatting.

## Registered commands

Eight commands, all under `@search` ACL category (`FT.INTERNAL_UPDATE` is internal; `FT._LIST` / `FT._DEBUG` are admin-only):

| Command | Flags | ACL |
|---------|-------|-----|
| `FT.CREATE` | write, fast, deny-oom | @search, @write, @fast |
| `FT.DROPINDEX` | write, fast | @search, @write, @fast |
| `FT.INFO` | readonly, fast | @search, @read, @fast |
| `FT._LIST` | readonly, admin | @search, @read, @slow, @admin |
| `FT.SEARCH` | readonly, deny-oom | @search, @read, @slow |
| `FT.AGGREGATE` | readonly, deny-oom | @search, @read, @slow |
| `FT._DEBUG` | readonly, admin | @search, @read, @slow, @admin |
| `FT.INTERNAL_UPDATE` | write, admin, fast | @admin, @search, @write, @fast |

## Configs (`src/valkey_search_options.cc`)

Registered via the `vmsdk::config` builder pattern. Access via `CONFIG GET search.<param>` / `CONFIG SET search.<param> <value>`.

| Config | Type | Default | Range | Purpose |
|--------|------|---------|-------|---------|
| `reader-threads` | Number | CPU cores | 1-1024 | FT.SEARCH / FT.AGGREGATE worker pool |
| `writer-threads` | Number | CPU cores | 1-1024 | mutation-processing worker pool |
| `utility-threads` | Number | 1 | 1-1024 | low-priority background pool (cleanup) |
| `max-worker-suspension-secs` | Number | 60 | 0-3600 | timeout before writer pool resumes post-fork |
| `hnsw-block-size` | Number | 10240 | 0-UINT_MAX | HNSW capacity growth step |
| `query-string-bytes` | Number | 10240 | 1-UINT_MAX | max query string length |
| `max-indexes` | Number | 1000 | 1-10000000 | total indexes across all DBs |
| `backfill-batch-size` | Number | 10240 | 1-INT32_MAX | keys per cron tick (global) |
| `use-coordinator` | Boolean | false | startup-only, hidden | enable cluster gRPC coordinator |
| `log-level` | Enum | notice | warning..debug | module log verbosity |
| `skip-rdb-load` | Boolean | false | | skip vector index data during RDB load |
| `hnsw-allow-replace-deleted` | Boolean | false | dev | reuse deleted HNSW slots before resize |
| `search-result-background-cleanup` | Boolean | false | | offload result destruction to utility pool |
| `high-priority-weight` | Number | 100 | 0-100 | scheduling weight for high vs low priority (100 = backfill only when idle) |
| `enable-partial-results` | Boolean | true | | default SOMESHARDS in cluster fanout |
| `enable-consistent-results` | Boolean | false | | default CONSISTENT query behavior |
| `max-term-expansions` | Number | 200 | 1-100000 | max word expansions for prefix/suffix/fuzzy |
| `tag-min-prefix-length` | Number | 2 | 0-UINT_MAX | min chars before trailing `*` in TAG wildcards |
| `prefiltering-threshold-ratio` | String | "0.001" | 0.0-1.0 (dev) | planner threshold: prefilter when filtered/total is below this |
| `max-nonvector-search-results-fetched` | Number | 100000 | 0-UINT32_MAX | OOM guard for non-vector result sets |

Verify every entry against `src/valkey_search_options.cc` for the target version; a config may have been added, removed, or had its default changed. Hidden configs (`HIDDEN_CONFIG`) don't appear in `CONFIG GET *` / module-discovery output - `use-coordinator` above is hidden and startup-only.

Builder callbacks:

- `.WithValidationCallback(fn)` - runs before value accepted.
- `.WithModifyCallback(fn)` - runs after value applied (used to resize thread pools).
- `.Dev()` - only available when log level is debug.
- Hidden configs (like `use-coordinator`) - set at startup via module args, not via `CONFIG SET`.

## INFO sections

Declarative `vmsdk::info_field` builders. Appear under `MODULE INFO search`.

| Section | Fields | Visibility |
|---------|--------|------------|
| `memory` | `used_memory_human`, `used_memory_bytes`, `index_reclaimable_memory` | App |
| `indexing` | `background_indexing_status` (IN_PROGRESS / NO_ACTIVITY) | App |
| `thread-pool` | `used_read_cpu`, `used_write_cpu`, `query_queue_size`, `writer_queue_size` | App |
| `index_stats` | `number_of_indexes`, `total_indexed_documents`, per-type counts | App |
| `global_ingestion` | Per-type key/field counters, batch metrics | Dev |
| `time_slice_mutex` | Read/write periods, query/upsert/delete counts | Dev |
| `hnswlib` | Exception counts per operation | App |
| `rdb` | Load/save success/failure counts, restore progress | App/Dev |
| `coordinator` | Internal update parse/call/process failure counts | Dev |
| `latency` | HNSW/FLAT search latency samplers | App |
| `string_interning` | Store size | App |
| `vector_externing` | Entry count, LRU stats, hash errors | App |
| `query` | Success/failure, hybrid/prefilter/vector/text/nonvector breakdowns | App |

`App` = standard INFO. `Dev` = log-level=debug or `FT._DEBUG`. Fields marked `CrashSafe` emit during crash reports (no locks, no allocations).
