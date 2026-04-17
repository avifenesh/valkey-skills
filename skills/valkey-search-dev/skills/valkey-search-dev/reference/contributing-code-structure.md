# Code structure

Use when navigating the source tree, adding a feature, or planning a change.

Source: `src/`, `vmsdk/`, `testing/`, top-level `CMakeLists.txt`.

## Layout

```
valkey-search/
  build.sh
  CMakeLists.txt
  src/
    module_loader.cc       VALKEY_MODULE(), command table
    valkey_search.{cc,h}   ValkeySearch singleton - pools, lifecycle
    valkey_search_options.{cc,h}
    schema_manager.{cc,h}  index registry (per-db)
    index_schema.{cc,h}    one schema - attributes, prefixes, backfill
    keyspace_event_manager.{cc,h}  routes key mutations to indexes
    server_events.{cc,h}   loading / flushing / fork callbacks
    attribute.{cc,h}       attribute metadata + extraction
    attribute_data_type.{cc,h}  custom data type for attribute storage
    rdb_serialization.{cc,h}    protobuf RDB
    vector_externalizer.{cc,h}  LRU vector externalization
    acl.{cc,h}             prefix-based ACL checks
    metrics.h  version.h
    commands/
      commands.{cc,h}       QueryCommand base; async reply/timeout/free
      ft_create.cc  ft_search.{cc,h}  ft_aggregate.{cc,h}
      ft_aggregate_exec.{cc,h}
      ft_dropindex.cc  ft_info.cc  ft_list.cc  ft_debug.cc
      ft_internal_update.cc  ft_*_parser.{cc,h}  filter_parser.{cc,h}
      *.json                command metadata (flags, arity, key specs)
    indexes/
      index_base.h          IndexBase, IndexerType
      vector_base.{cc,h}    shared vector logic
      vector_hnsw.{cc,h}    HNSW
      vector_flat.{cc,h}    FLAT
      numeric.{cc,h}        segment tree
      tag.{cc,h}            Patricia tree
      text.{cc,h}           full-text wrapper
      universal_set_fetcher.{cc,h}
      text/
        text_index.{cc,h}   postings
        lexer.{cc,h}        tokenizer
        posting.{cc,h}  term.{cc,h}  rax_wrapper.{cc,h}
        flat_position_map.{cc,h}  proximity.{cc,h}  orproximity.{cc,h}
        text_fetcher.{cc,h}  unicode_normalizer.{cc,h}  fuzzy.h
        text_iterator.h  radix_tree.h
        rax/                  vendored rax (C; excluded from formatting)
    query/
      search.{cc,h}         SearchParameters, SearchAsync
      planner.{cc,h}        prefilter vs inline
      predicate.{cc,h}      numeric / tag / text
      content_resolution.{cc,h}
      response_generator.{cc,h}
      fanout.{cc,h}  fanout_operation_base.h
      cluster_info_fanout_operation.{cc,h}
      primary_info_fanout_operation.{cc,h}
    coordinator/
      server.{cc,h}  client.{cc,h}  client_pool.h
      metadata_manager.{cc,h}
      search_converter.{cc,h}  info_converter.{cc,h}
      grpc_suspender.{cc,h}  util.h  coordinator.proto
    expr/
      expr.{cc,h}  value.{cc,h}
    utils/
      allocator.{cc,h}  cancel.{cc,h}  string_interning.{cc,h}
      patricia_tree.h  segment_tree.h  lru.h
      intrusive_list.h  intrusive_ref_count.h  scanner.h
      inlined_priority_queue.h
  vmsdk/
    src/
      module.h              VALKEY_MODULE(), Options
      managed_pointers.h    UniqueValkeyString, RAII
      blocked_client.h      blocked clients by category
      module_config.h       type-safe configs (builder)
      thread_pool.h         priority scheduling
      cluster_map.h         topology + fanout targets
      module_type.h         custom data type registration
      memory_allocation.h  memory_tracker.h  command_parser.h
      concurrency.h  time_sliced_mrmw_mutex.h
      log.h  info.h  debug.h  utils.h
      testing_infra/        mock ValkeyModule_* for unit tests
      valkey_module_api/    Valkey API headers
    versionscript.lds       Linux symbol export
  testing/
  integration/
  third_party/  submodules/
```

## `IndexBase` (`src/indexes/index_base.h`)

```cpp
class IndexBase {
 public:
  virtual absl::StatusOr<bool> AddRecord   (const InternedStringPtr&, absl::string_view) = 0;
  virtual absl::StatusOr<bool> RemoveRecord(const InternedStringPtr&, DeletionType)      = 0;
  virtual absl::StatusOr<bool> ModifyRecord(const InternedStringPtr&, absl::string_view) = 0;
  virtual int                  RespondWithInfo(ValkeyModuleCtx*) const = 0;
  virtual absl::Status         SaveIndex(RDBChunkOutputStream) const  = 0;
  virtual std::unique_ptr<data_model::Index> ToProto() const          = 0;
  virtual size_t               GetTrackedKeyCount() const             = 0;
  virtual uint32_t             GetMutationWeight() const              = 0;
  // + key tracking / iteration / NormalizeStringRecord
};
```

`IndexerType` enum and `kIndexerTypeByStr`:

| Enum | String | Impl |
|------|--------|------|
| `kHNSW` | (via `kVector`) | `vector_hnsw.cc` (hnswlib) |
| `kFlat` | (via `kVector`) | `vector_flat.cc` (brute force) |
| `kNumeric` | `"NUMERIC"` | `numeric.cc` (segment tree) |
| `kTag` | `"TAG"` | `tag.cc` (Patricia tree) |
| `kText` | `"TEXT"` | `text.cc` -> `text/text_index.cc` |

`kIndexerTypeByStr` accepts `"VECTOR"`, `"TAG"`, `"NUMERIC"`, `"TEXT"`. Vector is resolved to HNSW / FLAT by the algorithm parameter.

## Adding a new index type

1. `src/indexes/new_type.{cc,h}` inheriting `IndexBase` - implement all pure virtuals.
2. Add enum value in `index_base.h` + string mapping in `kIndexerTypeByStr`.
3. CMake target in `src/indexes/CMakeLists.txt`.
4. Wire into `src/index_schema.cc` instantiation by proto type.
5. Extend `rdb_serialization.cc` + `index_schema.proto` fields.
6. Extend `src/commands/ft_create_parser.cc`.
7. `RespondWithInfo` + update `ft_info.cc` if needed.
8. Unit tests -> `indexes_test` binary.
9. Integration tests in `integration/`.

## Command registration (`module_loader.cc`)

```cpp
vmsdk::module::Options options = {
    .name = "search",
    .acl_categories = ACLPermissionFormatter({kSearchCategory}),
    .commands = {{
        .cmd_name    = "FT.CREATE",
        .permissions = {...},
        .flags       = {kWriteFlag, kFastFlag, kDenyOOMFlag},
        .cmd_func    = &vmsdk::CreateCommand<FTCreateCmd>,
    }, /* ... */},
    .on_load   = [](ctx, ...) { /* init singletons */ },
    .on_unload = [](ctx, ...) { /* cleanup */ },
};
VALKEY_MODULE(options);
```

Handler signature: `absl::Status Func(ValkeyModuleCtx*, ValkeyModuleString**, int)`. Error status -> VMSDK replies with the error message.

Commands: `FT.CREATE`, `FT.SEARCH`, `FT.AGGREGATE`, `FT.DROPINDEX`, `FT.INFO`, `FT._LIST`, `FT._DEBUG`, `FT.INTERNAL_UPDATE`.

## VMSDK abstractions

| Abstraction | Replaces | Why |
|-------------|----------|-----|
| `UniqueValkeyString` | raw `ValkeyModuleString*` | RAII auto-free |
| `BlockedClient` | raw `ValkeyModule_BlockClient` | category, timeout, measurement |
| `vmsdk::config::Builder` | raw `ValkeyModule_RegisterConfig` | type-safe + validation + callbacks |
| `vmsdk::ThreadPool` | manual threads | priority scheduling, CPU monitor |
| `vmsdk::module::Options` | manual `CreateCommand` | declarative command table |
| `vmsdk::cluster_map` | manual slot management | topology refresh + fanout |
| `TimeSlicedMRMWMutex` | standard mutex | MRMW + time-slice + fork-safe |

## Adding a new query feature

1. Parser in `src/commands/` (e.g., `ft_search_parser.cc`).
2. `SearchParameters` fields in `src/query/search.h`.
3. Planner -> `src/query/planner.cc` if it affects planning.
4. New filter type -> `src/query/predicate.cc`.
5. New expression operator -> `src/expr/expr.cc` + `value.cc`.
6. Response format -> `src/query/response_generator.cc`.
7. Cluster support -> `src/query/fanout.cc` + `src/coordinator/search_converter.cc`.
8. Parser tests + unit + integration.

## Singletons

| Singleton | Header | Role |
|-----------|--------|------|
| `ValkeySearch::Instance()` | `valkey_search.h` | module lifecycle, pools, coordinator |
| `SchemaManager::Instance()` | `schema_manager.h` | index registry, per-db lookup |
| `KeyspaceEventManager` | `keyspace_event_manager.h` | route mutations to indexes |

Both `ValkeySearch` and `KeyspaceEventManager` init in `module_loader.cc` `on_load`.

## Protos

| File | Purpose |
|------|---------|
| `src/index_schema.proto` | schema definition (attributes, types, params) |
| `src/rdb_section.proto` | RDB persistence format |
| `src/coordinator/coordinator.proto` | gRPC service |

Compiled to C++ via CMake's `valkey_search_create_proto_library` (`cmake/Modules/valkey_search.cmake`).
