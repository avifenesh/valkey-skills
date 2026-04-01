# Code Structure

Use when navigating the source tree, adding new features, understanding component relationships, or planning code changes.

Source: `src/`, `vmsdk/`, `testing/`, top-level `CMakeLists.txt`

## Contents

- [Directory Layout](#directory-layout)
- [IndexBase Abstract Class](#indexbase-abstract-class)
- [How to Add a New Index Type](#how-to-add-a-new-index-type)
- [Command Registration Pattern](#command-registration-pattern)
- [VMSDK Key Abstractions](#vmsdk-key-abstractions)
- [How to Add a New Query Feature](#how-to-add-a-new-query-feature)
- [Key Singletons](#key-singletons)
- [Proto Files](#proto-files)

## Directory Layout

```
valkey-search/
  build.sh                  # Developer build script
  CMakeLists.txt            # Top-level CMake configuration
  src/
    module_loader.cc        # Entry point: VALKEY_MODULE() macro, command table
    valkey_search.cc/h      # ValkeySearch singleton - thread pools, lifecycle
    valkey_search_options.cc/h # Module configuration options
    schema_manager.cc/h     # Index schema registry (per-db map of schemas)
    index_schema.cc/h       # Single index schema - attributes, key prefixes
    keyspace_event_manager.cc/h  # Subscribes to key mutations, routes to indexes
    server_events.cc/h      # Server event callbacks (loading, flushing, etc.)
    attribute.cc/h          # Attribute metadata and extraction
    attribute_data_type.cc/h # Custom Valkey data type for attribute storage
    rdb_serialization.cc/h  # Protobuf-based RDB save/load
    vector_externalizer.cc/h # LRU-based vector data externalization
    acl.cc/h                # ACL prefix-based permission checks
    metrics.h               # Metrics counter definitions
    version.h               # Module version constants
    commands/               # Command implementations
      commands.cc/h         # QueryCommand base, async reply/timeout/free
      ft_create.cc          # FT.CREATE implementation
      ft_search.cc/h        # FT.SEARCH implementation
      ft_aggregate.cc/h     # FT.AGGREGATE implementation
      ft_aggregate_exec.cc/h # FT.AGGREGATE execution engine
      ft_dropindex.cc       # FT.DROPINDEX implementation
      ft_info.cc            # FT.INFO implementation
      ft_list.cc            # FT._LIST implementation
      ft_debug.cc           # FT._DEBUG implementation
      ft_internal_update.cc # FT.INTERNAL_UPDATE (replication)
      ft_*_parser.cc/h      # Command argument parsers
      filter_parser.cc/h    # Filter expression parser
      *.json                # Command metadata (flags, arity, key specs)
    indexes/                # Index implementations
      index_base.h          # IndexBase abstract class, IndexerType enum
      vector_base.cc/h      # VectorBase - shared vector index logic
      vector_hnsw.cc/h      # HNSW approximate nearest neighbor index
      vector_flat.cc/h      # FLAT brute-force vector index
      numeric.cc/h          # Numeric range index (segment tree)
      tag.cc/h              # Tag index (inverted index)
      text.cc/h             # Full-text search index (wrapper)
      universal_set_fetcher.cc/h # Universal set fetcher for query planning
      text/                 # Full-text internals
        text_index.cc/h     # Core text index with posting lists
        lexer.cc/h          # Text tokenizer/lexer
        posting.cc/h        # Posting list data structure
        term.cc/h           # Term storage and lookup
        rax_wrapper.cc/h    # Radix tree wrapper over vendored rax
        flat_position_map.cc/h  # Position tracking for proximity queries
        proximity.cc/h      # Proximity query evaluation
        orproximity.cc/h    # OR-proximity query evaluation
        text_fetcher.cc/h   # Text content fetching for scoring
        unicode_normalizer.cc/h # ICU-based Unicode normalization
        fuzzy.h             # Fuzzy matching support
        text_iterator.h     # Text index iterator interface
        radix_tree.h        # Radix tree type alias
        rax/                # Vendored rax radix tree (C, excluded from formatting)
    query/                  # Query engine
      search.cc/h           # Core search logic, SearchParameters, SearchAsync
      planner.cc/h          # Query plan generation
      predicate.cc/h        # Filter predicates (numeric, tag, text)
      content_resolution.cc/h # Key content fetching and attribute extraction
      response_generator.cc/h # Search result formatting
      fanout.cc/h           # Cluster fanout coordination
      fanout_operation_base.h # Base class for fanout operations
      cluster_info_fanout_operation.cc/h # FT.INFO cluster fanout
      primary_info_fanout_operation.cc/h # FT.INFO primary fanout
    coordinator/            # gRPC cluster coordinator
      server.cc/h           # gRPC server for receiving fanout requests
      client.cc/h           # gRPC client for sending fanout requests
      client_pool.h         # Connection pool management
      metadata_manager.cc/h # Index metadata synchronization across nodes
      search_converter.cc/h # Protobuf <-> internal type conversion
      info_converter.cc/h   # FT.INFO protobuf conversion
      grpc_suspender.cc/h   # Graceful gRPC shutdown
      util.h                # Coordinator utility functions
      coordinator.proto     # gRPC service definition
    expr/                   # Expression evaluation
      expr.cc/h             # Filter expression AST and evaluator
      value.cc/h            # Typed values for expression evaluation
    utils/                  # Utility libraries
      allocator.cc/h        # Custom memory allocator
      cancel.cc/h           # Cancellation tokens for query timeouts
      string_interning.cc/h # Interned string pointers for memory efficiency
      patricia_tree.h       # Patricia tree (prefix trie) for key tracking
      segment_tree.h        # Segment tree for numeric range queries
      lru.h                 # LRU cache template
      intrusive_list.h      # Intrusive doubly-linked list
      intrusive_ref_count.h # Intrusive reference counting
      scanner.h             # String scanner utility
      inlined_priority_queue.h # Priority queue for top-K results
  vmsdk/                    # Valkey Module SDK
    src/
      module.h              # VALKEY_MODULE() macro, Options struct
      managed_pointers.h    # UniqueValkeyString, RAII wrappers
      blocked_client.h      # Blocked client tracking by category
      module_config.h       # Type-safe config with builder pattern
      thread_pool.h         # Thread pool with priority scheduling
      cluster_map.h         # Cluster topology and fanout targets
      module_type.h         # Custom data type registration
      memory_allocation.h   # Valkey-aware memory allocation
      memory_tracker.h      # Memory usage tracking
      command_parser.h      # Command argument iteration helpers
      concurrency.h         # Thread utilities
      time_sliced_mrmw_mutex.h # Multi-reader multi-writer mutex
      log.h                 # Structured logging
      info.h                # Module info callback helpers
      debug.h               # Debug command helpers
      utils.h               # General utilities
      testing_infra/        # VMSDK mock infrastructure for unit tests
      valkey_module_api/    # Valkey module API headers
    versionscript.lds       # Linux symbol export control
  testing/                  # Unit tests (see testing.md)
  integration/              # Python integration tests
  third_party/              # Vendored libraries
  submodules/               # External dependency build scripts
```

## IndexBase Abstract Class

All index types implement `IndexBase` defined in `src/indexes/index_base.h`:

```cpp
class IndexBase {
 public:
  virtual absl::StatusOr<bool> AddRecord(const InternedStringPtr& key,
                                         absl::string_view data) = 0;
  virtual absl::StatusOr<bool> RemoveRecord(const InternedStringPtr& key,
                                            DeletionType deletion_type) = 0;
  virtual absl::StatusOr<bool> ModifyRecord(const InternedStringPtr& key,
                                            absl::string_view data) = 0;
  virtual int RespondWithInfo(ValkeyModuleCtx* ctx) const = 0;
  virtual absl::Status SaveIndex(RDBChunkOutputStream chunked_out) const = 0;
  virtual std::unique_ptr<data_model::Index> ToProto() const = 0;
  virtual size_t GetTrackedKeyCount() const = 0;
  virtual uint32_t GetMutationWeight() const = 0;
  // ... key tracking, iteration, NormalizeStringRecord
};
```

The `IndexerType` enum and string-to-enum mapping:

| Type | Enum | String Key | Implementation |
|------|------|-----------|---------------|
| HNSW vector | `kHNSW` | (via `kVector`) | `vector_hnsw.cc` (wraps hnswlib) |
| FLAT vector | `kFlat` | (via `kVector`) | `vector_flat.cc` (brute-force) |
| Numeric | `kNumeric` | `"NUMERIC"` | `numeric.cc` (segment tree) |
| Tag | `kTag` | `"TAG"` | `tag.cc` (inverted index) |
| Text | `kText` | `"TEXT"` | `text.cc` -> `text/text_index.cc` |

The `kIndexerTypeByStr` map recognizes `"VECTOR"`, `"TAG"`, `"NUMERIC"`, and `"TEXT"`. Vector indexes are further resolved to HNSW or FLAT based on the algorithm parameter.

## How to Add a New Index Type

1. **Define the index class** in `src/indexes/new_type.cc/h`:
   - Inherit from `IndexBase`
   - Implement all pure virtual methods: `AddRecord`, `RemoveRecord`, `ModifyRecord`, `RespondWithInfo`, `SaveIndex`, `ToProto`, key tracking, `GetMutationWeight`
2. **Add the enum value** to `IndexerType` in `index_base.h` and the string mapping in `kIndexerTypeByStr`
3. **Create the CMake target** in `src/indexes/CMakeLists.txt` as a static library
4. **Wire into IndexSchema**: update `src/index_schema.cc` to instantiate your index type based on the schema proto attribute type
5. **Add RDB serialization**: extend `rdb_serialization.cc` and the `index_schema.proto` with new fields
6. **Add FT.CREATE parser support**: extend `src/commands/ft_create_parser.cc` to parse your type's parameters
7. **Add FT.INFO support**: implement `RespondWithInfo` and update `ft_info.cc` if needed
8. **Write unit tests** in `testing/` and add to the `indexes_test` binary in `testing/CMakeLists.txt`
9. **Write integration tests** in `integration/`

## Command Registration Pattern

Commands are registered in `src/module_loader.cc` via the `vmsdk::module::Options` struct:

```cpp
vmsdk::module::Options options = {
    .name = "search",
    .acl_categories = ACLPermissionFormatter({valkey_search::kSearchCategory}),
    .commands = {
        {
            .cmd_name = "FT.CREATE",
            .permissions = {...},
            .flags = {vmsdk::module::kWriteFlag, vmsdk::module::kFastFlag,
                      vmsdk::module::kDenyOOMFlag},
            .cmd_func = &vmsdk::CreateCommand<valkey_search::FTCreateCmd>,
        },
        // ... more commands
    },
    .on_load = [](ValkeyModuleCtx *ctx, ...) { /* init singletons */ },
    .on_unload = [](ValkeyModuleCtx *ctx, ...) { /* cleanup */ },
};
VALKEY_MODULE(options);
```

The `VALKEY_MODULE(options)` macro generates the `ValkeyModule_OnLoad` and `ValkeyModule_OnUnload` entry points. Each command function has the signature `absl::Status Func(ValkeyModuleCtx*, ValkeyModuleString**, int)` - returning an error status causes VMSDK to reply with the error message.

Registered commands: `FT.CREATE`, `FT.SEARCH`, `FT.AGGREGATE`, `FT.DROPINDEX`, `FT.INFO`, `FT._LIST`, `FT._DEBUG`, `FT.INTERNAL_UPDATE`.

## VMSDK Key Abstractions

| Abstraction | What it replaces | Why |
|-------------|-----------------|-----|
| `UniqueValkeyString` | Raw `ValkeyModuleString*` | RAII - auto-frees on scope exit |
| `BlockedClient` | Raw `ValkeyModule_BlockClient` | Category tracking, timeout, measurement |
| `vmsdk::config::Builder` | Raw `ValkeyModule_RegisterConfig` | Type-safe, validated, with change callbacks |
| `vmsdk::ThreadPool` | Manual thread management | Priority scheduling, CPU monitoring |
| `vmsdk::module::Options` | Manual `ValkeyModule_CreateCommand` calls | Declarative command table with ACL |
| `vmsdk::cluster_map` | Manual cluster slot management | Automatic topology refresh, fanout targeting |
| `TimeSlicedMRMWMutex` | Standard mutex | Multi-reader multi-writer with time slicing for fork safety |

## How to Add a New Query Feature

1. **Parser**: extend the relevant parser in `src/commands/` (e.g., `ft_search_parser.cc` for FT.SEARCH parameters)
2. **SearchParameters**: add fields to `SearchParameters` in `src/query/search.h`
3. **Query planner**: update `src/query/planner.cc` if the feature affects query planning
4. **Predicate**: if adding a new filter type, create or extend predicates in `src/query/predicate.cc`
5. **Expression**: if adding filter expression operators, extend `src/expr/expr.cc` and `src/expr/value.cc`
6. **Response**: update `src/query/response_generator.cc` if the output format changes
7. **Fanout**: update `src/query/fanout.cc` and the converter in `src/coordinator/search_converter.cc` if the feature needs cluster support
8. **Tests**: add parser tests, unit tests for the logic, and integration tests

## Key Singletons

| Singleton | Access | Responsibility |
|-----------|--------|---------------|
| `ValkeySearch::Instance()` | `src/valkey_search.h` | Module lifecycle, thread pools, coordinator |
| `SchemaManager::Instance()` | `src/schema_manager.h` | Index schema registry, per-db lookup |
| `KeyspaceEventManager` | `src/keyspace_event_manager.h` | Routes key mutations to indexes |

Both `ValkeySearch` and `KeyspaceEventManager` are initialized in `module_loader.cc` during `on_load`.

## Proto Files

| File | Purpose |
|------|---------|
| `src/index_schema.proto` | Index schema definition (attributes, types, parameters) |
| `src/rdb_section.proto` | RDB persistence format |
| `src/coordinator/coordinator.proto` | gRPC service for cluster coordination |

Proto files are compiled to C++ via CMake's `valkey_search_create_proto_library` function defined in `cmake/Modules/valkey_search.cmake`.
