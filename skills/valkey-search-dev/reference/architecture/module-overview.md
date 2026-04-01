# Module Overview

Use when understanding module loading, the ValkeySearch singleton, thread pools, VMSDK abstraction, or the overall startup sequence.

Source: `src/module_loader.cc`, `src/valkey_search.h`, `src/valkey_search.cc`, `src/version.h`, `vmsdk/src/module.h`

## Contents

- [Module Identity](#module-identity)
- [VALKEY_MODULE Macro and Loading](#valkey_module-macro-and-loading)
- [ValkeySearch Singleton](#valkeysearch-singleton)
- [OnLoad Sequence](#onload-sequence)
- [Thread Pools](#thread-pools)
- [VMSDK Abstraction Layer](#vmsdk-abstraction-layer)
- [Registered Commands](#registered-commands)
- [Configuration System](#configuration-system)
- [INFO Sections](#info-sections)
- [See Also](#see-also)

## Module Identity

The module registers itself as `search` with version 1.2.0 and requires Valkey server 9.0.1 or later. These constants live in `src/version.h`:

```cpp
constexpr auto kModuleVersion = vmsdk::ValkeyVersion(1, 2, 0);
constexpr auto kMinimumServerVersion = vmsdk::ValkeyVersion(9, 0, 1);
```

The release stage (`MODULE_RELEASE_STAGE`) tracks pre-release status - `"rc2"` during release candidates, `"ga"` for stable releases. Three metadata versions exist for forward/backward compatibility:

| Version | Release | Change |
|---------|---------|--------|
| kRelease10 (1.0.0) | 1.0 | Initial release |
| kRelease11 (1.1.0) | 1.1 | Cluster mode with non-zero DB numbers |
| kRelease12 (1.2.0) | 1.2 | Full-text search |

## VALKEY_MODULE Macro and Loading

The `VALKEY_MODULE(options)` macro in `vmsdk/src/module.h` generates the C entry points `ValkeyModule_OnLoad` and `ValkeyModule_OnUnload`. It:

1. Calls `vmsdk::verifyLoadedOnlyOnce()` to prevent double-loading
2. Calls `vmsdk::TrackCurrentAsMainThread()` to mark the calling thread
3. Delegates to `vmsdk::module::OnLoad()` which handles `ValkeyModule_Init`, ACL category registration, and command registration
4. Invokes the `on_load` callback if present
5. Calls `vmsdk::module::OnLoadDone()` to finalize

In `src/module_loader.cc`, the options struct configures the module:

```cpp
vmsdk::module::Options options = {
    .name = "search",
    .acl_categories = ACLPermissionFormatter({kSearchCategory}),
    .version = kModuleVersion,
    .minimum_valkey_server_version = kMinimumServerVersion,
    .info = valkey_search::ModuleInfo,
    .commands = { /* 8 commands */ },
    .on_load = [](ValkeyModuleCtx *ctx, ValkeyModuleString **argv,
                  int argc, const vmsdk::module::Options &options) {
        KeyspaceEventManager::InitInstance(...);
        ValkeySearch::InitInstance(...);
        return ValkeySearch::Instance().OnLoad(ctx, argv, argc);
    },
    .on_unload = [](ValkeyModuleCtx *ctx,
                    const vmsdk::module::Options &options) {
        ValkeySearch::Instance().OnUnload(ctx);
    },
};
VALKEY_MODULE(options);
```

The `ACLPermissionFormatter` helper strips the `@` prefix from category names (e.g., `@search` becomes `search`) for Valkey's module ACL registration.

## ValkeySearch Singleton

`ValkeySearch` is the central singleton holding module-wide state. It is stored via `absl::NoDestructor<std::unique_ptr<ValkeySearch>>` in `valkey_search.cc`:

```cpp
static absl::NoDestructor<std::unique_ptr<ValkeySearch>> valkey_search_instance;
ValkeySearch &ValkeySearch::Instance() { return **valkey_search_instance; }
```

Key responsibilities:

- **Thread pool ownership** - owns reader, writer, and utility `vmsdk::ThreadPool` instances
- **Background context** - holds a detached `ValkeyModuleCtx` (`ctx_`) valid for the module lifetime
- **Coordinator** - optionally owns a gRPC `coordinator::Server` and `coordinator::ClientPool` for cluster mode
- **Cluster map** - maintains a thread-safe `ClusterMap` refreshed on server cron
- **Fork handling** - implements `AtForkPrepare()` and `AfterForkParent()` for thread pool suspension
- **INFO reporting** - `Info()` delegates to `vmsdk::info_field::DoSections()` which evaluates all registered info fields
- **HNSW block size** - `GetHNSWBlockSize()` / `SetHNSWBlockSize()` manage vector block allocation via the config system

## OnLoad Sequence

`ValkeySearch::OnLoad()` executes on the main thread during module loading:

1. **Acquire background context** - `ValkeyModule_GetDetachedThreadSafeContext(ctx)` for lifetime-scoped operations
2. **Register module type** - `RegisterModuleType(ctx)` for RDB aux load/save callbacks
3. **Initialize configs** - `ModuleConfigManager::Instance().Init(ctx)` registers all module config parameters
4. **Load configs** - `ValkeyModule_LoadConfigs(ctx)` loads values from the server config
5. **Parse argv** - `LoadAndParseArgv()` applies command-line module arguments with a sanity check that reader and writer threads are both enabled or both disabled
6. **Startup** - `Startup(ctx)` creates thread pools, SchemaManager, and optionally the coordinator
7. **Set module options** - enables `HANDLE_IO_ERRORS`, `HANDLE_REPL_ASYNC_LOAD`, `NO_IMPLICIT_SIGNAL_MODIFIED`
8. **JSON detection** - checks if the JSON module is loaded for JSON index support
9. **Vector externalizer** - `VectorExternalizer::Instance().Init(ctx_)` initializes vector data externalization
10. **Validate info fields** - `vmsdk::info_field::Validate(ctx)` ensures all registered info fields are valid

`OnUnload()` frees the background context and destroys the reader thread pool.

## Thread Pools

Three thread pools are created in `Startup()`, each backed by `vmsdk::ThreadPool`:

| Pool | Name prefix | Default size | Purpose |
|------|-------------|-------------|---------|
| Reader | `read-worker-` | CPU core count | FT.SEARCH / FT.AGGREGATE query execution |
| Writer | `write-worker-` | CPU core count | Index mutation processing (add/modify/remove records) |
| Utility | `utility-worker-` | 1 | Low-priority background tasks (search result cleanup) |

Default thread counts come from `vmsdk::GetPhysicalCPUCoresCount()`. All pools are resizable at runtime via module config:

```
CONFIG SET search.reader-threads 8
CONFIG SET search.writer-threads 8
CONFIG SET search.utility-threads 2
```

Maximum is 1024 threads per pool. The modify callbacks call `pool->Resize(new_value)` to adjust live.

### Parallel query support

`SupportParallelQueries()` returns true when the reader pool has at least one thread. When both reader and writer thread counts are zero, the module operates in single-threaded mode - all mutations and queries execute synchronously on the main thread.

### Utility task scheduling

`ScheduleUtilityTask()` dispatches low-priority work to the utility pool. If no pool exists, the task executes synchronously. `ScheduleSearchResultCleanup()` optionally routes cleanup through the utility pool based on the `search-result-background-cleanup` config.

## VMSDK Abstraction Layer

The `vmsdk/` directory provides a C++ framework over the raw ValkeyModule C API:

| Component | File | Purpose |
|-----------|------|---------|
| Module bootstrap | `vmsdk/src/module.h` | VALKEY_MODULE macro, command/ACL registration |
| Thread pool | `vmsdk/src/thread_pool.h` | Worker management, suspend/resume, priority scheduling |
| Config | `vmsdk/src/module_config.h` | Type-safe config registration (Number, Boolean, Enum, String) |
| Managed pointers | `vmsdk/src/managed_pointers.h` | RAII wrappers for ValkeyModule objects |
| Command parser | `vmsdk/src/command_parser.h` | Argument iteration helpers |
| Blocked client | `vmsdk/src/blocked_client.h` | Async client blocking for mutation visibility |
| Info fields | `vmsdk/src/info.h` | Declarative INFO section registration |
| Time-sliced mutex | `vmsdk/src/time_sliced_mrmw_mutex.h` | Multi-reader/multi-writer concurrency primitive |
| Cluster map | `vmsdk/src/cluster_map.h` | Slot-to-node mapping for cluster mode |
| CPU monitor | `vmsdk/src/thread_group_cpu_monitor.h` | Per-thread-group CPU usage tracking |
| Logging | `vmsdk/src/log.h` | VMSDK_LOG macros with rate limiting |
| Utilities | `vmsdk/src/utils.h` | String conversion, version types, main thread tracking |

The `vmsdk::CreateCommand<Func>` template wraps command handler functions so they return `absl::Status` instead of raw integers, with automatic error reply formatting.

## Registered Commands

Eight commands are registered in `module_loader.cc`, all under the `@search` ACL category:

| Command | Handler | Flags | ACL Categories |
|---------|---------|-------|----------------|
| `FT.CREATE` | `FTCreateCmd` | write, fast, deny-oom | @search, @write, @fast |
| `FT.DROPINDEX` | `FTDropIndexCmd` | write, fast | @search, @write, @fast |
| `FT.INFO` | `FTInfoCmd` | readonly, fast | @search, @read, @fast |
| `FT._LIST` | `FTListCmd` | readonly, admin | @search, @read, @slow, @admin |
| `FT.SEARCH` | `FTSearchCmd` | readonly, deny-oom | @search, @read, @slow |
| `FT.AGGREGATE` | `FTAggregateCmd` | readonly, deny-oom | @search, @read, @slow |
| `FT._DEBUG` | `FTDebugCmd` | readonly, admin | @search, @read, @slow, @admin |
| `FT.INTERNAL_UPDATE` | `FTInternalUpdateCmd` | write, admin, fast | @admin, @search, @write, @fast |

`FT.INTERNAL_UPDATE` is the cluster-internal replication command - not meant for user invocation. Commands prefixed with `_` (e.g., `FT._LIST`, `FT._DEBUG`) are internal/admin utilities.

## Configuration System

Module configuration parameters are registered in `src/valkey_search_options.cc` using the `vmsdk::config` builder pattern. Key parameters:

| Config | Type | Default | Range | Description |
|--------|------|---------|-------|-------------|
| `reader-threads` | Number | CPU cores | 1-1024 | Reader thread pool size |
| `writer-threads` | Number | CPU cores | 1-1024 | Writer thread pool size |
| `utility-threads` | Number | 1 | 1-1024 | Utility thread pool size |
| `max-worker-suspension-secs` | Number | 60 | 0-3600 | Max writer suspension during fork |
| `hnsw-block-size` | Number | 10240 | 0-UINT_MAX | HNSW vector block allocation size |
| `query-string-bytes` | Number | 10240 | 1-UINT_MAX | Max query string length |
| `max-indexes` | Number | 1000 | 1-10000000 | Maximum number of indexes |
| `backfill-batch-size` | Number | 10240 | 1-INT32_MAX | Keys per backfill cron tick |
| `use-coordinator` | Boolean | false | - | Enable cluster coordinator (hidden, startup-only) |
| `log-level` | Enum | notice | warning-debug | Module log verbosity |
| `skip-rdb-load` | Boolean | false | - | Skip loading vector index data from RDB |
| `hnsw-allow-replace-deleted` | Boolean | false | - | HNSW replace-deleted optimization (dev) |
| `search-result-background-cleanup` | Boolean | false | - | Offload result cleanup to utility pool |
| `high-priority-weight` | Number | 100 | 0-100 | Thread pool high-priority task weight |
| `enable-partial-results` | Boolean | true | - | Default SOMESHARDS in cluster fanout |
| `enable-consistent-results` | Boolean | false | - | Default CONSISTENT query behavior |
| `max-term-expansions` | Number | 200 | 1-100000 | Max word expansions for prefix/suffix/fuzzy |
| `tag-min-prefix-length` | Number | 2 | 0-UINT_MAX | Min chars before trailing `*` in TAG wildcards |
| `prefiltering-threshold-ratio` | String | "0.001" | 0.0-1.0 | Hybrid query pre-filter vs inline threshold (dev) |
| `max-nonvector-search-results-fetched` | Number | 100000 | 0-UINT32_MAX | OOM guard for non-vector result sets |

Access configs at runtime: `CONFIG GET search.<param>` / `CONFIG SET search.<param> <value>`.

Config types use the builder pattern with optional callbacks:

```cpp
// Validation callback - runs before the value is accepted
.WithValidationCallback(ValidateHNSWBlockSize)

// Modify callback - runs after the value is applied
.WithModifyCallback([](auto new_value) {
    UpdateThreadPoolCount(pool, new_value);
})
```

Hidden configs (like `use-coordinator`) can only be set at startup via module arguments, not via CONFIG SET. Configs marked `.Dev()` are only available when the log level is set to debug.

## INFO Sections

The module registers declarative INFO fields using `vmsdk::info_field` builders. These appear under `MODULE INFO search`:

| Section | Key fields | Visibility |
|---------|-----------|------------|
| `memory` | `used_memory_human`, `used_memory_bytes`, `index_reclaimable_memory` | App |
| `indexing` | `background_indexing_status` (IN_PROGRESS/NO_ACTIVITY) | App |
| `thread-pool` | `used_read_cpu`, `used_write_cpu`, `query_queue_size`, `writer_queue_size` | App |
| `index_stats` | `number_of_indexes`, `total_indexed_documents`, attribute counts | App |
| `global_ingestion` | Per-type key/field counters, batch metrics | Dev |
| `time_slice_mutex` | Read/write periods and time, query/upsert/delete counts | Dev |
| `hnswlib` | Exception counts for add/remove/modify/search/create | App |
| `rdb` | Load/save success/failure counts, restore progress | App/Dev |
| `coordinator` | Internal update parse/call/process failure counts | Dev |
| `latency` | HNSW/FLAT vector search latency samplers | App |
| `string_interning` | Store size (unique strings count) | App |
| `vector_externing` | Entry count, LRU stats, hash errors | App |
| `query` | Success/failure counts, hybrid/prefilter/vector/text/nonvector breakdowns | App |

`App` fields appear in standard INFO output; `Dev` fields appear only when `search.log-level` is set to debug or via `FT._DEBUG` commands. Fields marked `CrashSafe` can be emitted during crash reports (no locks, no allocations).

## See Also

- [index-schema](index-schema.md) - IndexSchema class, per-index state management
- [schema-manager](schema-manager.md) - SchemaManager CRUD and lifecycle events
- [thread-model](thread-model.md) - Concurrency primitives and fork handling details
- [code-structure](../contributing/code-structure.md) - Source tree layout and build targets
- [coordinator](../cluster/coordinator.md) - gRPC coordinator for cluster mode
- [execution](../query/execution.md) - Query execution pipeline using thread pools
